import Foundation

/// Converts filter list formats into WebKit content-blocker JSON rules.
/// This is intentionally limited and optimized for production usage.
enum NookRuleCompiler {

    /// Parse uBO/ABP-style domain rules like `||example.com^` and return host strings.
    static func parseUBODomainList(_ text: String) -> Set<String> {
        var out = Set<String>()

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("!") { continue }
            if line.hasPrefix("[") { continue }
            if line.hasPrefix("@@") { continue }
            if line.contains("##") { continue }
            if line.contains("#@#") { continue }

            if let host = parseUboHostRule(line) {
                out.insert(host)
            }
        }

        return out
    }

    /// Convert a set of blocked domains into WebKit JSON rules (fast).
    static func webKitRulesForBlockedDomains(_ domains: Set<String>) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        rules.reserveCapacity(min(domains.count, 50_000))

        for host in domains.prefix(50_000) {
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

        return rules
    }

    /// Convert standard JSON "rules" (already in WebKit schema) into a canonical array.
    /// Supports either a JSON array or an object with a `rules` array.
    static func parseWebKitJSONRules(_ data: Data) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = obj as? [[String: Any]] { return arr }
        if let dict = obj as? [String: Any],
           let arr = dict["rules"] as? [[String: Any]] {
            return arr
        }
        return nil
    }

    /// uBO syntax `||domain.com^` host extraction.
    private static func parseUboHostRule(_ line: String) -> String? {
        guard line.hasPrefix("||") else { return nil }
        let withoutPrefix = String(line.dropFirst(2))
        guard !withoutPrefix.isEmpty else { return nil }

        var end = withoutPrefix.startIndex
        for idx in withoutPrefix.indices {
            let ch = withoutPrefix[idx]
            if ch == "^" || ch == "$" || ch == "*" || ch == "/" || ch == "?" {
                break
            }
            end = withoutPrefix.index(after: idx)
        }
        let candidate = String(withoutPrefix[..<end]).lowercased()
        if candidate.isEmpty { return nil }
        if candidate.contains("/") { return nil }
        return candidate
    }
}

