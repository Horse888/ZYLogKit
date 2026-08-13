import XCTest
@testable import ZYLogKit

final class ZYLogKitTests: XCTestCase {
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

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        Log.stopResourceMonitoring()
        Log.flush()

        let content = try contentsOfFirstLogFile(in: directory)
        XCTAssertTrue(content.contains("ℹ️ INFO RESOURCE"))
        XCTAssertTrue(content.contains("Resource Usage"))
        XCTAssertTrue(content.contains("resource.cpu.percent="))
        XCTAssertTrue(content.contains("resource.memory.resident.mb="))
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
