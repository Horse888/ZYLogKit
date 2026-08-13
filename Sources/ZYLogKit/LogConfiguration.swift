import Foundation

public struct LogConfiguration {
    public var subsystem: String
    public var logDirectory: URL
    public var minimumLevel: LogLevel
    public var fileMinimumLevel: LogLevel
    public var consoleMinimumLevel: LogLevel
    public var isFileLoggingEnabled: Bool
    public var isConsoleLoggingEnabled: Bool
    public var retention: LogRetention
    public var includesSessionHeader: Bool
    public var resourceMonitoring: LogResourceMonitoringConfiguration
    public var fileWriting: LogFileWritingConfiguration
    public var privacy: LogPrivacyConfiguration
    public var outputLimits: LogOutputLimits
    public var formatter: LogFormatter
    public var internalErrorHandler: (String, Error?) -> Void
    public var metadataProvider: () -> [String: String]

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "ZYLogKit",
        logDirectory: URL = LogConfiguration.defaultLogDirectory(),
        minimumLevel: LogLevel = .trace,
        fileMinimumLevel: LogLevel = .trace,
        consoleMinimumLevel: LogLevel = .debug,
        isFileLoggingEnabled: Bool = true,
        isConsoleLoggingEnabled: Bool = true,
        retention: LogRetention = .default,
        includesSessionHeader: Bool = true,
        resourceMonitoring: LogResourceMonitoringConfiguration = .default,
        privacy: LogPrivacyConfiguration = .default,
        outputLimits: LogOutputLimits = .default,
        internalErrorHandler: @escaping (String, Error?) -> Void = { _, _ in },
        metadataProvider: @escaping () -> [String: String] = { [:] }
    ) {
        self.init(
            subsystem: subsystem,
            logDirectory: logDirectory,
            minimumLevel: minimumLevel,
            fileMinimumLevel: fileMinimumLevel,
            consoleMinimumLevel: consoleMinimumLevel,
            isFileLoggingEnabled: isFileLoggingEnabled,
            isConsoleLoggingEnabled: isConsoleLoggingEnabled,
            retention: retention,
            includesSessionHeader: includesSessionHeader,
            resourceMonitoring: resourceMonitoring,
            fileWriting: .default,
            privacy: privacy,
            outputLimits: outputLimits,
            formatter: LogFormatter(),
            internalErrorHandler: internalErrorHandler,
            metadataProvider: metadataProvider
        )
    }

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "ZYLogKit",
        logDirectory: URL = LogConfiguration.defaultLogDirectory(),
        minimumLevel: LogLevel = .trace,
        fileMinimumLevel: LogLevel = .trace,
        consoleMinimumLevel: LogLevel = .debug,
        isFileLoggingEnabled: Bool = true,
        isConsoleLoggingEnabled: Bool = true,
        retention: LogRetention = .default,
        includesSessionHeader: Bool = true,
        resourceMonitoring: LogResourceMonitoringConfiguration = .default,
        fileWriting: LogFileWritingConfiguration,
        privacy: LogPrivacyConfiguration = .default,
        outputLimits: LogOutputLimits = .default,
        formatter: LogFormatter = LogFormatter(),
        internalErrorHandler: @escaping (String, Error?) -> Void = { _, _ in },
        metadataProvider: @escaping () -> [String: String] = { [:] }
    ) {
        self.subsystem = subsystem
        self.logDirectory = logDirectory
        self.minimumLevel = minimumLevel
        self.fileMinimumLevel = fileMinimumLevel
        self.consoleMinimumLevel = consoleMinimumLevel
        self.isFileLoggingEnabled = isFileLoggingEnabled
        self.isConsoleLoggingEnabled = isConsoleLoggingEnabled
        self.retention = retention
        self.includesSessionHeader = includesSessionHeader
        self.resourceMonitoring = resourceMonitoring
        self.fileWriting = fileWriting
        self.privacy = privacy
        self.outputLimits = outputLimits
        self.formatter = formatter
        self.internalErrorHandler = internalErrorHandler
        self.metadataProvider = metadataProvider
    }

    public static var `default`: LogConfiguration {
        LogConfiguration()
    }

    public static func defaultLogDirectory(fileManager: FileManager = .default) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleName = Bundle.main.bundleIdentifier ?? "ZYLogKit"
        return baseDirectory
            .appendingPathComponent(bundleName, isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }
}
