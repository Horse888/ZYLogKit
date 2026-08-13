import Foundation

// Pending state is lock-protected; file descriptor state is owned by `queue`.
final class FileWriter: @unchecked Sendable {
    private static let maximumAsyncBatchCount = 16
    private static let maximumInternalErrorKeys = 64

    private struct InternalErrorKey: Hashable {
        let identifier: String
        let directory: String
    }

    private struct PendingWrite {
        let line: String
        let date: Date
        let level: LogLevel
        let configuration: LogConfiguration
        let byteCount: Int
    }

    private let queue: DispatchQueue
    private let diagnosticsQueue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private let diagnosticsLock = NSLock()
    private let dayFormatter: DateFormatter

    private var pendingWrites: [PendingWrite] = []
    private var pendingHead = 0
    private var pendingBytes = 0
    private var isDrainScheduled = false

    private var currentFileURL: URL?
    private var currentConfiguration: LogConfiguration?
    private var outputFile: POSIXFile?
    private var lastInternalErrorReports: [InternalErrorKey: Date] = [:]

    init() {
        queue = DispatchQueue(
            label: "com.zylogkit.file-writer",
            qos: .utility,
            autoreleaseFrequency: .workItem,
            target: DispatchQueue.global(qos: .utility)
        )
        diagnosticsQueue = DispatchQueue(
            label: "com.zylogkit.internal-diagnostics",
            qos: .utility,
            autoreleaseFrequency: .workItem,
            target: DispatchQueue.global(qos: .utility)
        )

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        dayFormatter = formatter

        queue.setSpecific(key: queueKey, value: 1)
    }

    func write(_ line: String, date: Date, level: LogLevel, configuration: LogConfiguration) {
        enqueue(CollectionOfOne(
            PendingWrite(
                line: line,
                date: date,
                level: level,
                configuration: configuration,
                byteCount: Self.byteCount(for: line)
            )
        ))
    }

    func write(lines: [String], date: Date, level: LogLevel, configuration: LogConfiguration) {
        enqueue(lines.lazy.map { line in
            PendingWrite(
                line: line,
                date: date,
                level: level,
                configuration: configuration,
                byteCount: Self.byteCount(for: line)
            )
        })
    }

    func flush() {
        performSynchronously {
            drainPendingSnapshot()
            synchronizeLocked()
        }
    }

    func flushAsync(completion: @escaping @Sendable () -> Void) {
        queue.async {
            self.drainPendingSnapshot()
            self.synchronizeLocked()
            completion()
        }
    }

    func close() {
        performSynchronously {
            drainPendingSnapshot()
            closeLocked(synchronize: true)
        }
    }

    func applyRetention(_ retention: LogRetention, directory: URL) {
        queue.async {
            self.drainPendingSnapshot()
            self.closeLocked(synchronize: true)
            retention.apply(to: directory)
        }
    }

    private func enqueue<S: Sequence>(_ writes: S) where S.Element == PendingWrite {
        var shouldScheduleDrain = false
        var droppedCount = 0
        var droppedConfiguration: LogConfiguration?

        stateLock.lock()
        for write in writes {
            let limit = write.configuration.fileWriting.maximumPendingBytes.map { max(0, $0) }
            let (prospectiveBytes, byteCountOverflow) = pendingBytes.addingReportingOverflow(write.byteCount)

            if byteCountOverflow || limit.map({ write.byteCount > $0 }) == true {
                droppedCount += 1
                droppedConfiguration = write.configuration
                continue
            }

            if let limit, prospectiveBytes > limit {
                switch write.configuration.fileWriting.overflowStrategy {
                case .dropOldest:
                    while pendingBytes > limit - write.byteCount, popFirstLocked() != nil {
                        droppedCount += 1
                        droppedConfiguration = write.configuration
                    }
                case .dropNewest:
                    droppedCount += 1
                    droppedConfiguration = write.configuration
                    continue
                }
            }

            pendingWrites.append(write)
            pendingBytes = pendingBytes + write.byteCount
        }

        if hasPendingWritesLocked, !isDrainScheduled {
            isDrainScheduled = true
            shouldScheduleDrain = true
        }
        stateLock.unlock()

        if let droppedConfiguration, droppedCount > 0 {
            reportInternalError(
                "ZYLogKit dropped \(droppedCount) buffered log entries because the pending-byte limit was reached.",
                error: FileWriterError.bufferOverflow(droppedCount),
                throttleKey: "buffer-overflow",
                configuration: droppedConfiguration
            )
        }

        if shouldScheduleDrain {
            queue.async {
                self.drainScheduledWrites()
            }
        }
    }

    private func drainScheduledWrites() {
        drainPendingWrites(maximumBatchCount: Self.maximumAsyncBatchCount)

        stateLock.lock()
        let needsAnotherDrain = hasPendingWritesLocked
        if !needsAnotherDrain {
            isDrainScheduled = false
        }
        stateLock.unlock()

        if needsAnotherDrain {
            queue.async {
                self.drainScheduledWrites()
            }
        }
    }

    private func drainPendingSnapshot() {
        stateLock.lock()
        let writeCount = pendingWrites.count - pendingHead
        stateLock.unlock()
        drainPendingWrites(maximumWriteCount: writeCount)
    }

    private func drainPendingWrites(
        maximumBatchCount: Int? = nil,
        maximumWriteCount: Int? = nil
    ) {
        var drainedBatchCount = 0
        var remainingWriteCount = maximumWriteCount

        while maximumBatchCount.map({ drainedBatchCount < $0 }) ?? true,
              remainingWriteCount.map({ $0 > 0 }) ?? true,
              let batch = takePendingBatch(maximumWriteCount: remainingWriteCount) {
            autoreleasepool {
                writeBatchLocked(batch)
            }
            drainedBatchCount += 1
            remainingWriteCount = remainingWriteCount.map { max(0, $0 - batch.count) }
        }
    }

    private func takePendingBatch(maximumWriteCount: Int?) -> [PendingWrite]? {
        stateLock.lock()
        defer {
            stateLock.unlock()
        }

        guard hasPendingWritesLocked else {
            return nil
        }

        let first = pendingWrites[pendingHead]
        let batchLimit = max(1, first.configuration.fileWriting.batchSizeBytes)
        var batch: [PendingWrite] = []
        var batchBytes = 0

        while hasPendingWritesLocked,
              maximumWriteCount.map({ batch.count < $0 }) ?? true {
            let next = pendingWrites[pendingHead]
            if !batch.isEmpty {
                if batchBytes >= batchLimit || next.byteCount > batchLimit - batchBytes {
                    break
                }
            }

            pendingHead += 1
            pendingBytes = max(0, pendingBytes - next.byteCount)
            batch.append(next)
            batchBytes += next.byteCount
        }

        compactPendingWritesLocked()
        return batch
    }

    private var hasPendingWritesLocked: Bool {
        pendingHead < pendingWrites.count
    }

    private func popFirstLocked() -> PendingWrite? {
        guard hasPendingWritesLocked else {
            return nil
        }

        let write = pendingWrites[pendingHead]
        pendingHead += 1
        pendingBytes = max(0, pendingBytes - write.byteCount)
        compactPendingWritesLocked()
        return write
    }

    private func compactPendingWritesLocked() {
        if pendingHead == pendingWrites.count {
            pendingWrites.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 1_024, pendingHead >= pendingWrites.count / 2 {
            pendingWrites.removeFirst(pendingHead)
            pendingHead = 0
        }
    }

    private func writeBatchLocked(_ batch: [PendingWrite]) {
        var index = 0

        while index < batch.count {
            let first = batch[index]
            let fileURL = logFileURL(for: first.date, configuration: first.configuration)
            var data = Data()
            var shouldSynchronize = false
            var nextIndex = index

            while nextIndex < batch.count {
                let write = batch[nextIndex]
                guard logFileURL(for: write.date, configuration: write.configuration) == fileURL else {
                    break
                }

                data.append(contentsOf: write.line.utf8)
                data.append(0x0a)
                if let level = write.configuration.fileWriting.synchronizesAfterLevel,
                   write.level >= level {
                    shouldSynchronize = true
                }
                nextIndex += 1
            }

            do {
                try openFileIfNeeded(fileURL, configuration: first.configuration)
                try writeAll(data)
                if shouldSynchronize {
                    try synchronizeFileDescriptor()
                }
            } catch {
                closeLocked(synchronize: false)
                reportInternalError(
                    "ZYLogKit failed to write a log line.",
                    error: error,
                    configuration: first.configuration
                )
            }

            index = nextIndex
        }
    }

    private func openFileIfNeeded(_ fileURL: URL, configuration: LogConfiguration) throws {
        guard currentFileURL != fileURL || outputFile == nil else {
            return
        }

        closeLocked(synchronize: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: configuration.logDirectory,
            withIntermediateDirectories: true,
            attributes: configuration.fileWriting.fileProtection.fileAttributes
        )

        do {
            try configuration.fileWriting.fileProtection.apply(
                to: configuration.logDirectory,
                isDirectory: true,
                usesPrivateFilePermissions: configuration.fileWriting.usesPrivateFilePermissions,
                fileManager: fileManager
            )
        } catch {
            reportInternalError(
                "ZYLogKit failed to apply protection to the log directory.",
                error: error,
                configuration: configuration
            )
        }

        if configuration.fileWriting.excludesLogDirectoryFromBackup {
            do {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var directory = configuration.logDirectory
                try directory.setResourceValues(values)
            } catch {
                reportInternalError(
                    "ZYLogKit failed to exclude the log directory from backups.",
                    error: error,
                    configuration: configuration
                )
            }
        }

        let openedFile = try POSIXFile(
            url: fileURL,
            access: .appendCreate(
                usesPrivatePermissions: configuration.fileWriting.usesPrivateFilePermissions
            )
        )
        do {
            try configuration.fileWriting.fileProtection.apply(
                to: fileURL,
                isDirectory: false,
                usesPrivateFilePermissions: configuration.fileWriting.usesPrivateFilePermissions,
                fileManager: fileManager
            )
        } catch {
            reportInternalError(
                "ZYLogKit failed to apply file protection to a log file.",
                error: error,
                configuration: configuration
            )
        }

        outputFile = openedFile
        currentFileURL = fileURL
        currentConfiguration = configuration
    }

    private func writeAll(_ data: Data) throws {
        guard let outputFile else {
            throw FileWriterError.invalidFileDescriptor
        }
        try outputFile.write(data)
    }

    private func synchronizeLocked() {
        guard outputFile != nil else {
            return
        }

        do {
            try synchronizeFileDescriptor()
        } catch {
            if let currentConfiguration {
                reportInternalError(
                    "ZYLogKit failed to synchronize a log file.",
                    error: error,
                    configuration: currentConfiguration
                )
            }
        }
    }

    private func synchronizeFileDescriptor() throws {
        guard let outputFile else {
            throw FileWriterError.invalidFileDescriptor
        }
        try outputFile.synchronize()
    }

    private func closeLocked(synchronize: Bool) {
        guard let outputFile else {
            currentFileURL = nil
            currentConfiguration = nil
            return
        }

        if synchronize {
            synchronizeLocked()
        }
        outputFile.close()
        self.outputFile = nil
        currentFileURL = nil
        currentConfiguration = nil
    }

    private func logFileURL(for date: Date, configuration: LogConfiguration) -> URL {
        configuration.logDirectory
            .appendingPathComponent(dayFormatter.string(from: date))
            .appendingPathExtension("log")
    }

    private func performSynchronously(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func reportInternalError(
        _ message: String,
        error: Error?,
        throttleKey: String? = nil,
        configuration: LogConfiguration
    ) {
        let now = Date()
        let configuredInterval = configuration.fileWriting.internalErrorThrottleInterval
        let interval = configuredInterval.isFinite ? max(0, configuredInterval) : 60
        let directory = configuration.logDirectory.standardizedFileURL.path
        let key = InternalErrorKey(identifier: throttleKey ?? message, directory: directory)

        diagnosticsLock.lock()
        let shouldReport = lastInternalErrorReports[key].map {
            now.timeIntervalSince($0) >= interval
        } ?? true
        if shouldReport {
            if lastInternalErrorReports[key] == nil,
               lastInternalErrorReports.count >= Self.maximumInternalErrorKeys {
                lastInternalErrorReports.removeAll(keepingCapacity: true)
            }
            lastInternalErrorReports[key] = now
        }
        diagnosticsLock.unlock()

        guard shouldReport else {
            return
        }

        let handler = UncheckedSendableBox(configuration.internalErrorHandler)
        let capturedError = UncheckedSendableBox(error)
        diagnosticsQueue.async {
            handler.value(message, capturedError.value)
        }
    }

    private static func byteCount(for line: String) -> Int {
        let count = line.utf8.count
        return count == Int.max ? Int.max : count + 1
    }
}

private enum FileWriterError: Error {
    case bufferOverflow(Int)
    case invalidFileDescriptor
}
