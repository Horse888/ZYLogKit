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
        let bounded = normalizeAndLimit(value, maximumCharacters: limits.maximumMessageCharacters)
        return limit(redact(bounded), maximumCharacters: limits.maximumMessageCharacters)
    }

    func metadata(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        let selection = selectedMetadata(from: metadata)

        for item in selection.items {
            let key = uniqueMetadataKey(metadataKey(item.key), in: sanitized)
            let value: String
            if privacy.isEnabled, isSensitiveMetadataKey(privacyKey(item.key)) {
                value = normalizeAndLimit(
                    privacy.redactedValue,
                    maximumCharacters: limits.maximumMetadataValueCharacters
                )
            } else {
                let bounded = normalizeAndLimit(
                    item.value,
                    maximumCharacters: limits.maximumMetadataValueCharacters
                )
                value = limit(
                    redact(bounded),
                    maximumCharacters: limits.maximumMetadataValueCharacters
                )
            }
            sanitized[key] = value
        }

        if selection.droppedCount > 0 {
            sanitized["log.metadata.dropped_count"] = "\(selection.droppedCount)"
        }
        return sanitized
    }

    func formattedLine(_ value: String) -> String {
        normalizeAndLimit(value, maximumCharacters: limits.maximumFormattedLineCharacters)
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

    private func normalizeAndLimit(_ value: String, maximumCharacters: Int?) -> String {
        let boundedInput = limit(value, maximumCharacters: maximumCharacters)
        return limit(normalize(boundedInput), maximumCharacters: maximumCharacters)
    }

    private func limit(_ value: String, maximumCharacters: Int?) -> String {
        guard let maximumCharacters, maximumCharacters >= 0,
              let index = value.index(
                  value.startIndex,
                  offsetBy: maximumCharacters,
                  limitedBy: value.endIndex
              ),
              index != value.endIndex else {
            return value
        }

        return String(value[..<index]) + "...[truncated]"
    }

    private func metadataKey(_ key: String) -> String {
        let normalized = normalizeAndLimit(
            key,
            maximumCharacters: limits.maximumMetadataKeyCharacters
        )
        let displayKey = normalized.isEmpty ? "metadata" : normalized
        return limit(displayKey, maximumCharacters: limits.maximumMetadataKeyCharacters)
    }

    private func selectedMetadata(
        from metadata: [String: String]
    ) -> (items: [(key: String, value: String)], droppedCount: Int) {
        guard let maximumCount = limits.maximumMetadataItemCount,
              maximumCount >= 0,
              metadata.count > maximumCount else {
            return (metadata.sorted { $0.key < $1.key }, 0)
        }

        let selectedKeys = lexicographicallySmallestKeys(in: metadata, count: maximumCount)
        let items = selectedKeys.compactMap { key in
            metadata[key].map { (key: key, value: $0) }
        }
        return (items, metadata.count - items.count)
    }

    private func lexicographicallySmallestKeys(
        in metadata: [String: String],
        count: Int
    ) -> [String] {
        guard count > 0 else {
            return []
        }

        var heap: [String] = []
        heap.reserveCapacity(min(count, metadata.count))

        for key in metadata.keys {
            if heap.count < count {
                heap.append(key)
                siftUpMaxHeap(&heap, from: heap.count - 1)
            } else if let largest = heap.first, key < largest {
                heap[0] = key
                siftDownMaxHeap(&heap, from: 0)
            }
        }
        return heap.sorted()
    }

    private func siftUpMaxHeap(_ heap: inout [String], from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[parent] < heap[child] else {
                return
            }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private func siftDownMaxHeap(_ heap: inout [String], from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else {
                return
            }
            let right = left + 1
            let largestChild = right < heap.count && heap[left] < heap[right] ? right : left
            guard heap[parent] < heap[largestChild] else {
                return
            }
            heap.swapAt(parent, largestChild)
            parent = largestChild
        }
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

    private func privacyKey(_ key: String) -> String {
        limit(key, maximumCharacters: 4 * 1024)
    }
}

private struct CompiledRedactionRule {
    let expression: NSRegularExpression
    let replacement: String
}
