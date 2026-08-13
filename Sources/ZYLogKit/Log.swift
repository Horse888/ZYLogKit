import Foundation

// Mutable logging state is accessed through `lock`; writer and attachment work use their own guards.
private final class LogState: @unchecked Sendable {
    let lock = NSLock()
    let attachmentLock = NSLock()
    let fileWriter = FileWriter()
    var currentConfiguration: LogConfiguration
    var currentSanitizer: LogSanitizer
    var currentSession: SessionContext
    var timers: [String: Date] = [:]
    var lastRetentionCheck: Date?
    var resourceMonitor: ResourceMonitor?
    var configurationGeneration: UInt64 = 0
    var resourceMonitorGeneration: UInt64 = 0

    init() {
        let configuration = LogConfiguration.default
        currentConfiguration = configuration
        currentSanitizer = LogSanitizer(configuration: configuration)
        currentSession = SessionContext.make(configuration: configuration)
    }
}

public enum Log {
    private static let state = LogState()

    public static var configuration: LogConfiguration {
        state.lock.withLock {
            state.currentConfiguration
        }
    }

    public static var sessionID: String {
        state.lock.withLock {
            state.currentSession.id
        }
    }

    public static func configure(_ configuration: LogConfiguration) {
        let transition = state.lock.withLock { () -> (UInt64, UInt64, ResourceMonitor?) in
            state.configurationGeneration &+= 1
            state.resourceMonitorGeneration &+= 1
            let monitor = state.resourceMonitor
            state.resourceMonitor = nil
            return (state.configurationGeneration, state.resourceMonitorGeneration, monitor)
        }

        transition.2?.stop()
        state.fileWriter.close()

        let sanitizer = LogSanitizer(configuration: configuration)
        let session = SessionContext.make(configuration: configuration)
        let didApply = state.lock.withLock { () -> Bool in
            guard state.configurationGeneration == transition.0 else {
                return false
            }
            state.currentConfiguration = configuration
            state.currentSanitizer = sanitizer
            state.currentSession = session
            state.timers.removeAll()
            state.lastRetentionCheck = nil
            writeSessionHeaderIfNeeded(configuration: configuration, session: session, sanitizer: sanitizer)
            return true
        }

        guard didApply else {
            return
        }
        scheduleRetentionIfNeeded(configuration: configuration, now: Date())
        startResourceMonitoringIfNeeded(
            configuration.resourceMonitoring,
            configurationGeneration: transition.0,
            resourceMonitorGeneration: transition.1
        )
    }

    public static func startNewSession() {
        let snapshot = state.lock.withLock {
            (state.currentConfiguration, state.currentSanitizer, state.configurationGeneration)
        }
        let configuration = snapshot.0
        let sanitizer = snapshot.1
        let session = SessionContext.make(configuration: configuration)

        state.lock.withLock {
            guard state.configurationGeneration == snapshot.2 else {
                return
            }
            state.currentSession = session
            state.timers.removeAll()
            writeSessionHeaderIfNeeded(configuration: configuration, session: session, sanitizer: sanitizer)
        }
    }

    public static func trace(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        #if DEBUG
        write(level: .trace, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
        #endif
    }

    public static func debug(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        #if DEBUG
        write(level: .debug, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
        #endif
    }

    public static func info(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .info, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func notice(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .notice, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .warning, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .error, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func error(
        _ error: Error,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        var mergedMetadata = metadata
        let nsError = error as NSError
        mergedMetadata["error.domain"] = nsError.domain
        mergedMetadata["error.code"] = "\(nsError.code)"
        write(
            level: .error,
            message: { nsError.localizedDescription },
            category: category,
            metadata: mergedMetadata,
            file: file,
            function: function,
            line: line
        )
    }

    public static func critical(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .critical, message: message, category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func network(
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(
            level: .info,
            message: message,
            category: .network,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    public static func database(
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(
            level: .info,
            message: message,
            category: .database,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    public static func begin(
        _ name: String,
        category: LogCategory = .performance,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        state.lock.withLock {
            state.timers[name] = Date()
        }
        info("Begin \(name)", category: category, file: file, function: function, line: line)
    }

    public static func end(
        _ name: String,
        category: LogCategory = .performance,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        let startedAt = state.lock.withLock {
            state.timers.removeValue(forKey: name)
        }

        guard let startedAt else {
            warning("End \(name) without matching begin", category: category, file: file, function: function, line: line)
            return
        }

        info("\(name) \(Self.formatElapsedTime(from: startedAt, to: Date()))", category: category, file: file, function: function, line: line)
    }

    @discardableResult
    public static func measure<T>(
        _ name: String,
        category: LogCategory = .performance,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line,
        _ operation: () throws -> T
    ) rethrows -> T {
        let startedAt = Date()
        do {
            let result = try operation()
            info("\(name) \(Self.formatElapsedTime(from: startedAt, to: Date()))", category: category, file: file, function: function, line: line)
            return result
        } catch {
            self.error(error, category: category, file: file, function: function, line: line)
            throw error
        }
    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    @discardableResult
    public static func measure<T>(
        _ name: String,
        category: LogCategory = .performance,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        let startedAt = Date()
        do {
            let result = try await operation()
            info("\(name) \(Self.formatElapsedTime(from: startedAt, to: Date()))", category: category, file: file, function: function, line: line)
            return result
        } catch {
            self.error(error, category: category, file: file, function: function, line: line)
            throw error
        }
    }

    @discardableResult
    public static func attach(
        data: Data,
        filename: String,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) throws -> URL {
        let configuration = self.configuration
        let destination = try state.attachmentLock.withLock { () -> URL in
            let destination = try attachmentDestination(filename: filename, configuration: configuration)
            try prepareAttachmentDirectory(for: destination, configuration: configuration)
            do {
                try data.write(to: destination, options: [.atomic])
                try configuration.fileWriting.fileProtection.apply(
                    to: destination,
                    isDirectory: false,
                    usesPrivateFilePermissions: configuration.fileWriting.usesPrivateFilePermissions
                )
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return destination
        }
        info("Attach \(destination.lastPathComponent)", category: .attachment, file: file, function: function, line: line)
        return destination
    }

    @discardableResult
    public static func attach(
        file sourceURL: URL,
        filename: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) throws -> URL {
        let configuration = self.configuration
        let resolvedSourceURL = sourceURL.resolvingSymlinksInPath()
        let values = try resolvedSourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw LogAttachmentError.sourceIsNotRegularFile(sourceURL)
        }

        let destination = try state.attachmentLock.withLock { () -> URL in
            let destination = try attachmentDestination(
                filename: filename ?? sourceURL.lastPathComponent,
                configuration: configuration
            )
            try prepareAttachmentDirectory(for: destination, configuration: configuration)

            let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).partial"
            )
            do {
                try FileManager.default.copyItem(at: resolvedSourceURL, to: temporaryURL)
                try configuration.fileWriting.fileProtection.apply(
                    to: temporaryURL,
                    isDirectory: false,
                    usesPrivateFilePermissions: configuration.fileWriting.usesPrivateFilePermissions
                )
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }
            return destination
        }
        info("Attach \(destination.lastPathComponent)", category: .attachment, file: file, function: function, line: line)
        return destination
    }

    public static func flush() {
        state.fileWriter.flush()
    }

    public static func flushAsync(
        completionQueue: DispatchQueue = .main,
        completion: @escaping () -> Void = {}
    ) {
        let completion = UncheckedSendableBox(completion)
        state.fileWriter.flushAsync {
            completionQueue.async {
                completion.value()
            }
        }
    }

    public static func recordResourceUsage(
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        guard let snapshot = ResourceUsageSnapshot.current() else {
            warning(
                "Resource Usage Unavailable",
                category: .resource,
                metadata: ["resource.status": "unavailable"],
                file: file,
                function: function,
                line: line
            )
            return
        }

        let monitoring = configuration.resourceMonitoring
        writeResourceUsage(snapshot, monitoring: monitoring, file: file, function: function, line: line)
    }

    public static func stopResourceMonitoring() {
        let monitor = state.lock.withLock {
            state.resourceMonitorGeneration &+= 1
            let monitor = state.resourceMonitor
            state.resourceMonitor = nil
            return monitor
        }
        monitor?.stop()
    }

    @discardableResult
    public static func export(to destinationDirectory: URL? = nil) throws -> URL {
        try export(to: destinationDirectory, configuration: .default)
    }

    @discardableResult
    public static func export(
        to destinationDirectory: URL? = nil,
        configuration exportConfiguration: LogExportConfiguration
    ) throws -> URL {
        flush()

        let configuration = self.configuration
        let directory = destinationDirectory ?? FileManager.default.temporaryDirectory
        let timestamp = exportDateFormatterLock.withLock {
            exportDateFormatter.string(from: Date())
        }
        let identifier = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent("Logs-\(timestamp)-\(identifier).zip")
        return try LogExporter.export(
            logDirectory: configuration.logDirectory,
            destinationURL: destination,
            configuration: exportConfiguration
        )
    }

    public static func exportAsync(
        to destinationDirectory: URL? = nil,
        configuration exportConfiguration: LogExportConfiguration = .default,
        completionQueue: DispatchQueue = .main,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let completion = UncheckedSendableBox(completion)
        exportQueue.async {
            let result = Result {
                try export(to: destinationDirectory, configuration: exportConfiguration)
            }
            let resultBox = UncheckedSendableBox(result)
            completionQueue.async {
                completion.value(resultBox.value)
            }
        }
    }

    private static func write(
        level: LogLevel,
        message: () -> String,
        category: LogCategory,
        metadata: [String: String],
        file: String,
        function: String,
        line: UInt
    ) {
        #if !DEBUG
        guard level != .debug && level != .trace else {
            return
        }
        #endif

        let snapshot = state.lock.withLock {
            (state.currentConfiguration, state.currentSanitizer)
        }

        let configuration = snapshot.0
        let sanitizer = snapshot.1

        guard level >= configuration.minimumLevel else {
            return
        }

        let writesToConsole = configuration.isConsoleLoggingEnabled
            && level >= configuration.consoleMinimumLevel
        let writesToFile = configuration.isFileLoggingEnabled
            && level >= configuration.fileMinimumLevel
        guard writesToConsole || writesToFile else {
            return
        }

        var eventMetadata: [String: String] = [:]
        if configuration.formatter.includesMetadata {
            eventMetadata = MetadataProviderEvaluator.evaluate(configuration.metadataProvider)
            metadata.forEach { key, value in
                eventMetadata[key] = value
            }
        }

        let event = LogEvent(
            date: Date(),
            level: level,
            category: category,
            message: sanitizer.message(message()),
            file: file,
            function: function,
            line: line,
            metadata: sanitizer.metadata(eventMetadata)
        )
        let formattedLine = sanitizer.formattedLine(configuration.formatter.format(event))

        if writesToConsole {
            OSLogBridge.write(formattedLine, event: event, configuration: configuration)
        }

        if writesToFile {
            state.fileWriter.write(formattedLine, date: event.date, level: event.level, configuration: configuration)
            scheduleRetentionIfNeeded(configuration: configuration, now: event.date)
        }
    }

    private static func writeResourceUsage(
        _ snapshot: ResourceUsageSnapshot,
        monitoring: LogResourceMonitoringConfiguration,
        file: String,
        function: String,
        line: UInt
    ) {
        write(
            level: monitoring.level,
            message: { "Resource Usage" },
            category: monitoring.category,
            metadata: snapshot.metadata,
            file: file,
            function: function,
            line: line
        )
    }

    private static func writeSessionHeaderIfNeeded(
        configuration: LogConfiguration,
        session: SessionContext,
        sanitizer: LogSanitizer
    ) {
        guard configuration.includesSessionHeader, configuration.isFileLoggingEnabled else {
            return
        }

        state.fileWriter.write(
            lines: session.headerLines(sanitizer: sanitizer),
            date: session.startedAt,
            level: .info,
            configuration: configuration
        )
    }

    private static func scheduleRetentionIfNeeded(configuration: LogConfiguration, now: Date) {
        let shouldRun = state.lock.withLock { () -> Bool in
            if let lastRetentionCheck = state.lastRetentionCheck,
               now.timeIntervalSince(lastRetentionCheck) < 60 * 60 {
                return false
            }
            state.lastRetentionCheck = now
            return true
        }

        if shouldRun {
            state.fileWriter.applyRetention(configuration.retention, directory: configuration.logDirectory)
        }
    }

    private static func startResourceMonitoringIfNeeded(
        _ monitoring: LogResourceMonitoringConfiguration,
        configurationGeneration expectedConfigurationGeneration: UInt64,
        resourceMonitorGeneration expectedResourceMonitorGeneration: UInt64
    ) {
        guard monitoring.isEnabled,
              monitoring.interval.isFinite,
              monitoring.interval > 0 else {
            return
        }

        let monitor = ResourceMonitor(configuration: monitoring) { snapshot in
            recordAutomaticResourceUsage(snapshot, monitoring: monitoring)
        }

        let shouldStart = state.lock.withLock { () -> Bool in
            guard state.configurationGeneration == expectedConfigurationGeneration,
                  state.resourceMonitorGeneration == expectedResourceMonitorGeneration else {
                return false
            }
            state.resourceMonitor = monitor
            return true
        }
        guard shouldStart else {
            return
        }

        monitor.start()

        let remainsCurrent = state.lock.withLock {
            state.configurationGeneration == expectedConfigurationGeneration
                && state.resourceMonitorGeneration == expectedResourceMonitorGeneration
                && state.resourceMonitor === monitor
        }
        if !remainsCurrent {
            monitor.stop()
        }
    }

    private static func recordAutomaticResourceUsage(
        _ snapshot: ResourceUsageSnapshot,
        monitoring: LogResourceMonitoringConfiguration,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        writeResourceUsage(snapshot, monitoring: monitoring, file: file, function: function, line: line)
    }

    private static func attachmentDestination(filename: String, configuration: LogConfiguration) throws -> URL {
        let sessionID = sessionID
        let sanitizedFilename = sanitizeFilename(filename)
        var destination = configuration.logDirectory
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(sanitizedFilename)

        if FileManager.default.fileExists(atPath: destination.path) {
            let extensionName = destination.pathExtension
            let baseName = destination.deletingPathExtension().lastPathComponent
            let uniqueName = "\(baseName)-\(UUID().uuidString.prefix(8))"
            destination = destination
                .deletingLastPathComponent()
                .appendingPathComponent(uniqueName)

            if !extensionName.isEmpty {
                destination = destination.appendingPathExtension(extensionName)
            }
        }

        return destination
    }

    private static func prepareAttachmentDirectory(
        for destination: URL,
        configuration: LogConfiguration
    ) throws {
        let fileManager = FileManager.default
        let attachmentsDirectory = configuration.logDirectory
            .appendingPathComponent("attachments", isDirectory: true)
        let sessionDirectory = destination.deletingLastPathComponent()

        for directory in [configuration.logDirectory, attachmentsDirectory, sessionDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: configuration.fileWriting.fileProtection.fileAttributes
            )
            try configuration.fileWriting.fileProtection.apply(
                to: directory,
                isDirectory: true,
                usesPrivateFilePermissions: configuration.fileWriting.usesPrivateFilePermissions,
                fileManager: fileManager
            )
        }

        if configuration.fileWriting.excludesLogDirectoryFromBackup {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var logDirectory = configuration.logDirectory
            try logDirectory.setResourceValues(values)
        }
    }

    private static func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
        let boundedFilename = Self.utf8Prefix(filename, maximumBytes: 4 * 1024)
        var cleaned = boundedFilename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned == "." || cleaned == ".." || cleaned.isEmpty {
            cleaned = "attachment-\(UUID().uuidString)"
        } else if cleaned.hasPrefix(".") {
            cleaned = "attachment\(cleaned)"
        }

        if cleaned.utf8.count > 180 {
            let extensionName = Self.utf8Prefix((cleaned as NSString).pathExtension, maximumBytes: 32)
            let suffix = extensionName.isEmpty ? "" : ".\(extensionName)"
            let baseName = (cleaned as NSString).deletingPathExtension
            let base = Self.utf8Prefix(
                baseName,
                maximumBytes: max(1, 180 - suffix.utf8.count)
            )
            cleaned = (base.isEmpty ? "attachment" : base) + suffix
        }
        return cleaned
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else {
            return ""
        }

        var result = ""
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumBytes else {
                break
            }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }

    private static func formatElapsedTime(from startedAt: Date, to endedAt: Date) -> String {
        let elapsed = endedAt.timeIntervalSince(startedAt)
        if elapsed < 1 {
            return "\(Int((elapsed * 1000).rounded()))ms"
        }

        return String(format: "%.2fs", elapsed)
    }

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
    private static let exportDateFormatterLock = NSLock()
    private static let exportQueue = DispatchQueue(
        label: "com.zylogkit.export",
        qos: .utility,
        autoreleaseFrequency: .workItem,
        target: DispatchQueue.global(qos: .utility)
    )
}

public enum LogAttachmentError: Error, Equatable {
    case sourceIsNotRegularFile(URL)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }
        return try body()
    }
}
