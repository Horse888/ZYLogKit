import Foundation

public struct LogRedactionRule: Sendable {
    public var pattern: String
    public var replacement: String

    public init(pattern: String, replacement: String) {
        self.pattern = pattern
        self.replacement = replacement
    }
}

public struct LogPrivacyConfiguration: Sendable {
    public var isEnabled: Bool
    public var redactedValue: String
    public var sensitiveMetadataKeys: Set<String>
    public var redactionRules: [LogRedactionRule]

    public init(
        isEnabled: Bool = true,
        redactedValue: String = "[REDACTED]",
        sensitiveMetadataKeys: Set<String> = LogPrivacyConfiguration.defaultSensitiveMetadataKeys,
        redactionRules: [LogRedactionRule] = LogPrivacyConfiguration.defaultRedactionRules
    ) {
        self.isEnabled = isEnabled
        self.redactedValue = redactedValue
        self.sensitiveMetadataKeys = Set(sensitiveMetadataKeys.map(Self.normalizedKey))
        self.redactionRules = redactionRules
    }

    public static var `default`: LogPrivacyConfiguration {
        LogPrivacyConfiguration()
    }

    public static var disabled: LogPrivacyConfiguration {
        LogPrivacyConfiguration(isEnabled: false)
    }

    public static let defaultSensitiveMetadataKeys: Set<String> = [
        "password",
        "passwd",
        "pwd",
        "token",
        "access_token",
        "refreshtoken",
        "refresh_token",
        "secret",
        "apikey",
        "api_key",
        "authorization",
        "cookie",
        "credential",
        "session",
        "sessionid",
        "session_id"
    ]

    public static let defaultRedactionRules: [LogRedactionRule] = [
        LogRedactionRule(
            pattern: #"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s]+"#,
            replacement: "$1[REDACTED]"
        ),
        LogRedactionRule(
            pattern: #"(?i)((?:password|passwd|pwd|token|access[_-]?token|refresh[_-]?token|secret|api[_-]?key|credential|cookie)\s*[:=]\s*)[^\s&]+"#,
            replacement: "$1[REDACTED]"
        ),
        LogRedactionRule(
            pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            replacement: "[REDACTED_EMAIL]"
        )
    ]

    static func normalizedKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
