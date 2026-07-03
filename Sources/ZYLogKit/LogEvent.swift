import Foundation

struct LogEvent {
    let date: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
    let file: String
    let function: String
    let line: UInt
    let sessionID: String
    let metadata: [String: String]
}
