import Foundation

public struct LogCategory: Hashable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String {
        rawValue.uppercased()
    }

    public static let general = LogCategory("general")
    public static let network = LogCategory("network")
    public static let database = LogCategory("database")
    public static let ui = LogCategory("ui")
    public static let ai = LogCategory("ai")
    public static let cloudKit = LogCategory("cloudkit")
    public static let sync = LogCategory("sync")
    public static let purchase = LogCategory("purchase")
    public static let performance = LogCategory("performance")
    public static let attachment = LogCategory("attachment")
}
