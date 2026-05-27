import Foundation
import WebKit

/// Extended filter parser supporting uBO syntax beyond basic ABP.
/// Handles: network rules (||domain^), cosmetic (##), scriptlet (##+js()),
/// and special modifiers ($removeparam, $redirect, $csp, $popup).
enum CanopyFilterParser {

    struct ParsedFilter {
        enum FilterType {
            case networkBlock(domain: String)
            case networkAllow(domain: String)
            case cosmeticHide(domains: [String], selector: String)
            case cosmeticException(domains: [String], selector: String)
            case scriptlet(domains: [String], name: String, args: [String])
            case removeparam(param: String, isException: Bool)
            case redirect(pattern: String, resource: String)
            case popup(domains: [String])
            case comment
            case unsupported
        }
        let type: FilterType
        let raw: String
    }

    /// Parse a single filter line into a structured result.
    static func parse(_ line: String) -> ParsedFilter {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty || trimmed.hasPrefix("!") || trimmed.hasPrefix("[") {
            return ParsedFilter(type: .comment, raw: trimmed)
        }

        // Scriptlet injection: domain##+js(name, args)
        if trimmed.contains("##+js(") {
            let parts = trimmed.components(separatedBy: "##+js(")
            if parts.count == 2 {
                let domainPart = parts[0].trimmingCharacters(in: .whitespaces)
                var scriptlet = parts[1]
                if scriptlet.hasSuffix(")") { scriptlet.removeLast() }
                let args = scriptlet.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let name = args.first ?? ""
                let scriptArgs = Array(args.dropFirst())
                let domains = domainPart.isEmpty ? ["*"] : domainPart.components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*.")).lowercased() }
                return ParsedFilter(type: .scriptlet(domains: domains, name: name, args: scriptArgs), raw: trimmed)
            }
        }

        // Cosmetic exception: domain#@#selector
        if trimmed.contains("#@#") {
            let parts = trimmed.components(separatedBy: "#@#")
            if parts.count == 2 {
                let domains = parts[0].isEmpty ? ["*"] : parts[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*.")).lowercased() }
                return ParsedFilter(type: .cosmeticException(domains: domains, selector: parts[1].trimmingCharacters(in: .whitespaces)), raw: trimmed)
            }
        }

        // Cosmetic hiding: domain##selector
        if trimmed.contains("##") && !trimmed.hasPrefix("@@") {
            let parts = trimmed.components(separatedBy: "##")
            if parts.count == 2 {
                let domains = parts[0].isEmpty ? ["*"] : parts[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*.")).lowercased() }
                return ParsedFilter(type: .cosmeticHide(domains: domains, selector: parts[1].trimmingCharacters(in: .whitespaces)), raw: trimmed)
            }
        }

        // Network rules with modifiers
        if trimmed.contains("$") {
            let dollarIdx = trimmed.lastIndex(of: "$")!
            let options = String(trimmed[trimmed.index(after: dollarIdx)...])

            // $removeparam
            for opt in options.components(separatedBy: ",") {
                let o = opt.trimmingCharacters(in: .whitespaces)
                if o.hasPrefix("removeparam=") {
                    let param = String(o.dropFirst("removeparam=".count))
                    let isException = trimmed.hasPrefix("@@")
                    return ParsedFilter(type: .removeparam(param: param, isException: isException), raw: trimmed)
                }
                if o.hasPrefix("redirect=") || o.hasPrefix("redirect-rule=") {
                    let resource = o.contains("redirect-rule=") ? String(o.dropFirst("redirect-rule=".count)) : String(o.dropFirst("redirect=".count))
                    let pattern = String(trimmed[..<dollarIdx])
                    return ParsedFilter(type: .redirect(pattern: pattern, resource: resource), raw: trimmed)
                }
                if o == "popup" {
                    let pattern = String(trimmed[..<dollarIdx])
                    let domains = pattern.hasPrefix("||") ? [String(pattern.dropFirst(2)).components(separatedBy: "^").first ?? ""] : ["*"]
                    return ParsedFilter(type: .popup(domains: domains), raw: trimmed)
                }
            }
        }

        // Exception rule: @@||domain^
        if trimmed.hasPrefix("@@||") {
            let withoutPrefix = String(trimmed.dropFirst(4))
            if let domain = extractDomain(from: withoutPrefix) {
                return ParsedFilter(type: .networkAllow(domain: domain), raw: trimmed)
            }
        }

        // Network block rule: ||domain^
        if trimmed.hasPrefix("||") {
            let withoutPrefix = String(trimmed.dropFirst(2))
            if let domain = extractDomain(from: withoutPrefix) {
                return ParsedFilter(type: .networkBlock(domain: domain), raw: trimmed)
            }
        }

        return ParsedFilter(type: .unsupported, raw: trimmed)
    }

    /// Parse multiple lines and apply them to the appropriate Canopy managers.
    @MainActor
    static func parseAndApply(_ text: String) -> (network: Int, cosmetic: Int, scriptlet: Int, other: Int) {
        var network = 0, cosmetic = 0, scriptlet = 0, other = 0

        for line in text.components(separatedBy: "\n") {
            let result = parse(line)
            switch result.type {
            case .cosmeticHide(let domains, let selector):
                for domain in domains {
                    CanopyElementPicker.shared.addRule(host: domain, selector: selector)
                }
                cosmetic += 1
            case .cosmeticException(let domains, let selector):
                for domain in domains {
                    CanopyElementPicker.shared.removeRule(host: domain, selector: selector)
                }
                cosmetic += 1
            case .networkBlock:
                network += 1
            case .networkAllow:
                network += 1
            case .scriptlet:
                scriptlet += 1
            case .removeparam, .redirect, .popup:
                other += 1
            case .comment, .unsupported:
                break
            }
        }

        return (network, cosmetic, scriptlet, other)
    }

    private static func extractDomain(from text: String) -> String? {
        var end = text.startIndex
        for idx in text.indices {
            let ch = text[idx]
            if ch == "^" || ch == "$" || ch == "*" || ch == "/" || ch == "?" { break }
            end = text.index(after: idx)
        }
        let candidate = String(text[..<end]).lowercased()
        if candidate.isEmpty || !candidate.contains(".") { return nil }
        return candidate
    }
}
