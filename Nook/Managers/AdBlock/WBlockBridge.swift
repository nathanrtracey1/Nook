import Foundation
import WebKit

/// Bridges wBlock's Safari content blocker rules into Nook's WKWebView.
///
/// wBlock uses Safari's `com.apple.Safari.content-blocker` extension point, which WKWebView
/// cannot load natively. This bridge reads wBlock's compiled rule lists from its App Group
/// container and loads them via WKContentRuleListStore, giving Nook access to wBlock's
/// 750,000 rules across all 5 content blocker slots.
@MainActor
final class WBlockBridge {
    static let shared = WBlockBridge()

    private var compiledLists: [String: WKContentRuleList] = [:]
    private(set) var isAvailable: Bool = false
    private(set) var loadedSlots: [String] = []

    private static let appGroupIdentifiers = [
        "group.com.0xCUB3.wBlock",
        "group.wBlock",
    ]

    private static let slotNames = [
        "wBlock Ads",
        "wBlock Privacy",
        "wBlock Custom",
        "wBlock Foreign",
        "wBlock Security",
    ]

    private init() {}

    /// Scan for wBlock installation and load any available content blocker rules.
    func loadIfAvailable() async {
        guard let containerURL = findWBlockContainer() else {
            isAvailable = false
            return
        }

        guard let store = WKContentRuleListStore.default() else { return }

        isAvailable = true
        loadedSlots.removeAll()

        for slot in Self.slotNames {
            if let json = readBlockerJSON(for: slot, in: containerURL) {
                let identifier = "wblock.\(slot.lowercased().replacingOccurrences(of: " ", with: "_"))"
                do {
                    let list = try await store.compileContentRuleList(
                        forIdentifier: identifier,
                        encodedContentRuleList: json
                    )
                    compiledLists[slot] = list
                    loadedSlots.append(slot)
                    print("[WBlockBridge] Loaded \(slot) rules")
                } catch {
                    print("[WBlockBridge] Failed to compile \(slot): \(error)")
                }
            }
        }

        if loadedSlots.isEmpty {
            // Try reading the bundled fallback blockerList.json from wBlock's app bundle
            if let appJSON = readBlockerJSONFromApp() {
                do {
                    let list = try await store.compileContentRuleList(
                        forIdentifier: "wblock.app_bundled",
                        encodedContentRuleList: appJSON
                    )
                    compiledLists["bundled"] = list
                    loadedSlots.append("bundled")
                    print("[WBlockBridge] Loaded bundled wBlock rules from app bundle")
                } catch {
                    print("[WBlockBridge] Failed to compile bundled rules: \(error)")
                }
            }
        }
    }

    func applyTo(controller: WKUserContentController) {
        for (_, list) in compiledLists {
            controller.add(list)
        }
    }

    // MARK: - Container discovery

    private func findWBlockContainer() -> URL? {
        let fm = FileManager.default

        for groupId in Self.appGroupIdentifiers {
            if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
                if fm.fileExists(atPath: container.path) {
                    return container
                }
            }
        }

        // Fallback: scan Library/Group Containers
        let groupContainers = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
        if let items = try? fm.contentsOfDirectory(at: groupContainers, includingPropertiesForKeys: nil) {
            for item in items {
                let name = item.lastPathComponent.lowercased()
                if name.contains("wblock") || name.contains("0xcub3") {
                    return item
                }
            }
        }

        return nil
    }

    private func readBlockerJSON(for slot: String, in containerURL: URL) -> String? {
        let fm = FileManager.default

        let possiblePaths = [
            containerURL.appendingPathComponent("ContentBlocker/\(slot).json"),
            containerURL.appendingPathComponent("\(slot)/blockerList.json"),
            containerURL.appendingPathComponent("Library/Caches/\(slot).json"),
            containerURL.appendingPathComponent("blockerList_\(slot.replacingOccurrences(of: " ", with: "_")).json"),
        ]

        for path in possiblePaths {
            if fm.fileExists(atPath: path.path),
               let json = try? String(contentsOf: path, encoding: .utf8),
               json.count > 10 {
                return json
            }
        }

        return nil
    }

    private func readBlockerJSONFromApp() -> String? {
        let fm = FileManager.default
        let appPath = URL(fileURLWithPath: "/Applications/wBlock.app")
        guard fm.fileExists(atPath: appPath.path) else { return nil }

        let plugInsDir = appPath.appendingPathComponent("Contents/PlugIns")
        guard let plugins = try? fm.contentsOfDirectory(at: plugInsDir, includingPropertiesForKeys: nil) else { return nil }

        for plugin in plugins where plugin.pathExtension == "appex" {
            let blockerList = plugin.appendingPathComponent("Contents/Resources/blockerList.json")
            if fm.fileExists(atPath: blockerList.path),
               let json = try? String(contentsOf: blockerList, encoding: .utf8),
               json.count > 10 {
                return json
            }
        }

        return nil
    }
}
