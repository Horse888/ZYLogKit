import Foundation

public enum LogExporter {
    @discardableResult
    public static func export(logDirectory: URL, destinationURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try ZipWriter.zip(directory: logDirectory, destinationURL: destinationURL, rootName: "logs")
        return destinationURL
    }
}

private enum ZipWriter {
    struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    static func zip(directory: URL, destinationURL: URL, rootName: String) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            throw LogExporterError.missingLogDirectory(directory)
        }

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer {
            handle.closeFile()
        }

        let files = try allFiles(in: directory)
        var entries: [Entry] = []

        for fileURL in files {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= UInt32.max else {
                throw LogExporterError.fileTooLarge(fileURL)
            }

            let offset = UInt32(handle.offsetInFile)
            let relativeName = try zipPath(for: fileURL, rootDirectory: directory, rootName: rootName)
            let nameData = Data(relativeName.utf8)
            let crc32 = CRC32.checksum(data)
            let dos = dosDateTime(for: fileURL)

            var localHeader = Data()
            localHeader.appendUInt32(0x04034b50)
            localHeader.appendUInt16(20)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(dos.time)
            localHeader.appendUInt16(dos.date)
            localHeader.appendUInt32(crc32)
            localHeader.appendUInt32(UInt32(data.count))
            localHeader.appendUInt32(UInt32(data.count))
            localHeader.appendUInt16(UInt16(nameData.count))
            localHeader.appendUInt16(0)
            localHeader.append(nameData)

            handle.write(localHeader)
            handle.write(data)

            entries.append(Entry(
                name: relativeName,
                crc32: crc32,
                size: UInt32(data.count),
                offset: offset,
                dosTime: dos.time,
                dosDate: dos.date
            ))
        }

        let centralDirectoryOffset = UInt32(handle.offsetInFile)

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            var centralHeader = Data()
            centralHeader.appendUInt32(0x02014b50)
            centralHeader.appendUInt16(20)
            centralHeader.appendUInt16(20)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(entry.dosTime)
            centralHeader.appendUInt16(entry.dosDate)
            centralHeader.appendUInt32(entry.crc32)
            centralHeader.appendUInt32(entry.size)
            centralHeader.appendUInt32(entry.size)
            centralHeader.appendUInt16(UInt16(nameData.count))
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt32(0)
            centralHeader.appendUInt32(entry.offset)
            centralHeader.append(nameData)

            handle.write(centralHeader)
        }

        let centralDirectorySize = UInt32(handle.offsetInFile) - centralDirectoryOffset
        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt16(UInt16(entries.count))
        end.appendUInt32(centralDirectorySize)
        end.appendUInt32(centralDirectoryOffset)
        end.appendUInt16(0)
        handle.write(end)
    }

    private static func allFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL else {
                return nil
            }

            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
        .sorted { $0.path < $1.path }
    }

    private static func zipPath(for fileURL: URL, rootDirectory: URL, rootName: String) throws -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            throw LogExporterError.invalidRelativePath(fileURL)
        }

        let relativePath = String(filePath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(rootName)/\(relativePath)"
    }

    private static func dosDateTime(for fileURL: URL) -> (date: UInt16, time: UInt16) {
        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: modifiedAt
        )

        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2

        let dosDate = UInt16((year << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        return (dosDate, dosTime)
    }
}

public enum LogExporterError: Error, Equatable {
    case missingLogDirectory(URL)
    case fileTooLarge(URL)
    case invalidRelativePath(URL)
}

private enum CRC32 {
    private static let table: [UInt32] = (0...255).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xedb88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
