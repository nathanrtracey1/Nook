import Foundation
import WebKit

/// High-performance, native adblock engine coordinator.
/// - Data layer: domain trie (+ optional bloom precheck)
/// - Static layer: WKContentRuleListStore compiled rules (handled by existing ContentBlockerManager)
/// - Dynamic layer: scriptlets injected at document_start (via CustomFeatureRegistry)
@MainActor
final class NookAdBlockManager {
    static let shared = NookAdBlockManager()

    private weak var browserManager: BrowserManager?

    private var domainFilter: NookDomainFilter?

    private init() {}

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    /// Compile domain trie from enabled sources in the background.
    /// This is separate from WKContentRuleList compilation (which is handled by ContentBlockerManager).
    func rebuildDomainFilterInBackground(from texts: [String]) {
        Task.detached(priority: .utility) { [weak self] in
            let joined = texts.joined(separator: "\n")
            let domains = NookRuleCompiler.parseUBODomainList(joined)
            let filter = NookDomainFilter(domains: domains)
            await MainActor.run {
                self?.domainFilter = filter
            }
        }
    }

    /// Fast host check used in main-frame navigation decisions.
    func shouldBlockMainFrame(url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if browserManager?.nookSettings?.contentBlockerAllowlist.contains(host) == true {
            return false
        }
        if CanopyAdBlockManager.shared.bypassedHosts.contains(host) { return false }
        return domainFilter?.matches(host: host) ?? false
    }
}

