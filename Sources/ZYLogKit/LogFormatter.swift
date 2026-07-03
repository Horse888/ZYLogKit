import Foundation

public struct LogFormatter {
    public var includesSourceLocation: Bool
    public var includesMetadata: Bool

    public init(includesSourceLocation: Bool = true, includesMetadata: Bool = true) {
        self.includesSourceLocation = includesSourceLocation
        self.includesMetadata = includesMetadata
    }

    func format(_ event: LogEvent) -> String {
        var components = [
            Self.formattedDate(event.date),
            "[\(event.level.label)]",
            "[\(event.category.description)]",
            "[session:\(event.sessionID)]",
            "[process:\(event.processName) pid:\(event.processID)]",
            "[thread:\(event.thread)]",
            event.message
        ]

        if includesMetadata, !event.metadata.isEmpty {
            let metadata = event.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            components.append("{\(metadata)}")
        }

        if includesSourceLocation {
            components.append("[source:\(event.file):\(event.line)]")
            components.append("[function:\(event.function)]")
        }

        return components.joined(separator: " ")
    }

    static func formattedDate(_ date: Date) -> String {
        dateFormatterLock.lock()
        defer {
            dateFormatterLock.unlock()
        }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatterLock = NSLock()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
