import Foundation
import WebKit

@MainActor
final class CanopyBlockPageManager {
    static let shared = CanopyBlockPageManager()

    private init() {}

    func showBlockPage(for url: URL, in webView: WKWebView) {
        let host = url.host ?? url.absoluteString
        let safeURL = url.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let safeHost = host
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Blocked — Canopy</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif;
                    background: #1a1a2e;
                    color: #e0e0e0;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    min-height: 100vh;
                    -webkit-font-smoothing: antialiased;
                }
                @media (prefers-color-scheme: light) {
                    body { background: #f5f5f7; color: #1d1d1f; }
                    .card { background: #ffffff; border-color: #d2d2d7; }
                    .url-box { background: #f5f5f7; color: #1d1d1f; }
                    .shield { color: #34c759; }
                    h1 { color: #1d1d1f; }
                    .info { color: #86868b; }
                    .proceed { border-color: #d2d2d7; color: #86868b; }
                    .proceed:hover { border-color: #ff3b30; color: #ff3b30; }
                }
                .card {
                    background: #16213e;
                    border: 1px solid #0f3460;
                    border-radius: 16px;
                    max-width: 520px;
                    width: 90%;
                    padding: 2.5rem;
                    text-align: center;
                }
                .shield {
                    font-size: 3rem;
                    margin-bottom: 0.5rem;
                    color: #50fa7b;
                }
                h1 {
                    font-size: 1.25rem;
                    font-weight: 600;
                    margin-bottom: 1rem;
                    color: #f8f8f2;
                }
                .url-box {
                    font-family: 'SF Mono', Menlo, monospace;
                    font-size: 0.8rem;
                    background: #0f3460;
                    padding: 0.75rem 1rem;
                    border-radius: 8px;
                    word-break: break-all;
                    color: #a8d8ea;
                    margin-bottom: 1.25rem;
                    text-align: left;
                }
                .info {
                    font-size: 0.85rem;
                    color: #8892b0;
                    margin-bottom: 1.5rem;
                    line-height: 1.5;
                }
                .actions {
                    display: flex;
                    gap: 12px;
                    justify-content: center;
                    flex-wrap: wrap;
                }
                .proceed {
                    padding: 0.5rem 1.2rem;
                    background: none;
                    border: 1px solid #334;
                    border-radius: 8px;
                    color: #556;
                    cursor: pointer;
                    font-size: 0.85rem;
                    font-family: inherit;
                    transition: all 0.15s;
                }
                .proceed:hover {
                    border-color: #ff6b6b;
                    color: #ff6b6b;
                }
                .go-back {
                    padding: 0.5rem 1.2rem;
                    background: #50fa7b;
                    border: none;
                    border-radius: 8px;
                    color: #1a1a2e;
                    cursor: pointer;
                    font-size: 0.85rem;
                    font-weight: 600;
                    font-family: inherit;
                    transition: all 0.15s;
                }
                .go-back:hover { opacity: 0.85; }
            </style>
        </head>
        <body>
            <div class="card">
                <div class="shield">🛡</div>
                <h1>Page Blocked by Canopy</h1>
                <div class="url-box">\(safeURL)</div>
                <p class="info">
                    <strong>\(safeHost)</strong> was blocked because it appears on known
                    ad-serving or tracking filter lists. This protects your privacy and
                    keeps your browsing fast.
                </p>
                <div class="actions">
                    <button class="go-back" onclick="history.back()">Go Back</button>
                    <button class="proceed" onclick="window.webkit.messageHandlers.canopyProceed.postMessage('\(url.absoluteString)')">
                        Proceed anyway
                    </button>
                </div>
            </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
