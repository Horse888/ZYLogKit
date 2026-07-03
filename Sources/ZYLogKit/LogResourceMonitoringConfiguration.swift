import Foundation

public struct LogResourceMonitoringConfiguration {
    public var isEnabled: Bool
    public var interval: TimeInterval
    public var level: LogLevel
    public var category: LogCategory

    public init(
        isEnabled: Bool = true,
        interval: TimeInterval = 30,
        level: LogLevel = .info,
        category: LogCategory = .resource
    ) {
        self.isEnabled = isEnabled
        self.interval = interval
        self.level = level
        self.category = category
    }

    public static var `default`: LogResourceMonitoringConfiguration {
        LogResourceMonitoringConfiguration()
    }

    public static var disabled: LogResourceMonitoringConfiguration {
        LogResourceMonitoringConfiguration(isEnabled: false)
    }
}
