import Foundation

public enum Log {
    private static let lock = NSLock()
    private static let fileWriter = FileWriter()
    private static let formatter = LogFormatter()
    private static var currentConfiguration = LogConfiguration.default
    private static var currentSession = SessionContext.make(configuration: currentConfiguration)
    private static var timers: [String: Date] = [:]
    private static var lastRetentionCheck: Date?
    private static var resourceMonitor: ResourceMonitor?

    public static var configuration: LogConfiguration {
        lock.withLock {
            currentConfiguration
        }
    }

    public static var sessionID: String {
        lock.withLock {
            currentSession.id
        }
    }

    public static func configure(_ configuration: LogConfiguration) {
        let session = SessionContext.make(configuration: configuration)

        let previousMonitor = lock.withLock {
            let monitor = resourceMonitor
            resourceMonitor = nil
            currentConfiguration = configuration
            currentSession = session
            timers.removeAll()
            lastRetentionCheck = nil
            return monitor
        }

        previousMonitor?.stop()
        fileWriter.close()
        writeSessionHeaderIfNeeded(configuration: configuration, session: session)
        scheduleRetentionIfNeeded(configuration: configuration, now: Date())
        startResourceMonitoringIfNeeded(configuration.resourceMonitoring)
    }

    public static func startNewSession() {
        let configuration = self.configuration
        let session = SessionContext.make(configuration: configuration)

        lock.withLock {
            currentSession = session
            timers.removeAll()
        }

        writeSessionHeaderIfNeeded(configuration: configuration, session: session)
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
        write(level: .trace, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
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
        write(level: .debug, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
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
        write(level: .info, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func notice(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .notice, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func warning(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .warning, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        category: LogCategory = .general,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        write(level: .error, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
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
            message: nsError.localizedDescription,
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
        write(level: .critical, message: message(), category: category, metadata: metadata, file: file, function: function, line: line)
    }

    public static func network(
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        info(message(), category: .network, metadata: metadata, file: file, function: function, line: line)
    }

    public static func database(
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        info(message(), category: .database, metadata: metadata, file: file, function: function, line: line)
    }

    public static func begin(
        _ name: String,
        category: LogCategory = .performance,
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        lock.withLock {
            timers[name] = Date()
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
        let startedAt = lock.withLock {
            timers.removeValue(forKey: name)
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
        let destination = try attachmentDestination(filename: filename, configuration: configuration)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: [.atomic])
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
        let destination = try attachmentDestination(
            filename: filename ?? sourceURL.lastPathComponent,
            configuration: configuration
        )
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        info("Attach \(destination.lastPathComponent)", category: .attachment, file: file, function: function, line: line)
        return destination
    }

    public static func flush() {
        fileWriter.flush()
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
        let monitor = lock.withLock {
            let monitor = resourceMonitor
            resourceMonitor = nil
            return monitor
        }
        monitor?.stop()
    }

    @discardableResult
    public static func export(to destinationDirectory: URL? = nil) throws -> URL {
        flush()

        let configuration = self.configuration
        let directory = destinationDirectory ?? FileManager.default.temporaryDirectory
        let timestamp = exportDateFormatter.string(from: Date())
        let destination = directory.appendingPathComponent("Logs-\(timestamp).zip")
        return try LogExporter.export(logDirectory: configuration.logDirectory, destinationURL: destination)
    }

    private static func write(
        level: LogLevel,
        message: String,
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

        let snapshot = lock.withLock {
            (currentConfiguration, currentSession)
        }

        let configuration = snapshot.0
        let session = snapshot.1

        guard level >= configuration.minimumLevel else {
            return
        }

        var eventMetadata = configuration.metadataProvider()
        metadata.forEach { key, value in
            eventMetadata[key] = value
        }

        let processInfo = ProcessInfo.processInfo
        let event = LogEvent(
            date: Date(),
            level: level,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            sessionID: session.id,
            processName: processInfo.processName,
            processID: processInfo.processIdentifier,
            thread: currentThreadDescription(),
            metadata: eventMetadata
        )
        let formattedLine = formatter.format(event)

        if configuration.isConsoleLoggingEnabled, level >= configuration.consoleMinimumLevel {
            OSLogBridge.write(formattedLine, event: event, configuration: configuration)
        }

        if configuration.isFileLoggingEnabled, level >= configuration.fileMinimumLevel {
            fileWriter.write(formattedLine, date: event.date, configuration: configuration)
        }

        scheduleRetentionIfNeeded(configuration: configuration, now: event.date)
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
            message: "Resource Usage",
            category: monitoring.category,
            metadata: snapshot.metadata,
            file: file,
            function: function,
            line: line
        )
    }

    private static func writeSessionHeaderIfNeeded(configuration: LogConfiguration, session: SessionContext) {
        guard configuration.includesSessionHeader, configuration.isFileLoggingEnabled else {
            return
        }

        fileWriter.write(lines: session.headerLines(), date: session.startedAt, configuration: configuration)
    }

    private static func scheduleRetentionIfNeeded(configuration: LogConfiguration, now: Date) {
        let shouldRun = lock.withLock { () -> Bool in
            if let lastRetentionCheck, now.timeIntervalSince(lastRetentionCheck) < 60 * 60 {
                return false
            }
            lastRetentionCheck = now
            return true
        }

        if shouldRun {
            fileWriter.applyRetention(configuration.retention, directory: configuration.logDirectory)
        }
    }

    private static func startResourceMonitoringIfNeeded(_ monitoring: LogResourceMonitoringConfiguration) {
        guard monitoring.isEnabled else {
            return
        }

        let monitor = ResourceMonitor(configuration: monitoring) { snapshot in
            recordAutomaticResourceUsage(snapshot, monitoring: monitoring)
        }

        lock.withLock {
            resourceMonitor = monitor
        }
        monitor.start()
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

    private static func sanitizeFilename(_ filename: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = filename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment-\(UUID().uuidString)" : cleaned
    }

    private static func currentThreadDescription() -> String {
        if Thread.isMainThread {
            return "main"
        }

        if let name = Thread.current.name, !name.isEmpty {
            return name
        }

        return "background"
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
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
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
