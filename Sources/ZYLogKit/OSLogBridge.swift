import Foundation

#if canImport(os)
import os
#endif

enum OSLogBridge {
    static func write(_ event: LogEvent, configuration: LogConfiguration) {
        #if canImport(os)
        if #available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *) {
            let logger = Logger(
                subsystem: configuration.subsystem,
                category: event.category.rawValue
            )
            logger.log(level: event.level.osLogType, "\(event.message, privacy: .public)")
        } else {
            os_log(
                "%{public}@",
                log: OSLog(subsystem: configuration.subsystem, category: event.category.rawValue),
                type: event.level.osLogType,
                event.message
            )
        }
        #endif
    }
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
