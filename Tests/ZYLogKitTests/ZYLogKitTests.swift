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
            retention: .disabled
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
            retention: .disabled
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZYLogKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
