import Foundation

public enum LogArchiveCompression: Sendable {
    case none
    case deflate
}

public struct LogExportConfiguration: Sendable {
    public var compression: LogArchiveCompression
    public var includesAttachments: Bool
    public var maximumFileCount: Int?
    public var maximumUncompressedSizeBytes: UInt64?
    public var fileProtection: LogFileProtection
    public var usesPrivateFilePermissions: Bool

    public init(
        compression: LogArchiveCompression = .deflate,
        includesAttachments: Bool = true,
        maximumFileCount: Int? = 10_000,
        maximumUncompressedSizeBytes: UInt64? = 256 * 1024 * 1024,
        fileProtection: LogFileProtection = .completeUntilFirstUserAuthentication,
        usesPrivateFilePermissions: Bool = true
    ) {
        self.compression = compression
        self.includesAttachments = includesAttachments
        self.maximumFileCount = maximumFileCount
        self.maximumUncompressedSizeBytes = maximumUncompressedSizeBytes
        self.fileProtection = fileProtection
        self.usesPrivateFilePermissions = usesPrivateFilePermissions
    }

    public static var `default`: LogExportConfiguration {
        LogExportConfiguration()
    }
}
