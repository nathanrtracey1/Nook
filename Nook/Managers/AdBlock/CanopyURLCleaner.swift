import Foundation
import WebKit

@MainActor
final class CanopyURLCleaner {
    static let shared = CanopyURLCleaner()

    private var paramsToStrip: Set<String> = []
    private var exceptionParams: Set<String> = []

    private init() {
        loadRules()
    }

    private func loadRules() {
        guard let url = Bundle.main.url(forResource: "removeparam_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode([RemoveParamRule].self, from: data) else { return }

        for rule in rules {
            let cleaned = rule.param.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            guard !cleaned.isEmpty else { continue }
            if rule.exception == true {
                exceptionParams.insert(cleaned)
            } else {
                paramsToStrip.insert(cleaned)
            }
        }
        paramsToStrip.subtract(exceptionParams)
    }

    func addCustomParam(_ param: String) {
        let cleaned = param.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !cleaned.isEmpty else { return }
        paramsToStrip.insert(cleaned)
    }

    func cleanURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else { return nil }

        let filtered = queryItems.filter { item in
            !paramsToStrip.contains(item.name)
        }

        if filtered.count == queryItems.count { return nil }

        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.url
    }

    func shouldClean(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return false }
        return queryItems.contains { paramsToStrip.contains($0.name) }
    }
}

private struct RemoveParamRule: Decodable {
    let param: String
    let exception: Bool?
}
