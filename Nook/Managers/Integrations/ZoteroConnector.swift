import Foundation
import WebKit
import AppKit

/// Native Zotero Connector: saves the current page to Zotero desktop app
/// via its local HTTP API (port 23119). Works without any browser extension.
@MainActor
final class ZoteroConnector {
    static let shared = ZoteroConnector()

    private let baseURL = "http://127.0.0.1:23119"

    private init() {}

    /// Save the current page to Zotero. Extracts metadata from the webview and POSTs to Zotero's connector API.
    func saveCurrentPage(from webView: WKWebView) {
        let script = """
        (function() {
            var meta = {};
            meta.url = location.href;
            meta.title = document.title;

            // DOI
            var doiMeta = document.querySelector('meta[name="citation_doi"], meta[name="dc.identifier"], meta[name="DC.Identifier"]');
            if (doiMeta) meta.doi = doiMeta.getAttribute('content');

            // Authors
            var authors = [];
            document.querySelectorAll('meta[name="citation_author"], meta[name="dc.creator"], meta[name="DC.Creator"], meta[name="author"]').forEach(function(el) {
                var name = el.getAttribute('content');
                if (name) authors.push(name);
            });
            if (authors.length > 0) meta.authors = authors;

            // Date
            var dateMeta = document.querySelector('meta[name="citation_date"], meta[name="dc.date"], meta[name="DC.Date"], meta[name="date"], meta[property="article:published_time"]');
            if (dateMeta) meta.date = dateMeta.getAttribute('content');

            // Publication
            var pubMeta = document.querySelector('meta[name="citation_journal_title"], meta[name="dc.publisher"], meta[name="DC.Publisher"]');
            if (pubMeta) meta.publication = pubMeta.getAttribute('content');

            // Abstract
            var absMeta = document.querySelector('meta[name="citation_abstract"], meta[name="description"], meta[property="og:description"]');
            if (absMeta) meta.abstract = absMeta.getAttribute('content');

            // ISBN/ISSN
            var isbnMeta = document.querySelector('meta[name="citation_isbn"]');
            if (isbnMeta) meta.isbn = isbnMeta.getAttribute('content');
            var issnMeta = document.querySelector('meta[name="citation_issn"]');
            if (issnMeta) meta.issn = issnMeta.getAttribute('content');

            // Selected text
            var sel = window.getSelection();
            if (sel && sel.toString().trim().length > 0) meta.selectedText = sel.toString().trim();

            // Full HTML for snapshot
            meta.html = document.documentElement.outerHTML;

            return meta;
        })();
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, let meta = result as? [String: Any] else {
                self?.showAlert(title: "Zotero Error", message: "Could not extract page metadata.")
                return
            }
            Task { await self.sendToZotero(meta: meta) }
        }
    }

    private func sendToZotero(meta: [String: Any]) async {
        // First check if Zotero is running
        guard await isZoteroRunning() else {
            showAlert(title: "Zotero Not Running", message: "Please open the Zotero desktop app and try again.")
            return
        }

        // Build the saveSnapshot payload
        var payload: [String: Any] = [
            "url": meta["url"] ?? "",
            "title": meta["title"] ?? "",
            "sessionID": UUID().uuidString,
        ]

        // Add optional metadata
        if let html = meta["html"] as? String {
            payload["html"] = html
        }
        if let doi = meta["doi"] as? String {
            payload["DOI"] = doi
        }

        // Try saveSnapshot first (saves full page)
        do {
            let url = URL(string: "\(baseURL)/connector/saveSnapshot")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 {
                showSuccessNotification(title: meta["title"] as? String ?? "Page")
                return
            }
        } catch {}

        // Fallback: try savePage
        do {
            let url = URL(string: "\(baseURL)/connector/savePage")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 10

            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 {
                showSuccessNotification(title: meta["title"] as? String ?? "Page")
                return
            }
        } catch {}

        showAlert(title: "Save Failed", message: "Could not save to Zotero. Make sure Zotero is running and the connector is enabled.")
    }

    private func isZoteroRunning() async -> Bool {
        do {
            let url = URL(string: "\(baseURL)/connector/ping")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func showSuccessNotification(title: String) {
        let alert = NSAlert()
        alert.messageText = "Saved to Zotero"
        alert.informativeText = "\"\(title)\" has been saved to your Zotero library."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
