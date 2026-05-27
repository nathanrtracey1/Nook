import Foundation
import WebKit

@MainActor
final class CanopyStatsManager: ObservableObject {
    static let shared = CanopyStatsManager()

    @Published private(set) var sessionBlockCount: Int = 0
    @Published private(set) var totalBlockCount: Int = 0

    private let totalBlockCountKey = "canopy.totalBlockCount"

    private init() {
        totalBlockCount = UserDefaults.standard.integer(forKey: totalBlockCountKey)
    }

    func recordBlock() {
        sessionBlockCount += 1
        totalBlockCount += 1
        persistIfNeeded()
    }

    func recordBlocks(_ count: Int) {
        guard count > 0 else { return }
        sessionBlockCount += count
        totalBlockCount += count
        persistIfNeeded()
    }

    func resetSession() {
        sessionBlockCount = 0
    }

    var formattedSessionCount: String {
        formatCount(sessionBlockCount)
    }

    var formattedTotalCount: String {
        formatCount(totalBlockCount)
    }

    private var lastPersist: Date = .distantPast
    private func persistIfNeeded() {
        let now = Date()
        if now.timeIntervalSince(lastPersist) > 5 {
            UserDefaults.standard.set(totalBlockCount, forKey: totalBlockCountKey)
            lastPersist = now
        }
    }

    func persistNow() {
        UserDefaults.standard.set(totalBlockCount, forKey: totalBlockCountKey)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    /// User script that counts hidden ad elements and reports back.
    /// Runs at document end after cosmetic filtering has applied.
    nonisolated static func countingScript() -> WKUserScript {
        func buildOnMain() -> WKUserScript {
            MainActor.assumeIsolated {
        let source = """
        (function() {
            if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.canopyStats) return;
            if (window !== window.top) return;
            var count = 0;
            try {
                var hidden = document.querySelectorAll('[style*="display: none"][data-canopy-hidden], [style*="display:none"][data-canopy-hidden]');
                count += hidden.length;
                var observer = new PerformanceObserver(function(list) {
                    var blocked = 0;
                    list.getEntries().forEach(function(e) {
                        if (e.transferSize === 0 && e.decodedBodySize === 0 && e.name.match(/doubleclick|googlesyndication|googletagmanager|facebook\\.net|analytics/)) {
                            blocked++;
                        }
                    });
                    if (blocked > 0) {
                        window.webkit.messageHandlers.canopyStats.postMessage({ type: 'blocked', count: blocked });
                    }
                });
                observer.observe({ type: 'resource', buffered: true });
            } catch(e) {}
            setTimeout(function() {
                try {
                    var ads = document.querySelectorAll('[style*="display: none"], [hidden]');
                    var adCount = 0;
                    ads.forEach(function(el) {
                        var cl = (el.className || '').toLowerCase();
                        var id = (el.id || '').toLowerCase();
                        if (cl.match(/ad[s_-]|banner|sponsor|promo/) || id.match(/ad[s_-]|banner|sponsor|promo/)) {
                            adCount++;
                        }
                    });
                    if (adCount > 0) {
                        window.webkit.messageHandlers.canopyStats.postMessage({ type: 'cosmetic', count: adCount });
                    }
                } catch(e) {}
            }, 2000);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            }
        }
        if Thread.isMainThread { return buildOnMain() }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    func handleMessage(_ message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let count = dict["count"] as? Int,
              count > 0 else { return }
        recordBlocks(count)
    }
}
