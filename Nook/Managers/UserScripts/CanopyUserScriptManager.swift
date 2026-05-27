import Foundation
import WebKit

/// Userscript metadata parsed from // ==UserScript== ... // ==/UserScript== block.
struct UserScriptMeta: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var matchPatterns: [String]
    var excludePatterns: [String]
    var runAt: String // document-start, document-end, document-idle
    var grants: [String]
    var noframes: Bool
    var version: String
    var isEnabled: Bool
    var source: String // the full JS source

    init(id: UUID = UUID(), source: String) {
        self.id = id
        self.source = source
        self.name = ""
        self.description = ""
        self.matchPatterns = []
        self.excludePatterns = []
        self.runAt = "document-end"
        self.grants = []
        self.noframes = false
        self.version = ""
        self.isEnabled = true
        parseMetadata()
    }

    private mutating func parseMetadata() {
        guard let startRange = source.range(of: "// ==UserScript=="),
              let endRange = source.range(of: "// ==/UserScript==") else { return }

        let metaBlock = source[startRange.upperBound..<endRange.lowerBound]
        for line in metaBlock.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("//") else { continue }
            let content = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)

            if content.hasPrefix("@name ") {
                name = String(content.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if content.hasPrefix("@description ") {
                description = String(content.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            } else if content.hasPrefix("@match ") {
                matchPatterns.append(String(content.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } else if content.hasPrefix("@include ") {
                matchPatterns.append(String(content.dropFirst(9)).trimmingCharacters(in: .whitespaces))
            } else if content.hasPrefix("@exclude-match ") {
                excludePatterns.append(String(content.dropFirst(15)).trimmingCharacters(in: .whitespaces))
            } else if content.hasPrefix("@exclude ") {
                excludePatterns.append(String(content.dropFirst(9)).trimmingCharacters(in: .whitespaces))
            } else if content.hasPrefix("@run-at ") {
                runAt = String(content.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if content.hasPrefix("@grant ") {
                grants.append(String(content.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } else if content.hasPrefix("@version ") {
                version = String(content.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if content == "@noframes" {
                noframes = true
            }
        }

        if name.isEmpty {
            name = "Untitled Script"
        }
    }
}

/// Manages user-installed scripts with Greasemonkey API compatibility.
@MainActor
final class CanopyUserScriptManager: ObservableObject {
    static let shared = CanopyUserScriptManager()

    @Published var scripts: [UserScriptMeta] = []

    private let storageKey = "canopy.userscripts"
    private let scriptStoragePrefix = "canopy.userscript.storage."

    private init() {
        loadScripts()
    }

    // MARK: - Script management

    func addScript(source: String) -> UserScriptMeta {
        var meta = UserScriptMeta(source: source)
        scripts.append(meta)
        saveScripts()
        return meta
    }

    func removeScript(id: UUID) {
        scripts.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: scriptStoragePrefix + id.uuidString)
        saveScripts()
    }

    func toggleScript(id: UUID, enabled: Bool) {
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx].isEnabled = enabled
            saveScripts()
        }
    }

    func updateScript(id: UUID, source: String) {
        if let idx = scripts.firstIndex(where: { $0.id == id }) {
            scripts[idx] = UserScriptMeta(id: id, source: source)
            scripts[idx].isEnabled = true
            saveScripts()
        }
    }

    // MARK: - URL matching

    func scriptsMatching(url: URL) -> [UserScriptMeta] {
        scripts.filter { $0.isEnabled && matches(url: url, meta: $0) }
    }

    private func matches(url: URL, meta: UserScriptMeta) -> Bool {
        let urlString = url.absoluteString

        for exclude in meta.excludePatterns {
            if matchesPattern(urlString, pattern: exclude) { return false }
        }

        if meta.matchPatterns.isEmpty { return false }

        for pattern in meta.matchPatterns {
            if matchesPattern(urlString, pattern: pattern) { return true }
        }
        return false
    }

    private func matchesPattern(_ url: String, pattern: String) -> Bool {
        if pattern == "*" || pattern == "*://*/*" { return true }

        // Convert match pattern to regex
        var regex = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "*", with: ".*")
            .replacingOccurrences(of: "?", with: "\\?")

        if !regex.hasPrefix(".*") && !regex.hasPrefix("http") {
            regex = ".*" + regex
        }

        return (try? NSRegularExpression(pattern: "^" + regex + "$", options: .caseInsensitive))?.firstMatch(
            in: url, range: NSRange(url.startIndex..., in: url)
        ) != nil
    }

    // MARK: - Injection

    func injectScripts(for url: URL, in webView: WKWebView) {
        let matched = scriptsMatching(url: url)
        for script in matched {
            let wrapped = wrapWithGMApi(script: script)
            let injectionTime: WKUserScriptInjectionTime = script.runAt == "document-start" ? .atDocumentStart : .atDocumentEnd
            webView.evaluateJavaScript(wrapped, completionHandler: nil)
        }
    }

    private func wrapWithGMApi(script: UserScriptMeta) -> String {
        let scriptId = script.id.uuidString
        return """
        (function() {
            'use strict';
            var GM_info = {script: {name: '\(script.name.replacingOccurrences(of: "'", with: "\\'"))', version: '\(script.version)', description: '\(script.description.replacingOccurrences(of: "'", with: "\\'"))'}};
            var GM = {
                info: GM_info,
                getValue: function(key, def) {
                    try {
                        var store = JSON.parse(localStorage.getItem('__canopy_gm_\(scriptId)') || '{}');
                        return (key in store) ? store[key] : def;
                    } catch(e) { return def; }
                },
                setValue: function(key, val) {
                    try {
                        var store = JSON.parse(localStorage.getItem('__canopy_gm_\(scriptId)') || '{}');
                        store[key] = val;
                        localStorage.setItem('__canopy_gm_\(scriptId)', JSON.stringify(store));
                    } catch(e) {}
                },
                deleteValue: function(key) {
                    try {
                        var store = JSON.parse(localStorage.getItem('__canopy_gm_\(scriptId)') || '{}');
                        delete store[key];
                        localStorage.setItem('__canopy_gm_\(scriptId)', JSON.stringify(store));
                    } catch(e) {}
                },
                listValues: function() {
                    try {
                        return Object.keys(JSON.parse(localStorage.getItem('__canopy_gm_\(scriptId)') || '{}'));
                    } catch(e) { return []; }
                },
                addStyle: function(css) {
                    var s = document.createElement('style');
                    s.textContent = css;
                    (document.head || document.documentElement).appendChild(s);
                },
                notification: function(text) { /* no-op in WKWebView */ },
                setClipboard: function(text) {
                    try { navigator.clipboard.writeText(text); } catch(e) {}
                },
                xmlhttpRequest: function(opts) {
                    var xhr = new XMLHttpRequest();
                    xhr.open(opts.method || 'GET', opts.url);
                    if (opts.headers) { for (var k in opts.headers) xhr.setRequestHeader(k, opts.headers[k]); }
                    xhr.onload = function() { if (opts.onload) opts.onload({responseText:xhr.responseText,status:xhr.status,responseHeaders:xhr.getAllResponseHeaders()}); };
                    xhr.onerror = function() { if (opts.onerror) opts.onerror({error:'Network error'}); };
                    xhr.send(opts.data || null);
                }
            };
            var GM_getValue = function(k,d){return GM.getValue(k,d)};
            var GM_setValue = function(k,v){GM.setValue(k,v)};
            var GM_deleteValue = function(k){GM.deleteValue(k)};
            var GM_listValues = function(){return GM.listValues()};
            var GM_addStyle = function(css){GM.addStyle(css)};
            var GM_xmlhttpRequest = function(o){GM.xmlhttpRequest(o)};
            var GM_setClipboard = function(t){GM.setClipboard(t)};
            var GM_notification = function(t){GM.notification(t)};
            \(script.source)
        })();
        """
    }

    // MARK: - Persistence

    private func saveScripts() {
        if let data = try? JSONEncoder().encode(scripts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadScripts() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let loaded = try? JSONDecoder().decode([UserScriptMeta].self, from: data) else { return }
        scripts = loaded
    }

    // MARK: - Install from URL

    func installFromURL(_ url: URL) async -> UserScriptMeta? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let source = String(data: data, encoding: .utf8) else { return nil }
            return addScript(source: source)
        } catch {
            return nil
        }
    }
}
