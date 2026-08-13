import XCTest
@testable import ZYLogKit

final class ZYLogKitTests: XCTestCase {
    func testFilteredAutoclosureIsNotEvaluated() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            minimumLevel: .error,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        var evaluationCount = 0
        func message() -> String {
            evaluationCount += 1
            return "Filtered"
        }

        Log.info(message())
        Log.network(message())
        Log.database(message())

        XCTAssertEqual(evaluationCount, 0)
    }

    func testMetadataProviderCanLogWithoutRecursiveEvaluation() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var providerCallCount = 0
        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            metadataProvider: {
                providerCallCount += 1
                if providerCallCount < 4 {
                    Log.info("Nested provider log")
                }
                return ["provider.calls": "\(providerCallCount)"]
            }
        ))

        Log.info("Outer log")
        Log.flush()

        XCTAssertEqual(providerCallCount, 1)
        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("Nested provider log"))
        XCTAssertTrue(content.contains("Outer log"))
    }

    func testFlushCompletesWhileProducersContinueWriting() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let writer = FileWriter()
        let configuration = LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            fileWriting: LogFileWritingConfiguration(
                maximumPendingBytes: 4 * 1024,
                batchSizeBytes: 1
            )
        )
        let producerCount = 4
        let producers = DispatchGroup()
        let shouldStop = LockedFlag()

        for _ in 0..<producerCount {
            producers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while !shouldStop.value {
                    writer.write("entry", date: Date(), level: .info, configuration: configuration)
                }
                producers.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.05)
        let expectation = expectation(description: "flush is not starved")
        DispatchQueue.global(qos: .utility).async {
            writer.flush()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)

        shouldStop.value = true
        XCTAssertEqual(producers.wait(timeout: .now() + 10), .success)
        writer.close()
    }

    func testConcurrentWritesProduceCompleteDistinctLines() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            fileWriting: LogFileWritingConfiguration(
                maximumPendingBytes: 4 * 1024 * 1024,
                batchSizeBytes: 32 * 1024
            )
        ))

        let count = 500
        DispatchQueue.concurrentPerform(iterations: count) { index in
            Log.info("Concurrent Entry", metadata: ["index": "\(index)"])
        }
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        let loggedIndexes = Set(content
            .split(separator: "\n")
            .filter { $0.contains("Concurrent Entry") }
            .compactMap { line -> Int? in
                guard let range = line.range(of: "index=") else {
                    return nil
                }
                let digits = line[range.upperBound...].prefix { $0.isNumber }
                return Int(digits)
            })

        XCTAssertEqual(loggedIndexes, Set(0..<count))
    }

    func testLogFilesUsePrivatePermissionsByDefault() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled
        ))
        Log.info("Private file")
        Log.flush()

        let logFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "log" })
        let attributes = try FileManager.default.attributesOfItem(atPath: logFile.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testBoundedWriterDropsOversizedEntryAndReportsIt() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let expectation = expectation(description: "overflow is reported")
        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            fileWriting: LogFileWritingConfiguration(
                maximumPendingBytes: 1,
                batchSizeBytes: 1,
                internalErrorThrottleInterval: 0
            ),
            internalErrorHandler: { message, _ in
                if message.contains("dropped") {
                    expectation.fulfill()
                }
            }
        ))

        Log.info("Too large for the bounded queue")

        wait(for: [expectation], timeout: 2)
        Log.flush()
        let logFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "log" }
        XCTAssertTrue(logFiles.isEmpty)
    }

    func testOverflowDiagnosticsAreThrottledAcrossDifferentDropCounts() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let firstReport = expectation(description: "first overflow report")
        let reportCount = LockedCounter()
        let configuration = LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            fileWriting: LogFileWritingConfiguration(maximumPendingBytes: 0),
            internalErrorHandler: { message, _ in
                guard message.contains("dropped") else {
                    return
                }
                if reportCount.increment() == 1 {
                    firstReport.fulfill()
                }
            }
        )
        let writer = FileWriter()

        for lineCount in 1...3 {
            writer.write(
                lines: Array(repeating: "entry", count: lineCount),
                date: Date(),
                level: .info,
                configuration: configuration
            )
        }

        wait(for: [firstReport], timeout: 2)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(reportCount.value, 1)
        writer.close()
    }

    func testAsyncFlushCompletesAfterPendingWritesReachDisk() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled
        ))
        Log.info("Async Flush")

        let expectation = expectation(description: "flush completion")
        Log.flushAsync(completionQueue: .global(qos: .utility)) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        XCTAssertTrue(try contentsOfFirstLogFile(in: directory).contains("Async Flush"))
    }

    func testWritesLogFileAndExportsZip() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled,
            metadataProvider: { ["TestKey": "TestValue"] }
        ))

        Log.info("App Launch", category: .ui)
        Log.network("GET /user")
        Log.database("Insert Word")
        Log.flush()

        let logFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "log" }

        XCTAssertEqual(logFiles.count, 1)

        let content = try String(contentsOf: logFiles[0], encoding: .utf8)
        XCTAssertTrue(content.contains("===== Session Begin ====="))
        XCTAssertTrue(content.contains("INFO UI"))
        XCTAssertTrue(content.contains("App Launch"))
        XCTAssertTrue(content.contains("INFO NETWORK"))
        XCTAssertTrue(content.contains("GET /user"))
        XCTAssertTrue(content.contains("INFO DATABASE"))
        XCTAssertTrue(content.contains("Insert Word"))
        XCTAssertTrue(content.contains("TestKey: TestValue"))
        XCTAssertTrue(content.contains("TestKey=TestValue"))
        XCTAssertTrue(content.contains("ℹ️ INFO UI"))

        let zipURL = try Log.export(to: directory)
        let zipData = try Data(contentsOf: zipURL)
        XCTAssertEqual(zipData.prefix(2), Data([0x50, 0x4b]))
        XCTAssertTrue(zipData.contains(Data("logs/".utf8)))
    }

    func testAttachDataIsIncludedInExport() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        let attachmentURL = try Log.attach(data: Data("image".utf8), filename: "screenshot.png")
        Log.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: attachmentURL.path))

        let zipURL = try Log.export(to: directory)
        let zipData = try Data(contentsOf: zipURL)
        XCTAssertTrue(zipData.contains(Data("attachments/".utf8)))
        XCTAssertTrue(zipData.contains(Data("screenshot.png".utf8)))
    }

    func testAttachmentFilenameCannotEscapeSessionDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        let attachment = try Log.attach(data: Data("safe".utf8), filename: "..")
        let attachmentsDirectory = directory.appendingPathComponent("attachments", isDirectory: true)

        XCTAssertTrue(attachment.standardizedFileURL.path.hasPrefix(attachmentsDirectory.standardizedFileURL.path + "/"))
        XCTAssertNotEqual(attachment.lastPathComponent, "..")
        XCTAssertEqual(try Data(contentsOf: attachment), Data("safe".utf8))
    }

    func testExportUsesStreamingDeflateCompression() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let source = directory.appendingPathComponent("2026-08-13.log")
        let sourceData = Data(repeating: 0x41, count: 512 * 1024)
        try sourceData.write(to: source)
        let destination = directory.appendingPathComponent("compressed.zip")

        try LogExporter.export(
            logDirectory: directory,
            destinationURL: destination,
            configuration: LogExportConfiguration(compression: .deflate)
        )

        let archive = try Data(contentsOf: destination)
        XCTAssertEqual(archive.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
        XCTAssertEqual(archive[archive.startIndex + 8], 0x08)
        XCTAssertEqual(archive[archive.startIndex + 9], 0x00)
        XCTAssertLessThan(archive.count, sourceData.count / 10)
    }

    func testExportCanExcludeAttachments() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data("log".utf8).write(to: directory.appendingPathComponent("2026-08-13.log"))
        let attachments = directory.appendingPathComponent("attachments/session", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: attachments.appendingPathComponent("private.txt"))
        let destination = directory.appendingPathComponent("without-attachments.zip")

        try LogExporter.export(
            logDirectory: directory,
            destinationURL: destination,
            configuration: LogExportConfiguration(includesAttachments: false)
        )

        let archive = try Data(contentsOf: destination)
        XCTAssertFalse(archive.contains(Data("private.txt".utf8)))
    }

    func testFailedExportPreservesExistingDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try Data(repeating: 0x41, count: 32).write(to: directory.appendingPathComponent("2026-08-13.log"))
        let destination = directory.appendingPathComponent("existing.zip")
        let existingData = Data("existing archive".utf8)
        try existingData.write(to: destination)

        XCTAssertThrowsError(try LogExporter.export(
            logDirectory: directory,
            destinationURL: destination,
            configuration: LogExportConfiguration(maximumUncompressedSizeBytes: 16)
        ))
        XCTAssertEqual(try Data(contentsOf: destination), existingData)
    }

    func testExportSkipsSymbolicLinks() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: logs.appendingPathComponent("2026-08-13.log"))
        let external = directory.appendingPathComponent("outside.log")
        try Data("secret".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: logs.appendingPathComponent("leak.log"),
            withDestinationURL: external
        )
        let destination = directory.appendingPathComponent("symlink-safe.zip")

        try LogExporter.export(logDirectory: logs, destinationURL: destination)

        let archive = try Data(contentsOf: destination)
        XCTAssertFalse(archive.contains(Data("leak.log".utf8)))
    }

    func testExportSkipsSymbolicLinkDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        let external = directory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: logs.appendingPathComponent("2026-08-13.log"))
        try Data("secret".utf8).write(to: external.appendingPathComponent("private-attachment.txt"))
        try FileManager.default.createSymbolicLink(
            at: logs.appendingPathComponent("attachments"),
            withDestinationURL: external
        )
        let destination = directory.appendingPathComponent("symlink-directory-safe.zip")

        try LogExporter.export(logDirectory: logs, destinationURL: destination)

        let archive = try Data(contentsOf: destination)
        XCTAssertFalse(archive.contains(Data("private-attachment.txt".utf8)))
    }

    func testExportRejectsBackslashPathComponents() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let unsafeLog = directory.appendingPathComponent("safe\\..\\escape.log")
        try Data("unsafe".utf8).write(to: unsafeLog)

        XCTAssertThrowsError(try LogExporter.export(
            logDirectory: directory,
            destinationURL: directory.appendingPathComponent("unsafe.zip")
        )) { error in
            XCTAssertEqual(error as? LogExporterError, .invalidRelativePath(unsafeLog))
        }
    }

    func testMeasureReturnsOperationValue() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        let value = Log.measure("Export PDF") {
            "done"
        }

        XCTAssertEqual(value, "done")
        Log.flush()

        let logFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "log" })
        let content = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(content.contains("PERFORMANCE"))
        XCTAssertTrue(content.contains("Export PDF"))
    }

    func testLogLineUsesCompactReadableContext() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled,
            metadataProvider: {
                [
                    "UserID": "42",
                    "app.name": "出入口制图",
                    "app.version": "5.1.2",
                    "app.build": "260630",
                    "device.model": "iPad",
                    "system.version": "27.0"
                ]
            }
        ))

        Log.warning(
            "Context Check",
            category: .sync,
            metadata: ["RequestID": "abc"],
            file: "Tests/ManualSource.swift",
            function: "sampleFunction()",
            line: 123
        )
        Log.flush()

        let logFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "log" })
        let content = try String(contentsOf: logFile, encoding: .utf8)
        let line = try XCTUnwrap(content
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("Context Check") })

        XCTAssertTrue(line.contains("⚠️ WARNING SYNC ManualSource.swift:123 sampleFunction() - Context Check"))
        XCTAssertTrue(line.contains("Context Check"))
        XCTAssertFalse(line.contains("[session:"))
        XCTAssertFalse(line.contains("[process:"))
        XCTAssertFalse(line.contains("pid:"))
        XCTAssertFalse(line.contains("[thread:"))
        XCTAssertTrue(line.contains("RequestID=abc"))
        XCTAssertTrue(line.contains("UserID=42"))
        XCTAssertTrue(line.contains("app=出入口制图 5.1.2(260630)"))
        XCTAssertTrue(line.contains("device=iPad OS 27.0"))
        XCTAssertFalse(line.contains("app.build="))
        XCTAssertFalse(line.contains("app.name="))
        XCTAssertFalse(line.contains("app.version="))
        XCTAssertFalse(line.contains("device.model="))
        XCTAssertFalse(line.contains("system.version="))
    }

    func testFormatterCanOmitSourceAndMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        var metadataProviderCallCount = 0

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            fileWriting: .default,
            formatter: LogFormatter(includesSourceLocation: false, includesMetadata: false),
            metadataProvider: {
                metadataProviderCallCount += 1
                return ["Hidden": "Value"]
            }
        ))

        Log.info(
            "Minimal",
            metadata: ["RequestID": "abc"],
            file: "Tests/Hidden.swift",
            function: "hiddenFunction()",
            line: 99
        )
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("INFO GENERAL - Minimal"))
        XCTAssertFalse(content.contains("Hidden.swift"))
        XCTAssertFalse(content.contains("hiddenFunction"))
        XCTAssertFalse(content.contains("RequestID"))
        XCTAssertFalse(content.contains("Hidden=Value"))
        XCTAssertEqual(metadataProviderCallCount, 0)
    }

    func testErrorLogUsesRedExclamationEmoji() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        Log.error(
            "Failure",
            category: .database,
            file: "Tests/ErrorSource.swift",
            function: "failingFunction()",
            line: 44
        )
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        let line = try XCTUnwrap(content
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("Failure") })

        XCTAssertTrue(line.contains("❗ ERROR DATABASE ErrorSource.swift:44 failingFunction() - Failure"))
        XCTAssertFalse(line.contains("[session:"))
        XCTAssertFalse(line.contains("[process:"))
    }

    func testFormattedDateUsesLocalTimeZone() {
        let date = Date(timeIntervalSince1970: 1_787_000_000)
        let expectedFormatter = DateFormatter()
        expectedFormatter.calendar = Calendar(identifier: .gregorian)
        expectedFormatter.locale = Locale(identifier: "en_US_POSIX")
        expectedFormatter.timeZone = .current
        expectedFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"

        XCTAssertEqual(LogFormatter.formattedDate(date), expectedFormatter.string(from: date))
    }

    func testRecordResourceUsageIncludesCPUAndMemory() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled
        ))

        Log.recordResourceUsage(
            file: "Tests/ResourceSource.swift",
            function: "sampleResourceUsage()",
            line: 88
        )
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("INFO RESOURCE"))
        XCTAssertTrue(content.contains("Resource Usage"))
        XCTAssertTrue(content.contains("resource.cpu.percent="))
        XCTAssertTrue(content.contains("resource.memory.resident.mb="))
        XCTAssertTrue(content.contains("ResourceSource.swift:88"))
        XCTAssertTrue(content.contains("sampleResourceUsage()"))
    }

    func testLogRedactsSensitiveMessagesMetadataAndSessionHeader() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled,
            metadataProvider: {
                [
                    "apiKey": "provider-secret",
                    "bad\nkey": "bad\rvalue",
                    "Environment": "test"
                ]
            }
        ))

        Log.info(
            "Login token=abc123 password=hunter2 user=user@example.com Authorization: Bearer bearer-token",
            metadata: [
                "Access Token": "space-secret",
                "refreshToken": "refresh-secret",
                "line\nbreak": "tab\tvalue",
                "SafeKey": "visible"
            ]
        )
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertFalse(content.contains("abc123"))
        XCTAssertFalse(content.contains("hunter2"))
        XCTAssertFalse(content.contains("user@example.com"))
        XCTAssertFalse(content.contains("bearer-token"))
        XCTAssertFalse(content.contains("refresh-secret"))
        XCTAssertFalse(content.contains("space-secret"))
        XCTAssertFalse(content.contains("provider-secret"))
        XCTAssertFalse(content.contains("bad\nkey"))
        XCTAssertFalse(content.contains("bad\rvalue"))
        XCTAssertTrue(content.contains("token=[REDACTED]"))
        XCTAssertTrue(content.contains("password=[REDACTED]"))
        XCTAssertTrue(content.contains("[REDACTED_EMAIL]"))
        XCTAssertTrue(content.contains("Authorization: Bearer [REDACTED]"))
        XCTAssertTrue(content.contains("Access Token=[REDACTED]"))
        XCTAssertTrue(content.contains("refreshToken=[REDACTED]"))
        XCTAssertTrue(content.contains("line\\nbreak=tab\\tvalue"))
        XCTAssertTrue(content.contains("bad\\nkey: bad\\rvalue"))
        XCTAssertTrue(content.contains("apiKey: [REDACTED]"))
        XCTAssertTrue(content.contains("SafeKey=visible"))
        XCTAssertTrue(content.contains("Environment: test"))
    }

    func testOutputLimitsTruncateMessageAndMetadata() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: .disabled,
            outputLimits: LogOutputLimits(
                maximumMessageCharacters: 5,
                maximumMetadataKeyCharacters: 5,
                maximumMetadataValueCharacters: 4,
                maximumMetadataItemCount: 2,
                maximumFormattedLineCharacters: nil
            )
        ))

        Log.info(
            "abcdef",
            metadata: [
                "a": "123456",
                "b": "ok",
                "cLongKey": "dropped",
                "d": "dropped"
            ]
        )
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("abcde...[truncated]"))
        XCTAssertTrue(content.contains("a=1234...[truncated]"))
        XCTAssertTrue(content.contains("b=ok"))
        XCTAssertTrue(content.contains("log.metadata.dropped_count=2"))
        XCTAssertFalse(content.contains("cLongKey=dropped"))
        XCTAssertFalse(content.contains("d=dropped"))
    }

    func testInternalErrorHandlerReceivesFileWriteFailures() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let fileURL = directory.appendingPathComponent("NotADirectory")
        try Data("occupied".utf8).write(to: fileURL)
        let expectation = expectation(description: "internal error handler")
        var capturedMessage: String?

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: fileURL,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            internalErrorHandler: { message, _ in
                capturedMessage = message
                expectation.fulfill()
            }
        ))

        Log.info("Cannot write")
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(capturedMessage, "ZYLogKit failed to write a log line.")
    }

    func testInternalErrorHandlerCanFlushWithoutDeadlockingWriter() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let fileURL = directory.appendingPathComponent("NotADirectory")
        try Data("occupied".utf8).write(to: fileURL)
        let expectation = expectation(description: "reentrant flush returns")

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: fileURL,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            includesSessionHeader: false,
            resourceMonitoring: .disabled,
            internalErrorHandler: { _, _ in
                Log.flush()
                expectation.fulfill()
            }
        ))

        Log.info("Cannot write")

        wait(for: [expectation], timeout: 2)
    }

    func testResourceMonitoringWritesAutomatically() throws {
        let directory = try makeTemporaryDirectory()
        defer {
            Log.stopResourceMonitoring()
            try? FileManager.default.removeItem(at: directory)
        }

        Log.configure(LogConfiguration(
            subsystem: "tests.zylogkit",
            logDirectory: directory,
            isConsoleLoggingEnabled: false,
            retention: .disabled,
            resourceMonitoring: LogResourceMonitoringConfiguration(interval: 0.05)
        ))

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        Log.stopResourceMonitoring()
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("ℹ️ INFO RESOURCE"))
        XCTAssertTrue(content.contains("Resource Usage"))
        XCTAssertTrue(content.contains("resource.cpu.percent="))
        XCTAssertTrue(content.contains("resource.memory.resident.mb="))
    }

    func testResourceMonitorCanStopFromItsHandler() {
        let expectation = expectation(description: "monitor stops without deadlock")
        var monitor: ResourceMonitor?
        monitor = ResourceMonitor(
            configuration: LogResourceMonitoringConfiguration(interval: 0.01)
        ) { _ in
            monitor?.stop()
            expectation.fulfill()
        }

        monitor?.start()
        wait(for: [expectation], timeout: 2)
        monitor = nil
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZYLogKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contentsOfFirstLogFile(in directory: URL) throws -> String {
        let logFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "log" })
        return try String(contentsOf: logFile, encoding: .utf8)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        get {
            lock.lock()
            defer {
                lock.unlock()
            }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedValue
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storedValue += 1
        let value = storedValue
        lock.unlock()
        return value
    }
}
