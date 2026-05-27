import Foundation

enum NookBlockerState: String {
    case enabled
    case disabled
    /// Strict isolation mode for academic/LTI domains (Canvas/Kaltura/Okta/etc.).
    case passthrough
}

enum ProtectedDomains {
    /// CRITICAL: When the *current* top-level URL matches any of these, all ad-blocking and JS injection
    /// must be treated as disabled for that WKWebView instance.
    static let seeds: [String] = [
        "instructure.com",
        "kaltura.com",
        "okta.com",
        "canvas"
    ]

    /// Pages where blocking must be fully disabled to avoid breaking functionality.
    static let protectedPaths: [(host: String, pathPrefix: String)] = [
        ("www.google.com", "/sorry"),
        ("google.com", "/sorry"),
    ]

    static func isProtectedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }

        if host.contains("canvas") { return true }

        for seed in seeds where seed != "canvas" {
            if host == seed { return true }
            if host.hasSuffix("." + seed) { return true }
        }

        return false
    }

    static func isProtectedURL(_ url: URL?) -> Bool {
        guard let url = url, let host = url.host?.lowercased() else { return false }
        if isProtectedHost(host) { return true }
        for entry in protectedPaths {
            if host == entry.host && url.path.hasPrefix(entry.pathPrefix) { return true }
        }
        return false
    }
}

