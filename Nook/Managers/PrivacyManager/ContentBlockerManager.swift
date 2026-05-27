//
//  ContentBlockerManager.swift
//  Nook
//
//  Nook-native content blocker that ingests uBlock Origin/uAssets-style
//  filter lists, compiles a subset of rules to WKContentRuleList JSON,
//  and installs the compiled list into the shared WKWebViewConfiguration.
//
//  This is intentionally conservative for a first pass:
//  - Supports host-based network filters of the form `||example.com^`
//    from uAssets default lists (ads + privacy).
//  - Ignores cosmetic filters (##, #@#) and advanced modifiers.
//  - Supports a per-domain allowlist using `ignore-previous-rules` rules.
//

import Foundation
import WebKit

@MainActor
final class ContentBlockerManager {
    weak var browserManager: BrowserManager?

    /// Backing flag used to keep track of current enabled state.
    private(set) var isEnabled: Bool = false

    /// Identifier used by WKContentRuleListStore for the compiled rule list.
    private let ruleListIdentifier = "NookContentBlocker_v1"

    /// Currently installed, compiled rule list (if any).
    private var installedRuleList: WKContentRuleList?

    /// Domains where the blocker should be disabled entirely.
    private var allowedDomains: Set<String> = []

    /// Metadata for an external filter list we can ingest.
    struct ContentBlockerFilterList: Identifiable {
        let id: String
        let title: String
        let description: String
        let url: URL
        let defaultEnabled: Bool
    }

    /// All built-in filter lists. These mirror uBO defaults.
    private let builtinLists: [ContentBlockerFilterList] = [
        ContentBlockerFilterList(
            id: "ublock-ads",
            title: "uBlock filters — Ads",
            description: "Core uBlock Origin ad blocking rules.",
            url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.min.txt")!,
            defaultEnabled: true
        ),
        ContentBlockerFilterList(
            id: "ublock-privacy",
            title: "uBlock filters — Privacy",
            description: "Extra tracking protection and privacy rules.",
            url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt")!,
            defaultEnabled: true
        ),
        ContentBlockerFilterList(
            id: "easylist",
            title: "EasyList",
            description: "Community-maintained ad blocking list.",
            url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")!,
            defaultEnabled: true
        ),
        ContentBlockerFilterList(
            id: "easyprivacy",
            title: "EasyPrivacy",
            description: "Community-maintained tracking protection list.",
            url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")!,
            defaultEnabled: true
        ),
    ]

    /// If nil, we use the defaultEnabled flags from built-in lists (and mark custom lists enabled by default).
    /// If non-empty, only lists whose ids are present will be loaded.
    private var enabledSourceIDs: Set<String>?

    /// When true, adds extra generic blocking rules for aggressive ad removal.
    private var aggressiveMode: Bool = false

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    /// Exposes all known filter lists for Settings UI.
    func allFilterLists() -> [ContentBlockerFilterList] {
        combinedLists()
    }

    /// The IDs that should be treated as "on" based on defaults and overrides.
    func defaultEnabledIDs() -> Set<String> {
        let lists = combinedLists()
        var ids = Set(lists.filter { $0.defaultEnabled }.map { $0.id })
        // Custom lists default to enabled if there is no explicit override.
        if let settings = browserManager?.nookSettings {
            let customIDs = settings.contentBlockerCustomLists.map { $0.id }
            ids.formUnion(customIDs)
        }
        return ids
    }

    func currentEnabledSourceIDs() -> Set<String> {
        if let ids = enabledSourceIDs, !ids.isEmpty {
            return ids
        }
        return defaultEnabledIDs()
    }

    /// Override which lists are active. Passing nil or an empty set resets to defaults.
    func setEnabledSourceIDs(_ ids: Set<String>?) {
        if let ids, !ids.isEmpty {
            enabledSourceIDs = ids
        } else {
            enabledSourceIDs = nil
        }
        recompileIfNeeded()
    }

    func setAggressiveMode(_ enabled: Bool) {
        aggressiveMode = enabled
        recompileIfNeeded()
    }

    // Combines built-in lists with any custom lists defined in settings.
    private func combinedLists() -> [ContentBlockerFilterList] {
        var lists = builtinLists
        if let custom = browserManager?.nookSettings?.contentBlockerCustomLists {
            for entry in custom {
                guard let url = URL(string: entry.urlString) else { continue }
                let title = entry.name.isEmpty ? entry.urlString : entry.name
                lists.append(
                    ContentBlockerFilterList(
                        id: entry.id,
                        title: title,
                        description: entry.urlString,
                        url: url,
                        defaultEnabled: true
                    )
                )
            }
        }
        return lists
    }

    /// Global on/off switch, driven by settings.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Task { @MainActor in
            if enabled {
                await installRuleList()
                applyToExistingWebViews()
            } else {
                removeFromExistingWebViews()
            }
        }
    }

    // MARK: - Per-site allowlist

    func allowDomain(_ host: String, allowed: Bool = true) {
        let normalized = host.lowercased()
        if allowed {
            allowedDomains.insert(normalized)
            Task { await CanopyAdBlockManager.shared.addWhitelist(host: normalized) }
        } else {
            allowedDomains.remove(normalized)
            CanopyAdBlockManager.shared.removeWhitelist(host: normalized)
        }

        syncAllowlistWithSettings()
        recompileIfNeeded()
    }

    func isDomainAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowedDomains.contains(host)
    }

    /// Replace the current allowlist with a new set of hosts.
    func setAllowedDomains(_ hosts: [String]) {
        let normalized = hosts.map { $0.lowercased() }.filter { !$0.isEmpty }
        allowedDomains = Set(normalized)
        recompileIfNeeded()
    }

    private func syncAllowlistWithSettings() {
        guard let settings = browserManager?.nookSettings else { return }
        let sorted = Array(allowedDomains).sorted()
        if settings.contentBlockerAllowlist != sorted {
            settings.contentBlockerAllowlist = sorted
        }
    }

    private func recompileIfNeeded() {
        // Recompile rules so `ignore-previous-rules` exceptions are updated.
        Task { @MainActor in
            if isEnabled {
                await installRuleList(forceRecompile: true)
                applyToExistingWebViews()
            }
        }
    }

    // MARK: - Installation

    private func installRuleList(forceRecompile: Bool = false) async {
        guard let store = WKContentRuleListStore.default() else { return }

        if !forceRecompile {
            if let existing = await withCheckedContinuation(
                { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
                    store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { list, _ in
                        cont.resume(returning: list)
                    }
                }
            ) {
                installedRuleList = existing
                return
            }
        }

        let compiledJSON = await makeRuleJSON()
        let compiled = await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(
                forIdentifier: ruleListIdentifier,
                encodedContentRuleList: compiledJSON
            ) { list, error in
                if let error {
                    print("[ContentBlocker] Rule compile error: \(error)")
                }
                cont.resume(returning: list)
            }
        }

        installedRuleList = compiled
    }

    private func applyToExistingWebViews() {
        guard let bm = browserManager else { return }
        for tab in bm.tabManager.allTabs() {
            guard let wv = tab.webView else { continue }
            refreshFor(tab: tab)
        }
    }

    private func removeFromExistingWebViews() {
        guard let bm = browserManager else { return }
        for tab in bm.tabManager.allTabs() {
            guard let wv = tab.webView else { continue }
            removeBlocking(from: wv)
        }
    }

    /// Re-evaluate whether blocking should apply to this tab/webview.
    func refreshFor(tab: Tab) {
        guard let wv = tab.webView else { return }
        if shouldApply(to: tab) {
            applyBlocking(to: wv)
        } else {
            removeBlocking(from: wv)
        }
    }

    /// Updates blocking state after a completed main-frame navigation.
    func refreshForTabAfterNavigation(tab: Tab) {
        refreshFor(tab: tab)
    }

    private func shouldApply(to tab: Tab) -> Bool {
        if !isEnabled { return false }
        let url = tab.webView?.url ?? tab.url
        let host = url.host
        if ProtectedDomains.isProtectedURL(url) { return false }
        if ProtectedDomains.isProtectedHost(host) { return false }
        if isDomainAllowed(host) { return false }
        return true
    }

    private func applyBlocking(to webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        if let list = installedRuleList {
            ucc.add(list)
        }
        CanopyAdBlockManager.shared.applyTo(controller: ucc)
        WBlockBridge.shared.applyTo(controller: ucc)
        CanopyCustomListManager.shared.applyTo(controller: ucc)
    }

    private func removeBlocking(from webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
    }

    // MARK: - Rule JSON

    /// Downloads uAssets/uBO lists, parses a subset of network filters, and
    /// returns WebKit content-blocker JSON. On network failure, falls back
    /// to a small built-in host list.
    private func makeRuleJSON() async -> String {
        let lines = await fetchFilterLines()
        let rules = buildRules(from: lines)

        if let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        // Fallback: small static tracker host list if JSON encoding fails.
        let fallbackRules = Self.fallbackRules()
        if let data = try? JSONSerialization.data(withJSONObject: fallbackRules, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return "[]"
    }

    private func fetchFilterLines() async -> [String] {
        var allLines: [String] = []
        let activeIDs = currentEnabledSourceIDs()
        let lists = combinedLists()

        for source in lists where activeIDs.contains(source.id) {
            do {
                let (data, _) = try await URLSession.shared.data(from: source.url)
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
                    allLines.append(contentsOf: lines)
                }
            } catch {
                print("[ContentBlocker] Failed to download \(source.id): \(error.localizedDescription)")
            }
        }

        return allLines
    }

    private func buildRules(from lines: [String]) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        rules.reserveCapacity(20_000)

        // Limit to avoid pathological compile times; WebKit has internal caps as well.
        // Raised to 50k to capture more of EasyList/EasyPrivacy while staying performant.
        let maxRules = 50_000

        for line in lines {
            if rules.count >= maxRules {
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("!") { continue } // comments
            if trimmed.hasPrefix("[") { continue } // section headers
            if trimmed.contains("##") { continue } // cosmetic filters
            if trimmed.contains("#@#") { continue } // cosmetic exceptions
            if trimmed.hasPrefix("@@") { continue } // exception rules (not yet modeled)

            guard let domain = extractDomain(fromFilterLine: trimmed) else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            // Match subdomains as well: (^|.)example.com
            let pattern = "^[^:]+://([^/]*\\.)?\(escaped)/"

            let trigger: [String: Any] = [
                "url-filter": pattern,
                "load-type": ["third-party"],
            ]

            let action: [String: Any] = [
                "type": "block",
            ]

            rules.append([
                "trigger": trigger,
                "action": action,
            ])
        }

        // Add per-site allowlist exceptions using ignore-previous-rules.
        if !allowedDomains.isEmpty {
            let allowRules = allowedDomains.map { host -> [String: Any] in
                [
                    "trigger": [
                        "if-domain": [host],
                    ],
                    "action": [
                        "type": "ignore-previous-rules",
                    ],
                ]
            }
            rules.append(contentsOf: allowRules)
        }

        // Hard-coded "sure block" rules for stubborn networks (Playwire/RAMP/etc.)
        let sureBlockHosts: [String] = [
            "playwire.com",
            "configar.com",
            "intergi.com",
            // Spotify ad-logic endpoint (subset of akamai CDN)
            "audio-ak-spotify-com.akamaized.net"
        ]
        for host in sureBlockHosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            let pattern = "^[^:]+://([^/]*\\.)?\(escaped)/"
            rules.append([
                "trigger": [
                    "url-filter": pattern,
                    "url-filter-is-case-sensitive": true
                ],
                "action": ["type": "block"]
            ])
        }

        // Anti-detection: redirect common ad-library scripts to our stub scheme.
        // Use simple, case-sensitive patterns for performance.
        let stubRedirects: [(match: String, target: String)] = [
            ("adsbygoogle\\.js", "nookstub://adsbygoogle.js"),
            ("playwire\\.js", "nookstub://playwire.js")
        ]
        for entry in stubRedirects {
            rules.append([
                "trigger": [
                    "url-filter": entry.match,
                    "url-filter-is-case-sensitive": true
                ],
                "action": [
                    "type": "redirect",
                    "url": entry.target
                ]
            ])
        }

        // Aggressive mode: add a few generic patterns for common ad paths on third-party hosts.
        if aggressiveMode {
            let aggressivePatterns: [String] = [
                ".*\\/ads?[0-9]?\\/.*",
                ".*\\/adserver\\/.*",
                ".*\\/banners?\\/.*",
                ".*\\/promotions?\\/.*",
                ".*\\/sponsored\\/.*"
            ]
            for pattern in aggressivePatterns {
                rules.append([
                    "trigger": [
                        "url-filter": pattern,
                        "load-type": ["third-party"],
                    ],
                    "action": ["type": "block"],
                ])
            }
        }

        if rules.isEmpty {
            return Self.fallbackRules()
        }

        return rules
    }

    /// Extracts a hostname from a uBO/ABP-style filter line of the form `||example.com^`.
    private func extractDomain(fromFilterLine line: String) -> String? {
        guard line.hasPrefix("||") else { return nil }
        let withoutPrefix = String(line.dropFirst(2))

        if withoutPrefix.isEmpty { return nil }

        var endIndex = withoutPrefix.startIndex
        for index in withoutPrefix.indices {
            let ch = withoutPrefix[index]
            if ch == "^" || ch == "$" || ch == "*" || ch == "/" || ch == "?" {
                break
            }
            endIndex = withoutPrefix.index(after: index)
        }

        let candidate = String(withoutPrefix[..<endIndex]).lowercased()
        if candidate.isEmpty { return nil }
        if candidate.contains("/") { return nil }
        return candidate
    }

    /// Small built-in host list used when list download or parsing fails.
    private static func fallbackRules() -> [[String: Any]] {
        let hosts: [String] = [
            "google-analytics.com",
            "analytics.google.com",
            "googletagmanager.com",
            "googletagservices.com",
            "doubleclick.net",
            "facebook.net",
            "connect.facebook.net",
            "graph.facebook.com",
            "adsystem.com",
            "adservice.google.com",
            "hotjar.com",
            "segment.io",
            "cdn.segment.com",
            "mixpanel.com",
            "sentry.io",
            "optimizely.com",
            "newrelic.com",
            "clarity.ms",
        ]

        var rules: [[String: Any]] = []

        for host in hosts {
            let escaped = NSRegularExpression.escapedPattern(for: host)
            let pattern = "^[^:]+://([^/]*\\.)?\(escaped)/"

            let trigger: [String: Any] = [
                "url-filter": pattern,
                "load-type": ["third-party"],
            ]

            let action: [String: Any] = ["type": "block"]

            rules.append([
                "trigger": trigger,
                "action": action,
            ])
        }

        return rules
    }
}

