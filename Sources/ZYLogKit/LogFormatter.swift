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
            event.level.emoji,
            event.level.label,
            event.category.description
        ]

        if includesSourceLocation {
            components.append("\(Self.fileName(from: event.file)):\(event.line)")
            components.append(event.function)
        }

        components.append("-")
        components.append(event.message)

        if includesMetadata, !event.metadata.isEmpty {
            let metadata = Self.formattedMetadata(event.metadata)
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

    private static func formattedMetadata(_ metadata: [String: String]) -> String {
        var remainingMetadata = metadata
        var items: [String] = []

        if let app = formattedAppMetadata(from: &remainingMetadata) {
            items.append(app)
        }

        if let device = formattedDeviceMetadata(from: &remainingMetadata) {
            items.append(device)
        }

        items.append(contentsOf: remainingMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" })

        return items.joined(separator: " ")
    }

    private static func formattedAppMetadata(from metadata: inout [String: String]) -> String? {
        let name = metadata.removeValue(forKey: "app.name")
        let version = metadata.removeValue(forKey: "app.version")
        let build = metadata.removeValue(forKey: "app.build")

        guard name != nil || version != nil || build != nil else {
            return nil
        }

        var value = name ?? "unknown"
        if let version {
            value += " \(version)"
        }
        if let build {
            value += "(\(build))"
        }

        return "app=\(value)"
    }

    private static func formattedDeviceMetadata(from metadata: inout [String: String]) -> String? {
        let model = metadata.removeValue(forKey: "device.model")
        let systemVersion = metadata.removeValue(forKey: "system.version")

        guard model != nil || systemVersion != nil else {
            return nil
        }

        let value = [
            model,
            systemVersion.map { "OS \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return "device=\(value)"
    }

    private static let dateFormatterLock = NSLock()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return formatter
    }()
}
