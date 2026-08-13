import Foundation

#if canImport(os)
import os
#endif

enum OSLogBridge {
    static func write(_ line: String, event: LogEvent, configuration: LogConfiguration) {
        #if canImport(os)
        let log = cachedLog(
            subsystem: configuration.subsystem,
            category: event.category.rawValue
        )
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            let logger = Logger(log)
            logger.log(level: event.level.osLogType, "\(line, privacy: .public)")
        } else {
            os_log(
                "%{public}@",
                log: log,
                type: event.level.osLogType,
                line
            )
        }
        #endif
    }

    #if canImport(os)
    private struct CacheKey: Hashable {
        let subsystem: String
        let category: String
    }

    private static func cachedLog(subsystem: String, category: String) -> OSLog {
        cache.log(subsystem: subsystem, category: category)
    }

    private final class Cache: @unchecked Sendable {
        func log(subsystem: String, category: String) -> OSLog {
            let key = CacheKey(subsystem: subsystem, category: category)
            lock.lock()
            defer {
                lock.unlock()
            }

            if let log = logs[key] {
                return log
            }
            if logs.count >= maximumLogCount {
                logs.removeAll(keepingCapacity: true)
            }

            let log = OSLog(
                subsystem: subsystem.isEmpty ? "ZYLogKit" : subsystem,
                category: category.isEmpty ? "general" : category
            )
            logs[key] = log
            return log
        }

        private let maximumLogCount = 64
        private let lock = NSLock()
        private var logs: [CacheKey: OSLog] = [:]
    }

    private static let cache = Cache()
    #endif
}

#if canImport(os)
private extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .trace, .debug:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }
}
#endif
