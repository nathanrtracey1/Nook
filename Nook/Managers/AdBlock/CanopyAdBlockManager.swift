import Foundation
import WebKit

@MainActor
final class CanopyAdBlockManager {
    static let shared = CanopyAdBlockManager()

    private(set) var isEnabled: Bool = false
    private var compiledAdList: WKContentRuleList?
    private var compiledTrackerList: WKContentRuleList?
    private var compiledExceptionList: WKContentRuleList?
    private var whitelistRuleLists: [String: WKContentRuleList] = [:]
    private var whitelistedHosts: Set<String> = []
    var bypassedHosts: Set<String> = []

    private let whitelistKey = "canopy.whitelist"
    private let lastUpdateKey = "canopy.lastListUpdate"
    nonisolated private static let updateBaseURL = "https://raw.githubusercontent.com/nathanrtracey1/Emerald-Ad-Blocker/main/output/"
    nonisolated private static let updateInterval: TimeInterval = 7 * 24 * 3600

    private init() {
        whitelistedHosts = Set(UserDefaults.standard.stringArray(forKey: whitelistKey) ?? [])
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            Task {
                await compileRuleLists()
                await restoreWhitelists()
            }
        }
    }

    // MARK: - Rule list compilation

    func compileRuleLists() async {
        guard let store = WKContentRuleListStore.default() else { return }

        async let ads = compileList(store: store, identifier: "canopy.adblock", resource: "adblock")
        async let trackers = compileList(store: store, identifier: "canopy.trackers", resource: "trackers")
        async let exceptions = compileList(store: store, identifier: "canopy.exceptions", resource: "exceptions")

        compiledAdList = await ads
        compiledTrackerList = await trackers
        compiledExceptionList = await exceptions
    }

    private func compileList(store: WKContentRuleListStore, identifier: String, resource: String) async -> WKContentRuleList? {
        if let cached = try? await store.contentRuleList(forIdentifier: identifier) {
            return cached
        }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            print("[Canopy] Missing bundled resource: \(resource).json")
            return nil
        }
        do {
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        } catch {
            print("[Canopy] Failed to compile \(identifier): \(error)")
            return nil
        }
    }

    // MARK: - Per-list toggles (persisted)

    private let adBlockEnabledKey = "canopy.adblock.enabled"
    private let trackerBlockEnabledKey = "canopy.trackers.enabled"
    private let cosmeticEnabledKey = "canopy.cosmetic.enabled"
    private let paramStrippingEnabledKey = "canopy.paramStripping.enabled"

    var isAdBlockEnabled: Bool {
        get { UserDefaults.standard.object(forKey: adBlockEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: adBlockEnabledKey) }
    }
    var isTrackerBlockEnabled: Bool {
        get { UserDefaults.standard.object(forKey: trackerBlockEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: trackerBlockEnabledKey) }
    }
    var isCosmeticEnabled: Bool {
        get { UserDefaults.standard.object(forKey: cosmeticEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: cosmeticEnabledKey) }
    }
    var isParamStrippingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: paramStrippingEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: paramStrippingEnabledKey) }
    }

    // MARK: - Per-tab application

    func applyTo(controller: WKUserContentController) {
        guard isEnabled else { return }
        if isAdBlockEnabled, let list = compiledAdList { controller.add(list) }
        if isTrackerBlockEnabled, let list = compiledTrackerList { controller.add(list) }
        if let list = compiledExceptionList { controller.add(list) }
        for (_, list) in whitelistRuleLists {
            controller.add(list)
        }
    }

    // MARK: - User scripts

    nonisolated static func canopyUserScripts() -> [WKUserScript] {
        func buildOnMain() -> [WKUserScript] {
            MainActor.assumeIsolated {
                var scripts: [WKUserScript] = []
                let filenames = ["cosmetic", "tracker_stubs", "ytadblock", "websocket_block", "scriptlets"]
                for name in filenames {
                    guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                          let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
                }
                return scripts
            }
        }
        if Thread.isMainThread {
            return buildOnMain()
        }
        return DispatchQueue.main.sync(execute: buildOnMain)
    }

    // MARK: - Whitelist (persisted)

    func addWhitelist(host: String) async {
        let normalized = host.lowercased()
        whitelistedHosts.insert(normalized)
        persistWhitelist()

        guard let store = WKContentRuleListStore.default() else { return }
        let json = """
        [{"trigger":{"url-filter":".*","if-domain":["\(normalized)"]},"action":{"type":"ignore-previous-rules"}}]
        """
        do {
            let list = try await store.compileContentRuleList(
                forIdentifier: "canopy.whitelist.\(normalized)",
                encodedContentRuleList: json
            )
            whitelistRuleLists[normalized] = list
        } catch {
            print("[Canopy] Whitelist compile failed for \(normalized): \(error)")
        }
    }

    func removeWhitelist(host: String) {
        let normalized = host.lowercased()
        whitelistedHosts.remove(normalized)
        whitelistRuleLists.removeValue(forKey: normalized)
        persistWhitelist()
    }

    func isWhitelisted(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return whitelistedHosts.contains(h)
    }

    func shouldSkipBlocking(for host: String?) -> Bool {
        if !isEnabled { return true }
        if ProtectedDomains.isProtectedHost(host) { return true }
        if isWhitelisted(host) { return true }
        if let h = host?.lowercased(), bypassedHosts.contains(h) { return true }
        return false
    }

    private func persistWhitelist() {
        UserDefaults.standard.set(Array(whitelistedHosts), forKey: whitelistKey)
    }

    private func restoreWhitelists() async {
        for host in whitelistedHosts {
            guard whitelistRuleLists[host] == nil else { continue }
            guard let store = WKContentRuleListStore.default() else { return }
            let json = """
            [{"trigger":{"url-filter":".*","if-domain":["\(host)"]},"action":{"type":"ignore-previous-rules"}}]
            """
            if let list = try? await store.compileContentRuleList(
                forIdentifier: "canopy.whitelist.\(host)",
                encodedContentRuleList: json
            ) {
                whitelistRuleLists[host] = list
            }
        }
    }

    // MARK: - Auto-update from GitHub

    func updateListsIfNeeded() async {
        let defaults = UserDefaults.standard
        let lastCheck = defaults.double(forKey: lastUpdateKey)
        guard Date().timeIntervalSince1970 - lastCheck > Self.updateInterval else { return }

        guard let store = WKContentRuleListStore.default() else { return }
        let files = ["adblock", "trackers", "exceptions"]

        var updated = false
        await withTaskGroup(of: Bool.self) { group in
            for file in files {
                group.addTask {
                    guard let url = URL(string: "\(Self.updateBaseURL)\(file).json") else { return false }
                    do {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard let httpResponse = response as? HTTPURLResponse,
                              httpResponse.statusCode == 200,
                              let json = String(data: data, encoding: .utf8) else { return false }
                        _ = try await store.compileContentRuleList(
                            forIdentifier: "canopy.\(file)",
                            encodedContentRuleList: json
                        )
                        return true
                    } catch {
                        print("[Canopy] Update failed for \(file): \(error)")
                        return false
                    }
                }
            }
            for await result in group {
                if result { updated = true }
            }
        }

        if updated {
            await compileRuleLists()
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastUpdateKey)
    }
}
