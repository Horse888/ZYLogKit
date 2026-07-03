import Foundation

public struct LogFormatter {
    public var includesSourceLocation: Bool
    public var includesMetadata: Bool

    public init(includesSourceLocation: Bool = true, includesMetadata: Bool = true) {
        self.includesSourceLocation = includesSourceLocation
        self.includesMetadata = includesMetadata
    }

    func format(_ event: LogEvent) -> String {
        var components: [String] = []

        if includesSourceLocation {
            components.append("[file:\(Self.fileName(from: event.file)):\(event.line)]")
            components.append("[function:\(event.function)]")
        }

        components.append(contentsOf: [
            Self.formattedDate(event.date),
            event.level.emoji,
            "[\(event.level.label)]",
            "[\(event.category.description)]",
            "[process:\(event.processName) pid:\(event.processID)]",
            "[thread:\(event.thread)]",
            event.message
        ])

        if includesMetadata, !event.metadata.isEmpty {
            let metadata = event.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            components.append("{\(metadata)}")
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

    private static func fileName(from file: String) -> String {
        file
            .split(separator: "/")
            .last
            .map(String.init) ?? file
    }

    private static let dateFormatterLock = NSLock()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
