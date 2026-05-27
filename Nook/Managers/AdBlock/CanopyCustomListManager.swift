import Foundation
import WebKit

/// Manages user-added custom filter lists (URLs to ABP/uBO/AdGuard-format filter lists).
/// Downloads lists, extracts cosmetic rules for injection, and compiles network rules to WKContentRuleList.
@MainActor
final class CanopyCustomListManager: ObservableObject {
    static let shared = CanopyCustomListManager()

    struct CustomList: Identifiable, Codable {
        let id: UUID
        var name: String
        var urlString: String
        var isEnabled: Bool
        var ruleCount: Int
        var lastUpdated: Date?
    }

    @Published var lists: [CustomList] = []

    private let listsKey = "canopy.customLists"
    private let cacheDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Nook").appendingPathComponent("CanopyCustomLists")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var compiledLists: [UUID: WKContentRuleList] = [:]

    private init() {
        loadLists()
        Task { await compileAll() }
    }

    // MARK: - List management

    func addList(name: String, urlString: String) {
        let list = CustomList(id: UUID(), name: name, urlString: urlString, isEnabled: true, ruleCount: 0, lastUpdated: nil)
        lists.append(list)
        saveLists()
        Task { await fetchAndCompile(list) }
    }

    func removeList(id: UUID) {
        lists.removeAll { $0.id == id }
        compiledLists.removeValue(forKey: id)
        let cacheFile = cacheDir.appendingPathComponent(id.uuidString + ".txt")
        try? FileManager.default.removeItem(at: cacheFile)
        saveLists()
    }

    func toggleList(id: UUID, enabled: Bool) {
        if let idx = lists.firstIndex(where: { $0.id == id }) {
            lists[idx].isEnabled = enabled
            saveLists()
        }
    }

    func refreshAll() async {
        for list in lists where list.isEnabled {
            await fetchAndCompile(list)
        }
    }

    // MARK: - Download + compile

    private func fetchAndCompile(_ list: CustomList) async {
        guard let url = URL(string: list.urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return }

            // Cache the raw text
            let cacheFile = cacheDir.appendingPathComponent(list.id.uuidString + ".txt")
            try? text.write(to: cacheFile, atomically: true, encoding: .utf8)

            // Parse using the extended uBO-compatible filter parser
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var networkRules: [[String: Any]] = []
            var cosmeticCount = 0

            for line in lines {
                let parsed = CanopyFilterParser.parse(line)
                switch parsed.type {
                case .cosmeticHide(let domains, let selector):
                    for domain in domains {
                        CanopyElementPicker.shared.addRule(host: domain, selector: selector)
                    }
                    cosmeticCount += 1
                case .cosmeticException(let domains, let selector):
                    for domain in domains {
                        CanopyElementPicker.shared.removeRule(host: domain, selector: selector)
                    }
                    cosmeticCount += 1
                case .networkBlock(let domain):
                    let escaped = NSRegularExpression.escapedPattern(for: domain)
                    networkRules.append([
                        "trigger": ["url-filter": "^[^:]+://([^/]*\\.)?\(escaped)/", "load-type": ["third-party"]],
                        "action": ["type": "block"]
                    ])
                case .removeparam(let param, let isException):
                    if !isException {
                        CanopyURLCleaner.shared.addCustomParam(param)
                    }
                    cosmeticCount += 1
                case .scriptlet, .redirect, .popup, .networkAllow:
                    cosmeticCount += 1
                case .comment, .unsupported:
                    break
                }
                if networkRules.count >= 50000 { break }
            }

            // Compile network rules
            if !networkRules.isEmpty, let store = WKContentRuleListStore.default() {
                if let jsonData = try? JSONSerialization.data(withJSONObject: networkRules),
                   let json = String(data: jsonData, encoding: .utf8) {
                    let compiled = try await store.compileContentRuleList(
                        forIdentifier: "canopy.custom.\(list.id.uuidString)",
                        encodedContentRuleList: json
                    )
                    compiledLists[list.id] = compiled
                }
            }

            // Update metadata
            if let idx = lists.firstIndex(where: { $0.id == list.id }) {
                lists[idx].ruleCount = networkRules.count + cosmeticCount
                lists[idx].lastUpdated = Date()
                saveLists()
            }
        } catch {
            print("[Canopy] Failed to fetch custom list \(list.name): \(error)")
        }
    }

    private func extractDomain(from line: String) -> String? {
        guard line.hasPrefix("||") else { return nil }
        let withoutPrefix = String(line.dropFirst(2))
        var end = withoutPrefix.startIndex
        for idx in withoutPrefix.indices {
            let ch = withoutPrefix[idx]
            if ch == "^" || ch == "$" || ch == "*" || ch == "/" || ch == "?" { break }
            end = withoutPrefix.index(after: idx)
        }
        let candidate = String(withoutPrefix[..<end]).lowercased()
        if candidate.isEmpty || !candidate.contains(".") { return nil }
        return candidate
    }

    // MARK: - Apply to tabs

    func applyTo(controller: WKUserContentController) {
        for (id, list) in compiledLists {
            if lists.first(where: { $0.id == id })?.isEnabled == true {
                controller.add(list)
            }
        }
    }

    // MARK: - Persistence

    private func saveLists() {
        if let data = try? JSONEncoder().encode(lists) {
            UserDefaults.standard.set(data, forKey: listsKey)
        }
    }

    private func loadLists() {
        guard let data = UserDefaults.standard.data(forKey: listsKey),
              let loaded = try? JSONDecoder().decode([CustomList].self, from: data) else { return }
        lists = loaded
    }

    private func compileAll() async {
        for list in lists where list.isEnabled {
            let cacheFile = cacheDir.appendingPathComponent(list.id.uuidString + ".txt")
            if FileManager.default.fileExists(atPath: cacheFile.path) {
                // Recompile from cache
                await fetchAndCompile(list)
            }
        }
    }
}
