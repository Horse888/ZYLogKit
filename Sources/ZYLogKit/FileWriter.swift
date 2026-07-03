import Foundation

final class FileWriter {
    private let queue = DispatchQueue(label: "com.zylogkit.file-writer")
    private let dayFormatter: DateFormatter
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?

    init() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = formatter
    }

    func write(_ line: String, date: Date, configuration: LogConfiguration) {
        queue.async {
            self.writeLocked(line, date: date, configuration: configuration)
        }
    }

    func write(lines: [String], date: Date, configuration: LogConfiguration) {
        queue.async {
            for line in lines {
                self.writeLocked(line, date: date, configuration: configuration)
            }
        }
    }

    func flush() {
        queue.sync {
            fileHandle?.synchronizeFile()
        }
    }

    func close() {
        queue.sync {
            self.closeLocked()
        }
    }

    func applyRetention(_ retention: LogRetention, directory: URL) {
        queue.async {
            retention.apply(to: directory)
        }
    }

    private func writeLocked(_ line: String, date: Date, configuration: LogConfiguration) {
        do {
            let fileURL = try logFileURL(for: date, configuration: configuration)
            if currentFileURL != fileURL {
                closeLocked()
                try FileManager.default.createDirectory(
                    at: configuration.logDirectory,
                    withIntermediateDirectories: true
                )

                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }

                fileHandle = try FileHandle(forWritingTo: fileURL)
                fileHandle?.seekToEndOfFile()
                currentFileURL = fileURL
            }

            guard let data = (line + "\n").data(using: .utf8) else {
                return
            }

            fileHandle?.write(data)
        } catch {
            currentFileURL = nil
            closeLocked()
        }
    }

    private func logFileURL(for date: Date, configuration: LogConfiguration) throws -> URL {
        configuration.logDirectory
            .appendingPathComponent(dayFormatter.string(from: date))
            .appendingPathExtension("log")
    }

    private func closeLocked() {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil
        currentFileURL = nil
    }
}
