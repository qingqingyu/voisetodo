import Foundation
import OSLog

/// Centralized structured logging for development diagnostics.
enum VoiceTodoLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.voicetodo.app"

    @TaskLocal static var extractID: String?

    static let app = Logger(subsystem: subsystem, category: "app")
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let extractor = Logger(subsystem: subsystem, category: "extractor")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let intent = Logger(subsystem: subsystem, category: "intent")
    static let widget = Logger(subsystem: subsystem, category: "widget")
    static let calendar = Logger(subsystem: subsystem, category: "calendar")
    static let notification = Logger(subsystem: subsystem, category: "notification")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    static func makeID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    static func currentExtractID(fallbackPrefix: String) -> String {
        extractID ?? makeID(fallbackPrefix)
    }

    static func durationMS(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1_000))
    }

    static func textSummary(_ text: String, previewLimit: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.isEmpty
            ? 0
            : trimmed.components(separatedBy: .newlines).count
        return "chars=\(trimmed.count) lines=\(lineCount) exceedsLimit=\(trimmed.count > previewLimit)"
    }

    static func idsSummary<T: CustomStringConvertible>(_ ids: [T], limit: Int = 5) -> String {
        let shown = ids.prefix(limit).map(\.description).joined(separator: ",")
        let suffix = ids.count > limit ? ",..." : ""
        return "count=\(ids.count) ids=[\(shown)\(suffix)]"
    }

    static func errorSummary(_ error: Error) -> String {
        "\(type(of: error)): \(String(describing: error)); localized=\"\(error.localizedDescription)\""
    }
}
