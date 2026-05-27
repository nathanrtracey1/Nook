import Foundation

enum AgentDebugLogger {
    static var isEnabled: Bool = false

    static func log(
        runId: String,
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {}
}
