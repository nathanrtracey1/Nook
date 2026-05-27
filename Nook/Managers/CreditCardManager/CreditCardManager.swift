//
//  CreditCardManager.swift
//  Nook
//
//  Custom feature: Safari-style credit card autofill: Keychain storage, Touch ID before fill or view.
//

import Foundation
import LocalAuthentication
import Security
import WebKit

struct SavedCardEntry: Identifiable {
    let id: String
    let lastFour: String
    let brand: String
    let name: String
    let expiryMonth: String
    let expiryYear: String
    let number: String
    let cvv: String?

    static func id(from number: String, name: String) -> String {
        "\(number.suffix(4))|\(name)"
    }

    var displayLabel: String { "\(brand) •••• \(lastFour)" }
}

@MainActor
final class CreditCardManager {
    static let shared = CreditCardManager()
    private let service = "com.nook.creditcards"

    private init() {}

    func listEntries() -> [SavedCardEntry] {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item -> SavedCardEntry? in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let payload = try? JSONDecoder().decode(CardPayload.self, from: data) else { return nil }
            return SavedCardEntry(
                id: account,
                lastFour: payload.lastFour,
                brand: payload.brand,
                name: payload.name,
                expiryMonth: payload.expiryMonth,
                expiryYear: payload.expiryYear,
                number: payload.number,
                cvv: payload.cvv
            )
        }
        #else
        return []
        #endif
    }

    func save(number: String, expiryMonth: String, expiryYear: String, name: String, cvv: String?) -> Bool {
        let digits = number.filter { $0.isNumber }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        let lastFour = String(digits.suffix(4))
        let brand = brandFromNumber(digits)
        let payload = CardPayload(
            lastFour: lastFour,
            brand: brand,
            name: name,
            expiryMonth: expiryMonth,
            expiryYear: expiryYear,
            number: digits,
            cvv: cvv
        )
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        let account = SavedCardEntry.id(from: digits, name: name)
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
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

    func getFullCard(entryId: String) -> SavedCardEntry? {
        listEntries().first { $0.id == entryId }
    }

    func delete(entryId: String) -> Bool {
        guard listEntries().contains(where: { $0.id == entryId }) else { return false }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: entryId
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess || SecItemDelete(query as CFDictionary) == errSecItemNotFound
        #else
        return false
        #endif
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

    private func brandFromNumber(_ digits: String) -> String {
        let first = digits.prefix(1)
        let two = digits.prefix(2)
        if two == "34" || two == "37" { return "American Express" }
        if first == "4" { return "Visa" }
        if two >= "51" && two <= "55" { return "Mastercard" }
        if two == "36" || two == "38" || (two >= "30" && two <= "35") { return "Diners" }
        if two == "65" || two == "60" || digits.hasPrefix("3528") || digits.hasPrefix("3589") { return "Discover" }
        return "Card"
    }

    /// User script for card field detection and fill callback. Used by CustomFeatureRegistry.
    static func userScript() -> WKUserScript {
        let source = """
        (function() {
          if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.nookCreditCard) return;
          window.__nookCreditCardFill = function(number, expMonth, expYear, name) {
            try {
              var num = document.querySelector('input[autocomplete="cc-number"], input[name*="cardnumber"], input[name*="number"], input[id*="cardnumber"], input[id*="number"]');
              var exp = document.querySelector('input[autocomplete="cc-exp"], input[name*="expir"], input[name*="exp-date"], input[id*="expir"]');
              var expM = document.querySelector('input[name*="month"], input[id*="month"]');
              var expY = document.querySelector('input[name*="year"], input[id*="year"]');
              var nameIn = document.querySelector('input[autocomplete="cc-name"], input[name*="name"], input[name*="cardname"], input[id*="name"]');
              if (num) { num.value = number; num.dispatchEvent(new Event('input', { bubbles: true })); }
              if (exp && expMonth && expYear) { var m = expMonth.length === 1 ? '0' + expMonth : expMonth; exp.value = m + '/' + expYear.slice(-2); exp.dispatchEvent(new Event('input', { bubbles: true })); }
              if (expM) { expM.value = expMonth; expM.dispatchEvent(new Event('input', { bubbles: true })); }
              if (expY) { expY.value = expYear; expY.dispatchEvent(new Event('input', { bubbles: true })); }
              if (nameIn) { nameIn.value = name; nameIn.dispatchEvent(new Event('input', { bubbles: true })); }
            } catch (e) {}
          };
          document.addEventListener('focusin', function(e) {
            if (!e.target || e.target.tagName !== 'INPUT') return;
            var a = (e.target.getAttribute('autocomplete') || '').toLowerCase();
            var n = (e.target.name || '').toLowerCase(), i = (e.target.id || '').toLowerCase();
            if (a.indexOf('cc') !== -1 || n.indexOf('card') !== -1 || n.indexOf('number') !== -1 || i.indexOf('card') !== -1 || i.indexOf('number') !== -1) {
              window.webkit.messageHandlers.nookCreditCard.postMessage({ type: 'autofillRequest' });
            }
          }, true);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// Handle message from web content (autofillRequest). Called by CustomFeatureRegistry.
    func handleMessage(_ message: WKScriptMessage, webView: WKWebView?) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String,
              type == "autofillRequest" else { return }
        Task { @MainActor in
            await handleAutofillRequest(webView: webView)
        }
    }

    private func handleAutofillRequest(webView: WKWebView?) async {
        let entries = listEntries()
        guard !entries.isEmpty, let webView = webView else { return }

        let card: SavedCardEntry
        if entries.count == 1 {
            card = entries[0]
        } else {
            guard let chosen = await pickCard(from: entries) else { return }
            card = chosen
        }

        let ok = await authenticateWithTouchID(reason: "Unlock saved card to autofill")
        guard ok else { return }
        fillCard(card, in: webView)
    }

    private func pickCard(from entries: [SavedCardEntry]) async -> SavedCardEntry? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Choose a Card"
                alert.informativeText = "Select a card to autofill."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Fill")
                alert.addButton(withTitle: "Cancel")

                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
                for entry in entries {
                    popup.addItem(withTitle: "\(entry.displayLabel)  —  \(entry.name)")
                }
                alert.accessoryView = popup

                if alert.runModal() == .alertFirstButtonReturn {
                    let idx = popup.indexOfSelectedItem
                    continuation.resume(returning: entries[idx])
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func fillCard(_ card: SavedCardEntry, in webView: WKWebView) {
        let numEsc = jsEscape(card.number)
        let monthEsc = jsEscape(card.expiryMonth)
        let yearEsc = jsEscape(card.expiryYear)
        let nameEsc = jsEscape(card.name)
        let script = "typeof window.__nookCreditCardFill === 'function' && window.__nookCreditCardFill('\(numEsc)', '\(monthEsc)', '\(yearEsc)', '\(nameEsc)');"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func jsEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}

private struct CardPayload: Codable {
    let lastFour: String
    let brand: String
    let name: String
    let expiryMonth: String
    let expiryYear: String
    let number: String
    let cvv: String?
}
