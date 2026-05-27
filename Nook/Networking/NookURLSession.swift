import Foundation

enum NookURLSession {
    /// Dedicated session for internal API calls (AI, extensions, Web Store)
    /// so we can tune connection pooling and timeouts without affecting
    /// WebKit's own networking stack.
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()
}

