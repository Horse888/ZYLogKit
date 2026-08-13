import Foundation

public enum LogBufferOverflowStrategy: Sendable {
    case dropOldest
    case dropNewest
}

public struct LogFileWritingConfiguration: Sendable {
    public var maximumPendingBytes: Int?
    public var batchSizeBytes: Int
    public var overflowStrategy: LogBufferOverflowStrategy
    public var synchronizesAfterLevel: LogLevel?
    public var fileProtection: LogFileProtection
    public var usesPrivateFilePermissions: Bool
    public var excludesLogDirectoryFromBackup: Bool
    public var internalErrorThrottleInterval: TimeInterval

    public init(
        maximumPendingBytes: Int? = 1024 * 1024,
        batchSizeBytes: Int = 64 * 1024,
        overflowStrategy: LogBufferOverflowStrategy = .dropOldest,
        synchronizesAfterLevel: LogLevel? = .critical,
        fileProtection: LogFileProtection = .completeUntilFirstUserAuthentication,
        usesPrivateFilePermissions: Bool = true,
        excludesLogDirectoryFromBackup: Bool = true,
        internalErrorThrottleInterval: TimeInterval = 60
    ) {
        self.maximumPendingBytes = maximumPendingBytes
        self.batchSizeBytes = batchSizeBytes
        self.overflowStrategy = overflowStrategy
        self.synchronizesAfterLevel = synchronizesAfterLevel
        self.fileProtection = fileProtection
        self.usesPrivateFilePermissions = usesPrivateFilePermissions
        self.excludesLogDirectoryFromBackup = excludesLogDirectoryFromBackup
        self.internalErrorThrottleInterval = internalErrorThrottleInterval
    }

    public static var `default`: LogFileWritingConfiguration {
        LogFileWritingConfiguration()
    }
}
