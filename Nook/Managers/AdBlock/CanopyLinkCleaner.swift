import Foundation
import WebKit

/// Intercepts tracking redirect URLs and navigates directly to the destination.
/// Also detects AMP pages and redirects to the canonical URL.
@MainActor
final class CanopyLinkCleaner {
    static let shared = CanopyLinkCleaner()

    private let trackingRedirectsEnabledKey = "canopy.trackingRedirects.enabled"
    private let ampRedirectEnabledKey = "canopy.ampRedirect.enabled"

    var isTrackingRedirectsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: trackingRedirectsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: trackingRedirectsEnabledKey) }
    }

    var isAmpRedirectEnabled: Bool {
        get { UserDefaults.standard.object(forKey: ampRedirectEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: ampRedirectEnabledKey) }
    }

    private init() {}

    // MARK: - Tracking redirect unwrapping

    func unwrapTrackingRedirect(_ url: URL) -> URL? {
        guard isTrackingRedirectsEnabled else { return nil }
        guard let host = url.host?.lowercased() else { return nil }

        // Google search result tracking
        if (host == "www.google.com" || host == "google.com") && url.path == "/url" {
            return extractParam(from: url, name: "q") ?? extractParam(from: url, name: "url")
        }

        // Google AMP viewer
        if host == "www.google.com" && url.path.hasPrefix("/amp/s/") {
            let ampPath = String(url.path.dropFirst("/amp/s/".count))
            return URL(string: "https://\(ampPath)")
        }

        // Facebook external link tracker
        if (host == "l.facebook.com" || host == "lm.facebook.com") && url.path == "/l.php" {
            return extractParam(from: url, name: "u")
        }

        // Facebook Messenger link tracker
        if host == "l.messenger.com" && url.path == "/l.php" {
            return extractParam(from: url, name: "u")
        }

        // Instagram redirect
        if host == "l.instagram.com" {
            return extractParam(from: url, name: "u")
        }

        // Twitter/X link tracker
        if host == "t.co" {
            return nil // t.co does HTTP redirect, let it pass through
        }

        // Reddit outbound tracking
        if (host == "out.reddit.com" || host == "www.reddit.com") && url.path == "/outbound" {
            return extractParam(from: url, name: "url")
        }

        // YouTube redirect
        if (host == "www.youtube.com" || host == "youtube.com") && url.path == "/redirect" {
            return extractParam(from: url, name: "q")
        }

        // Bing search tracking
        if host.hasSuffix(".bing.com") && url.path == "/ck/a" {
            return extractParam(from: url, name: "u")
        }

        // Steam external link warning
        if host == "steamcommunity.com" && url.path == "/linkfilter/" {
            return extractParam(from: url, name: "url") ?? extractParam(from: url, name: "u")
        }

        // Mozilla tracking
        if host == "incoming.telemetry.mozilla.org" || (host.hasSuffix(".mozilla.org") && url.path.contains("/redirect")) {
            return extractParam(from: url, name: "url")
        }

        // LinkedIn tracking
        if host == "www.linkedin.com" && url.path.hasPrefix("/safety/go") {
            return extractParam(from: url, name: "url") ?? extractParam(from: url, name: "trk")
        }

        return nil
    }

    private func extractParam(from url: URL, name: String) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == name })?.value,
              !value.isEmpty,
              let decoded = value.removingPercentEncoding ?? value as String?,
              let result = URL(string: decoded),
              let scheme = result.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return result
    }

    // MARK: - AMP redirect

    /// Returns a canonical URL script to inject at document end on potential AMP pages.
    /// The script checks for `<link rel="canonical">` and posts a message if found.
    nonisolated static func ampDetectionScript() -> WKUserScript {
        func buildOnMain() -> WKUserScript {
            MainActor.assumeIsolated {
        let source = """
        (function() {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.canopyAmpRedirect) return;
            if (window !== window.top) return;
            try {
                var isAmp = document.documentElement.hasAttribute('amp') ||
                            document.documentElement.hasAttribute('⚡') ||
                            document.querySelector('script[src*="ampproject.org"]') !== null ||
                            window.location.hostname.indexOf('amp.') === 0 ||
                            window.location.pathname.indexOf('/amp/') !== -1 ||
                            window.location.pathname.endsWith('/amp');
                if (!isAmp) return;
                var link = document.querySelector('link[rel="canonical"]');
                if (link && link.href && link.href !== window.location.href) {
                    window.webkit.messageHandlers.canopyAmpRedirect.postMessage(link.href);
                }
            } catch(e) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            }
        }
        if Thread.isMainThread { return buildOnMain() }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    func handleAmpRedirect(_ message: WKScriptMessage, webView: WKWebView?) {
        guard isAmpRedirectEnabled,
              let urlString = message.body as? String,
              let canonical = URL(string: urlString),
              let scheme = canonical.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let webView = webView else { return }
        webView.load(URLRequest(url: canonical))
    }
}
