import Foundation
import WebKit

@MainActor
final class CanopyCosmeticManager {
    static let shared = CanopyCosmeticManager()

    private var domainSelectors: [String: [String]] = [:]

    private init() {
        loadRules()
    }

    private func loadRules() {
        guard let url = Bundle.main.url(forResource: "cosmetic_domains", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
        domainSelectors = dict
    }

    func selectorsForHost(_ host: String?) -> [String]? {
        guard let host = host?.lowercased() else { return nil }

        if let exact = domainSelectors[host] { return exact }

        var parts = host.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            let parent = parts.joined(separator: ".")
            if let selectors = domainSelectors[parent] { return selectors }
        }
        return nil
    }

    func injectCosmeticRules(for url: URL, in webView: WKWebView) {
        guard let selectors = selectorsForHost(url.host), !selectors.isEmpty else { return }

        let escaped = selectors.map { sel in
            sel.replacingOccurrences(of: "\\", with: "\\\\")
               .replacingOccurrences(of: "'", with: "\\'")
               .replacingOccurrences(of: "\n", with: "")
        }

        let joined = escaped.joined(separator: ",")
        let script = """
        (function() {
            try {
                var s = document.createElement('style');
                s.textContent = '\(joined) { display: none !important; }';
                (document.head || document.documentElement).appendChild(s);
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
