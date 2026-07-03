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
    let processName: String
    let processID: Int32
    let thread: String
    let metadata: [String: String]
}
