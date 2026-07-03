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
        XCTAssertTrue(content.contains("[INFO] [UI]"))
        XCTAssertTrue(content.contains("App Launch"))
        XCTAssertTrue(content.contains("[INFO] [NETWORK]"))
        XCTAssertTrue(content.contains("GET /user"))
        XCTAssertTrue(content.contains("[INFO] [DATABASE]"))
        XCTAssertTrue(content.contains("Insert Word"))
        XCTAssertTrue(content.contains("TestKey: TestValue"))
        XCTAssertTrue(content.contains("TestKey=TestValue"))

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
        XCTAssertTrue(content.contains("[PERFORMANCE]"))
        XCTAssertTrue(content.contains("Export PDF"))
    }

    func testLogLineIncludesDiagnosticContext() throws {
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
            metadataProvider: { ["UserID": "42"] }
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

        XCTAssertTrue(content.contains("[WARNING] [SYNC]"))
        XCTAssertTrue(content.contains("Context Check"))
        XCTAssertTrue(content.contains("[session:"))
        XCTAssertTrue(content.contains("[process:"))
        XCTAssertTrue(content.contains("pid:\(ProcessInfo.processInfo.processIdentifier)"))
        XCTAssertTrue(content.contains("[thread:"))
        XCTAssertTrue(content.contains("[source:Tests/ManualSource.swift:123]"))
        XCTAssertTrue(content.contains("[function:sampleFunction()]"))
        XCTAssertTrue(content.contains("RequestID=abc"))
        XCTAssertTrue(content.contains("UserID=42"))
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
        XCTAssertTrue(content.contains("[INFO] [RESOURCE]"))
        XCTAssertTrue(content.contains("Resource Usage"))
        XCTAssertTrue(content.contains("resource.cpu.percent="))
        XCTAssertTrue(content.contains("resource.memory.resident.mb="))
        XCTAssertTrue(content.contains("resource.memory.resident.bytes="))
        XCTAssertTrue(content.contains("[source:Tests/ResourceSource.swift:88]"))
        XCTAssertTrue(content.contains("[function:sampleResourceUsage()]"))
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
        XCTAssertTrue(content.contains("[INFO] [RESOURCE]"))
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
