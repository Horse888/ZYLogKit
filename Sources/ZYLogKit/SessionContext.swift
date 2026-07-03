import Foundation

struct SessionContext {
    let id: String
    let startedAt: Date
    let metadata: [String: String]

    static func make(configuration: LogConfiguration) -> SessionContext {
        var metadata = defaultMetadata()
        configuration.metadataProvider().forEach { key, value in
            metadata[key] = value
        }

        return SessionContext(
            id: UUID().uuidString,
            startedAt: Date(),
            metadata: metadata
        )
    }

    func headerLines() -> [String] {
        var lines = [
            "===== Session Begin =====",
            "Session: \(id)",
            "StartedAt: \(LogFormatter.formattedDate(startedAt))"
        ]

        for item in metadata.sorted(by: { $0.key < $1.key }) {
            lines.append("\(item.key): \(item.value)")
        }

        lines.append("=========================")
        return lines
    }

    private static func defaultMetadata() -> [String: String] {
        let processInfo = ProcessInfo.processInfo
        var metadata: [String: String] = [
            "Process": processInfo.processName,
            "OS": processInfo.operatingSystemVersionString,
            "Host": processInfo.hostName
        ]

        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            metadata["Bundle"] = bundleIdentifier
        }

        if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            metadata["Version"] = shortVersion
        }

        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            metadata["Build"] = build
        }

        return metadata
    }
}
