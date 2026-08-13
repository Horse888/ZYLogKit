import Foundation

struct LogSanitizer {
    private let privacy: LogPrivacyConfiguration
    private let limits: LogOutputLimits
    private let redactionRules: [CompiledRedactionRule]

    init(configuration: LogConfiguration) {
        self.privacy = configuration.privacy
        self.limits = configuration.outputLimits
        self.redactionRules = configuration.privacy.redactionRules.compactMap { rule in
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: []) else {
                return nil
            }
            return CompiledRedactionRule(expression: expression, replacement: rule.replacement)
        }
    }

    func message(_ value: String) -> String {
        limit(redact(normalize(value)), maximumCharacters: limits.maximumMessageCharacters)
    }

    func metadata(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for item in metadata.sorted(by: { $0.key < $1.key }) {
            let key = uniqueMetadataKey(metadataKey(item.key), in: sanitized)
            let value: String
            if privacy.isEnabled, isSensitiveMetadataKey(item.key) {
                value = privacy.redactedValue
            } else {
                value = limit(redact(normalize(item.value)), maximumCharacters: limits.maximumMetadataValueCharacters)
            }
            sanitized[key] = value
        }

        guard let maximumMetadataItemCount = limits.maximumMetadataItemCount,
              maximumMetadataItemCount >= 0,
              sanitized.count > maximumMetadataItemCount
        else {
            return sanitized
        }

        let keptKeys = sanitized.keys.sorted().prefix(maximumMetadataItemCount)
        let droppedCount = sanitized.count - keptKeys.count
        var limited: [String: String] = [:]
        for key in keptKeys {
            limited[key] = sanitized[key]
        }
        limited["log.metadata.dropped_count"] = "\(droppedCount)"
        return limited
    }

    func formattedLine(_ value: String) -> String {
        limit(normalize(value), maximumCharacters: limits.maximumFormattedLineCharacters)
    }

    private func redact(_ value: String) -> String {
        guard privacy.isEnabled else {
            return value
        }

        var result = value
        for rule in redactionRules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }
        return result
    }

    private func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func limit(_ value: String, maximumCharacters: Int?) -> String {
        guard let maximumCharacters, maximumCharacters >= 0, value.count > maximumCharacters else {
            return value
        }

        let index = value.index(value.startIndex, offsetBy: maximumCharacters)
        return String(value[..<index]) + "...[truncated]"
    }

    private func metadataKey(_ key: String) -> String {
        let normalized = normalize(key)
        let displayKey = normalized.isEmpty ? "metadata" : normalized
        return limit(displayKey, maximumCharacters: limits.maximumMetadataKeyCharacters)
    }

    private func uniqueMetadataKey(_ key: String, in metadata: [String: String]) -> String {
        guard metadata[key] == nil else {
            var index = 2
            while true {
                let candidate = "\(key)#\(index)"
                if metadata[candidate] == nil {
                    return candidate
                }
                index += 1
            }
        }

        return key
    }

    private func isSensitiveMetadataKey(_ key: String) -> Bool {
        let normalizedKey = LogPrivacyConfiguration.normalizedKey(key)
        if privacy.sensitiveMetadataKeys.contains(normalizedKey) {
            return true
        }

        return privacy.sensitiveMetadataKeys.contains { sensitiveKey in
            normalizedKey.contains(sensitiveKey)
        }
    }
}

private struct CompiledRedactionRule {
    let expression: NSRegularExpression
    let replacement: String
}
