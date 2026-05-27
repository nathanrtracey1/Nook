import Foundation
import WebKit

/// Reader mode: extracts article content and renders it in a clean, customizable layout.
@MainActor
final class CanopyReaderMode {
    static let shared = CanopyReaderMode()

    private let fontKey = "canopy.reader.font"
    private let sizeKey = "canopy.reader.size"
    private let themeKey = "canopy.reader.theme"
    private let widthKey = "canopy.reader.width"

    var font: String {
        get { UserDefaults.standard.string(forKey: fontKey) ?? "Georgia" }
        set { UserDefaults.standard.set(newValue, forKey: fontKey) }
    }
    var fontSize: Int {
        get { UserDefaults.standard.object(forKey: sizeKey) as? Int ?? 19 }
        set { UserDefaults.standard.set(newValue, forKey: sizeKey) }
    }
    var theme: String {
        get { UserDefaults.standard.string(forKey: themeKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: themeKey) }
    }
    var contentWidth: Int {
        get { UserDefaults.standard.object(forKey: widthKey) as? Int ?? 680 }
        set { UserDefaults.standard.set(newValue, forKey: widthKey) }
    }

    static let availableFonts = ["Georgia", "Charter", "Palatino", "Times New Roman", "Helvetica Neue", "SF Pro Text", "Avenir Next", "Iowan Old Style", "Athelas"]
    static let availableThemes = ["auto", "light", "sepia", "dark", "black"]

    private init() {}

    func activate(in webView: WKWebView) {
        let script = Self.extractionScript
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, let dict = result as? [String: Any],
                  let title = dict["title"] as? String,
                  let content = dict["content"] as? String,
                  let siteName = dict["siteName"] as? String? else { return }
            let byline = dict["byline"] as? String
            let html = self.buildReaderHTML(title: title, content: content, byline: byline, siteName: siteName ?? "", originalURL: webView.url?.absoluteString ?? "")
            webView.loadHTMLString(html, baseURL: webView.url)
        }
    }

    // MARK: - Article extraction JS (simplified Readability-like)

    nonisolated static let extractionScript = """
    (function() {
        function getMetaContent(name) {
            var el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
            return el ? el.getAttribute('content') : null;
        }

        var title = document.title;
        var ogTitle = getMetaContent('og:title');
        if (ogTitle) title = ogTitle;

        var siteName = getMetaContent('og:site_name') || '';
        var byline = '';
        var authorEl = document.querySelector('[rel="author"], .author, .byline, [itemprop="author"]');
        if (authorEl) byline = authorEl.textContent.trim();
        if (!byline) byline = getMetaContent('author') || '';

        // Find the main content
        var candidates = ['article', '[role="main"]', 'main', '.post-content', '.article-content',
            '.entry-content', '.story-body', '#article-body', '.article__body',
            '.post-body', '.content-body', '.articleBody'];
        var content = null;
        for (var i = 0; i < candidates.length; i++) {
            var el = document.querySelector(candidates[i]);
            if (el && el.textContent.trim().length > 200) {
                content = el;
                break;
            }
        }

        if (!content) {
            // Fallback: find the largest text block
            var paragraphs = document.querySelectorAll('p');
            var bestParent = null;
            var bestScore = 0;
            paragraphs.forEach(function(p) {
                var parent = p.parentElement;
                if (!parent) return;
                var score = (parent.__readScore || 0) + p.textContent.trim().length;
                parent.__readScore = score;
                if (score > bestScore) { bestScore = score; bestParent = parent; }
            });
            content = bestParent;
        }

        if (!content) return null;

        // Clean up the content
        var clone = content.cloneNode(true);
        var removals = clone.querySelectorAll('script, style, nav, .ad, .advertisement, .social-share, .comments, .sidebar, [role="complementary"], .related-posts, .newsletter-signup, iframe:not([src*="youtube"]):not([src*="vimeo"])');
        removals.forEach(function(el) { el.remove(); });

        return {
            title: title,
            content: clone.innerHTML,
            byline: byline,
            siteName: siteName
        };
    })();
    """

    // MARK: - Reader HTML

    private func buildReaderHTML(title: String, content: String, byline: String?, siteName: String, originalURL: String) -> String {
        let safeTitle = title.replacingOccurrences(of: "<", with: "&lt;")
        let safeSiteName = siteName.replacingOccurrences(of: "<", with: "&lt;")
        let safeByline = (byline ?? "").replacingOccurrences(of: "<", with: "&lt;")

        let themeCSS: String
        switch theme {
        case "light": themeCSS = "background:#fff;color:#1d1d1f;"
        case "sepia": themeCSS = "background:#f4ecd8;color:#433422;"
        case "dark": themeCSS = "background:#1c1c1e;color:#e0e0e0;"
        case "black": themeCSS = "background:#000;color:#d0d0d0;"
        default: themeCSS = "background:var(--bg);color:var(--fg);"
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(safeTitle) — Reader</title>
            <style>
                :root { --bg: #fff; --fg: #1d1d1f; --subtle: #86868b; --border: #d2d2d7; --link: #0066cc; }
                @media (prefers-color-scheme: dark) {
                    :root { --bg: #1c1c1e; --fg: #e0e0e0; --subtle: #8e8e93; --border: #38383a; --link: #64d2ff; }
                }
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: '\(font)', Georgia, serif;
                    font-size: \(fontSize)px;
                    line-height: 1.7;
                    \(themeCSS)
                    -webkit-font-smoothing: antialiased;
                    padding: 60px 20px 120px;
                }
                .reader-container {
                    max-width: \(contentWidth)px;
                    margin: 0 auto;
                }
                .reader-toolbar {
                    position: fixed;
                    top: 12px;
                    right: 20px;
                    z-index: 100;
                    display: flex;
                    gap: 8px;
                    align-items: center;
                    background: rgba(128,128,128,0.12);
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                    padding: 6px 12px;
                    border-radius: 10px;
                    font-size: 13px;
                }
                .reader-toolbar button, .reader-toolbar select {
                    background: rgba(128,128,128,0.15);
                    border: none;
                    color: inherit;
                    padding: 4px 10px;
                    border-radius: 6px;
                    cursor: pointer;
                    font: inherit;
                    font-size: 12px;
                }
                .reader-toolbar button:hover { background: rgba(128,128,128,0.3); }
                .reader-meta {
                    margin-bottom: 32px;
                    padding-bottom: 20px;
                    border-bottom: 1px solid var(--border);
                }
                .reader-site { font-size: 0.75em; text-transform: uppercase; letter-spacing: 0.05em; color: var(--subtle); margin-bottom: 8px; }
                .reader-title { font-size: 2.2em; font-weight: 700; line-height: 1.2; margin-bottom: 12px; }
                .reader-byline { font-size: 0.85em; color: var(--subtle); }
                .reader-content h1, .reader-content h2, .reader-content h3 { margin: 1.5em 0 0.5em; font-weight: 600; }
                .reader-content h2 { font-size: 1.4em; }
                .reader-content h3 { font-size: 1.2em; }
                .reader-content p { margin-bottom: 1.2em; }
                .reader-content img { max-width: 100%; height: auto; border-radius: 8px; margin: 1em 0; }
                .reader-content a { color: var(--link); }
                .reader-content blockquote {
                    border-left: 3px solid var(--subtle);
                    padding-left: 1em;
                    margin: 1em 0;
                    color: var(--subtle);
                    font-style: italic;
                }
                .reader-content pre, .reader-content code {
                    font-family: 'SF Mono', Menlo, monospace;
                    font-size: 0.85em;
                    background: rgba(128,128,128,0.1);
                    padding: 2px 6px;
                    border-radius: 4px;
                }
                .reader-content pre { padding: 1em; overflow-x: auto; margin: 1em 0; }
                .reader-content ul, .reader-content ol { margin: 1em 0; padding-left: 1.5em; }
                .reader-content li { margin-bottom: 0.4em; }
                .reader-content figure { margin: 1.5em 0; }
                .reader-content figcaption { font-size: 0.8em; color: var(--subtle); text-align: center; margin-top: 8px; }
            </style>
        </head>
        <body>
            <div class="reader-toolbar">
                <button onclick="changeFontSize(-1)">A−</button>
                <button onclick="changeFontSize(1)">A+</button>
                <select onchange="changeFont(this.value)" id="fontSelect">
                    <option value="Georgia">Georgia</option>
                    <option value="Charter">Charter</option>
                    <option value="Palatino">Palatino</option>
                    <option value="Helvetica Neue">Helvetica</option>
                    <option value="Avenir Next">Avenir</option>
                    <option value="Iowan Old Style">Iowan</option>
                    <option value="Athelas">Athelas</option>
                </select>
                <select onchange="changeTheme(this.value)" id="themeSelect">
                    <option value="auto">Auto</option>
                    <option value="light">Light</option>
                    <option value="sepia">Sepia</option>
                    <option value="dark">Dark</option>
                    <option value="black">Black</option>
                </select>
                <button onclick="changeWidth(-60)">Narrower</button>
                <button onclick="changeWidth(60)">Wider</button>
            </div>
            <div class="reader-container">
                <div class="reader-meta">
                    \(safeSiteName.isEmpty ? "" : "<div class='reader-site'>\(safeSiteName)</div>")
                    <div class="reader-title">\(safeTitle)</div>
                    \(safeByline.isEmpty ? "" : "<div class='reader-byline'>\(safeByline)</div>")
                </div>
                <div class="reader-content">\(content)</div>
            </div>
            <script>
                document.getElementById('fontSelect').value = '\(font)';
                document.getElementById('themeSelect').value = '\(theme)';
                var currentSize = \(fontSize);
                var currentWidth = \(contentWidth);
                function changeFontSize(delta) {
                    currentSize = Math.max(12, Math.min(32, currentSize + delta));
                    document.body.style.fontSize = currentSize + 'px';
                }
                function changeFont(f) {
                    document.body.style.fontFamily = "'" + f + "', Georgia, serif";
                }
                function changeTheme(t) {
                    var themes = {light:'background:#fff;color:#1d1d1f',sepia:'background:#f4ecd8;color:#433422',dark:'background:#1c1c1e;color:#e0e0e0',black:'background:#000;color:#d0d0d0',auto:''};
                    if (t === 'auto') { document.body.style.cssText = document.body.style.cssText.replace(/background:[^;]+;color:[^;]+;/,''); }
                    else { document.body.style.background = themes[t].split(';')[0].split(':')[1]; document.body.style.color = themes[t].split(';')[1].split(':')[1]; }
                }
                function changeWidth(delta) {
                    currentWidth = Math.max(400, Math.min(1000, currentWidth + delta));
                    document.querySelector('.reader-container').style.maxWidth = currentWidth + 'px';
                }
            </script>
        </body>
        </html>
        """
    }
}
