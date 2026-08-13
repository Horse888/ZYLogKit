import Foundation

public struct LogOutputLimits: Sendable {
    public var maximumMessageCharacters: Int?
    public var maximumMetadataKeyCharacters: Int?
    public var maximumMetadataValueCharacters: Int?
    public var maximumMetadataItemCount: Int?
    public var maximumFormattedLineCharacters: Int?

    public init(
        maximumMessageCharacters: Int? = 8 * 1024,
        maximumMetadataKeyCharacters: Int? = 256,
        maximumMetadataValueCharacters: Int? = 2 * 1024,
        maximumMetadataItemCount: Int? = 64,
        maximumFormattedLineCharacters: Int? = 16 * 1024
    ) {
        self.maximumMessageCharacters = maximumMessageCharacters
        self.maximumMetadataKeyCharacters = maximumMetadataKeyCharacters
        self.maximumMetadataValueCharacters = maximumMetadataValueCharacters
        self.maximumMetadataItemCount = maximumMetadataItemCount
        self.maximumFormattedLineCharacters = maximumFormattedLineCharacters
    }

    public static var `default`: LogOutputLimits {
        LogOutputLimits()
    }

    public static var unlimited: LogOutputLimits {
        LogOutputLimits(
            maximumMessageCharacters: nil,
            maximumMetadataKeyCharacters: nil,
            maximumMetadataValueCharacters: nil,
            maximumMetadataItemCount: nil,
            maximumFormattedLineCharacters: nil
        )
    }
}
