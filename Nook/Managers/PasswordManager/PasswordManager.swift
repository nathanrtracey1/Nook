//
//  PasswordManager.swift
//  Nook
//
//  Safari-style password manager: Keychain storage, Touch ID for reveal/autofill, native dropdown for suggestions.
//  Security: Credentials are never injected automatically; the user must click a suggestion to fill.
//  All data is stored in the system Keychain (encrypted), not in the app sandbox.
//  Touch ID is used for authenticateWithTouchID when revealing or filling passwords.
//  Optional hardening: kSecAttrAccessControl with .userPresence would require biometrics for each access.
//

import AppKit
import Foundation
import LocalAuthentication
import Security
import WebKit

struct SavedPasswordEntry: Identifiable {
    let id: String
    let origin: String
    let username: String
    var password: String { _password ?? "" }
    private let _password: String?
    init(origin: String, username: String, password: String? = nil) {
        self.origin = origin
        self.username = username
        self.id = "\(origin)|\(username)"
        self._password = password
    }
}

@MainActor
final class PasswordManager {
    static let shared = PasswordManager()
    private let service = "com.nook.passwords"

    private init() {}

    private func accountKey(origin: String, username: String) -> String {
        "\(origin)\t\(username)"
    }

    func listEntries(origin: String? = nil) -> [SavedPasswordEntry] {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> SavedPasswordEntry? in
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.contains("\t"),
                  let parts = account.split(separator: "\t", maxSplits: 1).map(String.init) as [String]?,
                  parts.count == 2 else { return nil }
            let o = parts[0], u = parts[1]
            if let origin = origin, o != origin { return nil }
            return SavedPasswordEntry(origin: o, username: u, password: nil)
        }
        #else
        return []
        #endif
    }

    func save(origin: String, username: String, password: String) -> Bool {
        guard !origin.isEmpty, !username.isEmpty else { return false }
        #if canImport(Security)
        let key = accountKey(origin: origin, username: username)
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess
        } else {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        #else
        return false
        #endif
    }

    func getPassword(origin: String, username: String) -> String? {
        #if canImport(Security)
        let key = accountKey(origin: origin, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return password
        #else
        return nil
        #endif
    }

    func delete(origin: String, username: String) -> Bool {
        #if canImport(Security)
        let key = accountKey(origin: origin, username: username)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess || SecItemDelete(query as CFDictionary) == errSecItemNotFound
        #else
        return false
        #endif
    }

    /// Removes all saved passwords from Keychain. Returns the number of entries deleted.
    func deleteAll() -> Int {
        let entries = listEntries()
        var deleted = 0
        for entry in entries {
            if delete(origin: entry.origin, username: entry.username) {
                deleted += 1
            }
        }
        return deleted
    }

    func authenticateWithTouchID(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            return false
        }
    }

    /// User script for login form detection, field rect reporting, and fill callback. Used by CustomFeatureRegistry.
    /// Detects login contexts by: password fields, username/email fields (type, name, id, autocomplete, placeholder), and form structure.
    static func userScript() -> WKUserScript {
        let source = """
        (function() {
          if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.nookPassword) return;
          function isLoginUsernameField(input) {
            if (!input || input.tagName !== 'INPUT') return false;
            var t = (input.type || '').toLowerCase();
            if (t === 'email' || t === 'text') return true;
            var n = (input.name || '').toLowerCase(), i = (input.id || '').toLowerCase();
            var a = (input.getAttribute('autocomplete') || '').toLowerCase();
            if (a === 'username' || a === 'email' || a === 'username email') return true;
            if (/user|login|account|email|e-mail/.test(n) || /user|login|account|email|e-mail/.test(i)) return true;
            var p = (input.placeholder || '').toLowerCase(), l = (input.getAttribute('aria-label') || '').toLowerCase();
            if (/user|login|email|e-mail|account/.test(p) || /user|login|email|e-mail|account/.test(l)) return true;
            return false;
          }
          function findUsernameInput(container) {
            var root = container || document;
            var candidates = root.querySelectorAll('input[type="text"], input[type="email"], input[autocomplete="username"], input[autocomplete="email"], input[name*="user"], input[name*="login"], input[name*="email"], input[name*="account"], input[id*="user"], input[id*="login"], input[id*="email"], input[id*="account"]');
            for (var i = 0; i < candidates.length; i++) {
              if (isLoginUsernameField(candidates[i])) return candidates[i];
            }
            return candidates.length ? candidates[0] : null;
          }
          function findPasswordInput(container) {
            var root = container || document;
            return root.querySelector('input[type="password"]');
          }
          window.__nookPasswordFill = function(username, password) {
            try {
              var pass = findPasswordInput(document);
              var user = pass ? (pass.form ? findUsernameInput(pass.form) : findUsernameInput(document)) : null;
              if (!user) user = findUsernameInput(document);
              if (user) { user.value = username; user.dispatchEvent(new Event('input', { bubbles: true })); }
              if (pass) { pass.value = password; pass.dispatchEvent(new Event('input', { bubbles: true })); }
            } catch (e) {}
          };
          document.addEventListener('submit', function(e) {
            var form = e.target;
            var pass = form && findPasswordInput(form);
            var user = form && findUsernameInput(form);
            if (pass && user && pass.value && user.value) {
              window.webkit.messageHandlers.nookPassword.postMessage({ type: 'saveRequest', origin: location.origin, username: user.value, password: pass.value });
            }
          }, true);
          var lastFocusedLoginField = null;
          function sendRect(el) {
            if (!el) return;
            var r = el.getBoundingClientRect();
            window.webkit.messageHandlers.nookPassword.postMessage({
              type: 'autofillRequest',
              origin: location.origin,
              rect: { left: r.left, top: r.top, width: r.width, height: r.height }
            });
          }
          function onLoginFieldFocused(target) {
            if (!target || target.tagName !== 'INPUT') return;
            var isPassword = target.type === 'password';
            var isUserField = isLoginUsernameField(target);
            if (isPassword) {
              lastFocusedLoginField = target;
              sendRect(target);
              return;
            }
            if (isUserField) {
              var form = target.form || target.closest('form');
              if (form && findPasswordInput(form)) {
                lastFocusedLoginField = target;
                sendRect(target);
                return;
              }
              var anyPass = findPasswordInput(document);
              if (anyPass && (anyPass.form === null || anyPass.closest('form') === target.closest('form'))) {
                lastFocusedLoginField = target;
                sendRect(target);
              }
            }
          }
          document.addEventListener('focusin', function(e) { onLoginFieldFocused(e.target); }, true);
          document.addEventListener('click', function(e) {
            if (e.target && e.target.tagName === 'INPUT' && e.target.type === 'password') {
              lastFocusedLoginField = e.target;
              sendRect(e.target);
            }
          }, true);
          document.addEventListener('focusout', function(e) {
            if (e.target === lastFocusedLoginField) {
              var field = lastFocusedLoginField;
              lastFocusedLoginField = null;
              setTimeout(function() {
                if (document.activeElement !== field) {
                  window.webkit.messageHandlers.nookPassword.postMessage({ type: 'autofillDismiss', origin: location.origin });
                }
              }, 150);
            }
          }, true);
        })();
        """
        // Inject in all frames so login forms inside iframes (e.g. Microsoft, Google) are detected
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Popover for password suggestions; closed when focus leaves field or user selects a credential.
    private var suggestionPopover: PasswordSuggestionPopoverController?

    /// Handle message from web content (saveRequest, autofillRequest, autofillDismiss). Called by CustomFeatureRegistry.
    func handleMessage(_ message: WKScriptMessage, webView: WKWebView?) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }

        if type == "saveRequest" {
            guard let origin = dict["origin"] as? String, !origin.isEmpty,
                  let username = dict["username"] as? String, !username.isEmpty,
                  let password = dict["password"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                self?.showSavePasswordDialog(origin: origin, username: username, password: password)
            }
            return
        }

        if type == "autofillDismiss" {
            suggestionPopover?.dismiss()
            suggestionPopover = nil
            return
        }

        if type == "autofillRequest" {
            guard let origin = dict["origin"] as? String, !origin.isEmpty else { return }
            let rect = parseRect(from: dict)
            Task { @MainActor in
                await showPasswordSuggestionPopover(origin: origin, rect: rect, webView: webView)
            }
            return
        }
    }

    /// Parse rect from JS getBoundingClientRect (viewport coords: top-left origin). Values may be NSNumber.
    private func parseRect(from dict: [String: Any]) -> CGRect? {
        guard let rectDict = dict["rect"] as? [String: Any] else { return nil }
        func num(_ key: String) -> CGFloat? {
            guard let v = rectDict[key] else { return nil }
            if let n = v as? NSNumber { return CGFloat(truncating: n) }
            if let d = v as? Double { return CGFloat(d) }
            return nil
        }
        guard let left = num("left"), let top = num("top"), let width = num("width"), let height = num("height") else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    /// Show suggestion popover anchored to the password field; on select, fill and close.
    private func showPasswordSuggestionPopover(origin: String, rect: CGRect?, webView: WKWebView?) async {
        guard let webView = webView else { return }

        suggestionPopover?.dismiss()
        suggestionPopover = nil

        let entries = listEntries(origin: origin)
        let anchorRect: CGRect
        if let r = rect, let converted = viewRectFromViewport(r, in: webView) {
            anchorRect = converted
        } else {
            anchorRect = CGRect(x: webView.bounds.midX - 20, y: webView.bounds.midY - 20, width: 40, height: 40)
        }

        let controller = PasswordSuggestionPopoverController()
        suggestionPopover = controller

        controller.show(
            entries: entries,
            anchorRect: anchorRect,
            in: webView,
            onSelect: { [weak self] entry in
                Task { @MainActor in
                    await self?.fillPassword(entry: entry, webView: webView)
                }
            },
            onClose: { [weak self] in
                self?.suggestionPopover = nil
            }
        )
    }

    /// Convert viewport rect (getBoundingClientRect: top-left origin) to AppKit view rect (bottom-left origin).
    private func viewRectFromViewport(_ viewportRect: CGRect, in webView: WKWebView) -> CGRect? {
        let h = webView.bounds.height
        return CGRect(
            x: viewportRect.origin.x,
            y: h - viewportRect.origin.y - viewportRect.height,
            width: viewportRect.width,
            height: viewportRect.height
        )
    }

    /// Fill username and password for the selected entry via JS; optionally prompt Touch ID first.
    private func fillPassword(entry: SavedPasswordEntry, webView: WKWebView) async {
        guard let password = getPassword(origin: entry.origin, username: entry.username) else { return }
        let ok = await authenticateWithTouchID(reason: "Unlock saved password to autofill")
        guard ok else { return }
        let userEscaped = jsEscape(entry.username)
        let passEscaped = jsEscape(password)
        let script = "typeof window.__nookPasswordFill === 'function' && window.__nookPasswordFill('\(userEscaped)', '\(passEscaped)');"
        webView.evaluateJavaScript(script, completionHandler: nil)
        suggestionPopover?.dismiss()
        suggestionPopover = nil
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }

    private func showSavePasswordDialog(origin: String, username: String, password: String) {
        let alert = NSAlert()
        alert.messageText = "Save Password?"
        alert.informativeText = "Save password for \(username) on \(origin)?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Never")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            _ = save(origin: origin, username: username, password: password)
        }
    }

    // Security: Credentials are never injected automatically. Fill only happens when the user
    // explicitly selects an entry from the suggestion popover (fillPassword). No auto-fill path.
}
