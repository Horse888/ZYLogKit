import Foundation

#if canImport(Compression)
import Compression
#endif

public enum LogExporter {
    @discardableResult
    public static func export(logDirectory: URL, destinationURL: URL) throws -> URL {
        try export(
            logDirectory: logDirectory,
            destinationURL: destinationURL,
            configuration: .default
        )
    }

    @discardableResult
    public static func export(
        logDirectory: URL,
        destinationURL: URL,
        configuration: LogExportConfiguration
    ) throws -> URL {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial"
        )

        do {
            let output = try POSIXFile(
                url: temporaryURL,
                access: .exclusiveCreate(usesPrivatePermissions: configuration.usesPrivateFilePermissions)
            )
            do {
                try ZipWriter.zip(
                    directory: logDirectory,
                    output: output,
                    rootName: "logs",
                    configuration: configuration,
                    excludedURLs: [destinationURL, temporaryURL]
                )
                try output.synchronize()
                output.close()
            } catch {
                output.close()
                throw error
            }

            try configuration.fileProtection.apply(
                to: temporaryURL,
                isDirectory: false,
                usesPrivateFilePermissions: configuration.usesPrivateFilePermissions,
                fileManager: fileManager
            )

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private enum ZipWriter {
    private static let chunkSize = 64 * 1024
    private static let utf8AndDataDescriptorFlags: UInt16 = 0x0808

    struct Entry {
        let name: String
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let offset: UInt32
        let compressionMethod: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
    }

    struct StreamResult {
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
    }

    static func zip(
        directory: URL,
        output: POSIXFile,
        rootName: String,
        configuration: LogExportConfiguration,
        excludedURLs: Set<URL>
    ) throws {
        let files = try allFiles(
            in: directory,
            configuration: configuration,
            excludedURLs: excludedURLs
        )
        var entries: [Entry] = []
        entries.reserveCapacity(files.count)
        var totalUncompressedSize: UInt64 = 0

        for file in files {
            guard output.offset <= UInt32.max else {
                throw LogArchiveError.archiveTooLarge
            }

            let offset = UInt32(output.offset)
            let relativeName = try zipPath(for: file, rootDirectory: directory, rootName: rootName)
            let nameData = Data(relativeName.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw LogArchiveError.pathTooLong(file)
            }

            let dos = dosDateTime(for: file)
            let compressionMethod = method(for: configuration.compression)
            try writeLocalHeader(
                nameData: nameData,
                compressionMethod: compressionMethod,
                dosTime: dos.time,
                dosDate: dos.date,
                output: output
            )

            let result: StreamResult
            switch configuration.compression {
            case .none:
                result = try copy(
                    file,
                    to: output,
                    existingUncompressedSize: totalUncompressedSize,
                    maximumUncompressedSize: configuration.maximumUncompressedSizeBytes
                )
            case .deflate:
                result = try deflate(
                    file,
                    to: output,
                    existingUncompressedSize: totalUncompressedSize,
                    maximumUncompressedSize: configuration.maximumUncompressedSizeBytes
                )
            }

            guard result.compressedSize <= UInt32.max,
                  result.uncompressedSize <= UInt32.max else {
                throw LogExporterError.fileTooLarge(file)
            }

            let (newTotalSize, overflow) = totalUncompressedSize.addingReportingOverflow(result.uncompressedSize)
            guard !overflow else {
                throw LogArchiveError.archiveTooLarge
            }
            totalUncompressedSize = newTotalSize

            if let maximumSize = configuration.maximumUncompressedSizeBytes,
               totalUncompressedSize > maximumSize {
                throw LogArchiveError.uncompressedSizeLimitExceeded(maximumSize)
            }

            try writeDataDescriptor(
                crc32: result.crc32,
                compressedSize: UInt32(result.compressedSize),
                uncompressedSize: UInt32(result.uncompressedSize),
                output: output
            )

            entries.append(Entry(
                name: relativeName,
                crc32: result.crc32,
                compressedSize: UInt32(result.compressedSize),
                uncompressedSize: UInt32(result.uncompressedSize),
                offset: offset,
                compressionMethod: compressionMethod,
                dosTime: dos.time,
                dosDate: dos.date
            ))
        }

        guard entries.count <= Int(UInt16.max), output.offset <= UInt32.max else {
            throw LogArchiveError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(output.offset)

        for entry in entries {
            try writeCentralDirectoryEntry(entry, output: output)
        }

        guard output.offset <= UInt32.max else {
            throw LogArchiveError.archiveTooLarge
        }
        let centralDirectoryEnd = UInt32(output.offset)
        let centralDirectorySize = centralDirectoryEnd - centralDirectoryOffset
        try writeEndOfCentralDirectory(
            entryCount: UInt16(entries.count),
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset,
            output: output
        )
    }

    private static func allFiles(
        in directory: URL,
        configuration: LogExportConfiguration,
        excludedURLs: Set<URL>
    ) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LogExporterError.missingLogDirectory(directory)
        }

        let excludedPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            return []
        }

        let rootComponents = directory.standardizedFileURL.pathComponents
        var files: [URL] = []
        var discoveredSize: UInt64 = 0

        for case let url as URL in enumerator {
            if let enumerationError {
                throw enumerationError
            }

            let standardizedURL = url.standardizedFileURL
            guard !excludedPaths.contains(standardizedURL.path) else {
                continue
            }

            let values = try standardizedURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])

            let components = standardizedURL.pathComponents
            guard components.starts(with: rootComponents) else {
                throw LogExporterError.invalidRelativePath(url)
            }
            let relativeComponents = Array(components.dropFirst(rootComponents.count))
            guard let firstComponent = relativeComponents.first else {
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if firstComponent == "attachments", !configuration.includesAttachments {
                if relativeComponents.count == 1, values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            if firstComponent != "attachments", standardizedURL.pathExtension != "log" {
                continue
            }

            let size = UInt64(max(0, values.fileSize ?? 0))
            let (newSize, overflow) = discoveredSize.addingReportingOverflow(size)
            guard !overflow else {
                throw LogArchiveError.archiveTooLarge
            }
            discoveredSize = newSize

            if let maximumSize = configuration.maximumUncompressedSizeBytes,
               discoveredSize > maximumSize {
                throw LogArchiveError.uncompressedSizeLimitExceeded(maximumSize)
            }

            files.append(standardizedURL)
            if let maximumFileCount = configuration.maximumFileCount,
               files.count > max(0, maximumFileCount) {
                throw LogArchiveError.fileCountLimitExceeded(maximumFileCount)
            }
            guard files.count <= Int(UInt16.max) else {
                throw LogArchiveError.archiveTooLarge
            }
        }

        if let enumerationError {
            throw enumerationError
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func writeLocalHeader(
        nameData: Data,
        compressionMethod: UInt16,
        dosTime: UInt16,
        dosDate: UInt16,
        output: POSIXFile
    ) throws {
        var header = Data()
        header.appendUInt32(0x04034b50)
        header.appendUInt16(20)
        header.appendUInt16(utf8AndDataDescriptorFlags)
        header.appendUInt16(compressionMethod)
        header.appendUInt16(dosTime)
        header.appendUInt16(dosDate)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt16(UInt16(nameData.count))
        header.appendUInt16(0)
        header.append(nameData)
        try output.write(header)
    }

    private static func writeDataDescriptor(
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        output: POSIXFile
    ) throws {
        var descriptor = Data()
        descriptor.appendUInt32(0x08074b50)
        descriptor.appendUInt32(crc32)
        descriptor.appendUInt32(compressedSize)
        descriptor.appendUInt32(uncompressedSize)
        try output.write(descriptor)
    }

    private static func writeCentralDirectoryEntry(_ entry: Entry, output: POSIXFile) throws {
        let nameData = Data(entry.name.utf8)
        guard nameData.count <= Int(UInt16.max) else {
            throw LogArchiveError.archiveTooLarge
        }

        var header = Data()
        header.appendUInt32(0x02014b50)
        header.appendUInt16(20)
        header.appendUInt16(20)
        header.appendUInt16(utf8AndDataDescriptorFlags)
        header.appendUInt16(entry.compressionMethod)
        header.appendUInt16(entry.dosTime)
        header.appendUInt16(entry.dosDate)
        header.appendUInt32(entry.crc32)
        header.appendUInt32(entry.compressedSize)
        header.appendUInt32(entry.uncompressedSize)
        header.appendUInt16(UInt16(nameData.count))
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt32(0)
        header.appendUInt32(entry.offset)
        header.append(nameData)
        try output.write(header)
    }

    private static func writeEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32,
        output: POSIXFile
    ) throws {
        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(entryCount)
        end.appendUInt16(entryCount)
        end.appendUInt32(centralDirectorySize)
        end.appendUInt32(centralDirectoryOffset)
        end.appendUInt16(0)
        try output.write(end)
    }

    private static func copy(
        _ fileURL: URL,
        to output: POSIXFile,
        existingUncompressedSize: UInt64,
        maximumUncompressedSize: UInt64?
    ) throws -> StreamResult {
        let input = try POSIXFile(url: fileURL, access: .read)
        defer {
            input.close()
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            buffer.deallocate()
        }

        var crc32 = CRC32()
        var size: UInt64 = 0
        while true {
            let count = try input.read(into: buffer, maximumCount: chunkSize)
            guard count > 0 else {
                break
            }

            crc32.update(buffer, count: count)
            size = try checkedFileSize(
                size,
                adding: count,
                fileURL: fileURL,
                existingTotalSize: existingUncompressedSize,
                maximumSize: maximumUncompressedSize
            )
            try output.write(buffer, count: count)
            guard output.offset <= UInt32.max else {
                throw LogArchiveError.archiveTooLarge
            }
        }

        return StreamResult(crc32: crc32.checksum, compressedSize: size, uncompressedSize: size)
    }

    private static func deflate(
        _ fileURL: URL,
        to output: POSIXFile,
        existingUncompressedSize: UInt64,
        maximumUncompressedSize: UInt64?
    ) throws -> StreamResult {
        #if canImport(Compression)
        let input = try POSIXFile(url: fileURL, access: .read)
        defer {
            input.close()
        }

        let sourceBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer {
            sourceBuffer.deallocate()
            destinationBuffer.deallocate()
        }

        var stream = compression_stream(
            dst_ptr: destinationBuffer,
            dst_size: 0,
            src_ptr: UnsafePointer(sourceBuffer),
            src_size: 0,
            state: nil
        )
        let initializationStatus = compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        guard initializationStatus != COMPRESSION_STATUS_ERROR else {
            throw LogArchiveError.compressionFailed(fileURL)
        }
        defer {
            compression_stream_destroy(&stream)
        }

        var crc32 = CRC32()
        var uncompressedSize: UInt64 = 0
        var compressedSize: UInt64 = 0

        while true {
            let sourceCount = try input.read(into: sourceBuffer, maximumCount: chunkSize)
            guard sourceCount > 0 else {
                break
            }

            crc32.update(sourceBuffer, count: sourceCount)
            uncompressedSize = try checkedFileSize(
                uncompressedSize,
                adding: sourceCount,
                fileURL: fileURL,
                existingTotalSize: existingUncompressedSize,
                maximumSize: maximumUncompressedSize
            )
            stream.src_ptr = UnsafePointer(sourceBuffer)
            stream.src_size = sourceCount

            while stream.src_size > 0 {
                let produced = try processCompressionStream(
                    &stream,
                    destinationBuffer: destinationBuffer,
                    flags: 0,
                    fileURL: fileURL
                )
                if produced > 0 {
                    compressedSize = try checkedFileSize(compressedSize, adding: produced, fileURL: fileURL)
                    try output.write(destinationBuffer, count: produced)
                    guard output.offset <= UInt32.max else {
                        throw LogArchiveError.archiveTooLarge
                    }
                }
            }
        }

        while true {
            stream.src_ptr = UnsafePointer(sourceBuffer)
            stream.src_size = 0
            stream.dst_ptr = destinationBuffer
            stream.dst_size = chunkSize
            let status = compression_stream_process(
                &stream,
                Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            )
            guard status != COMPRESSION_STATUS_ERROR else {
                throw LogArchiveError.compressionFailed(fileURL)
            }

            let produced = chunkSize - stream.dst_size
            if produced > 0 {
                compressedSize = try checkedFileSize(compressedSize, adding: produced, fileURL: fileURL)
                try output.write(destinationBuffer, count: produced)
                guard output.offset <= UInt32.max else {
                    throw LogArchiveError.archiveTooLarge
                }
            }

            if status == COMPRESSION_STATUS_END {
                break
            }
            guard produced > 0 else {
                throw LogArchiveError.compressionFailed(fileURL)
            }
        }

        return StreamResult(
            crc32: crc32.checksum,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize
        )
        #else
        throw LogArchiveError.compressionUnavailable
        #endif
    }

    #if canImport(Compression)
    private static func processCompressionStream(
        _ stream: inout compression_stream,
        destinationBuffer: UnsafeMutablePointer<UInt8>,
        flags: Int32,
        fileURL: URL
    ) throws -> Int {
        let sourceSizeBefore = stream.src_size
        stream.dst_ptr = destinationBuffer
        stream.dst_size = chunkSize
        let status = compression_stream_process(&stream, flags)
        guard status != COMPRESSION_STATUS_ERROR else {
            throw LogArchiveError.compressionFailed(fileURL)
        }

        let produced = chunkSize - stream.dst_size
        let consumed = sourceSizeBefore - stream.src_size
        guard produced > 0 || consumed > 0 || status == COMPRESSION_STATUS_END else {
            throw LogArchiveError.compressionFailed(fileURL)
        }
        return produced
    }
    #endif

    private static func checkedFileSize(
        _ current: UInt64,
        adding count: Int,
        fileURL: URL,
        existingTotalSize: UInt64 = 0,
        maximumSize: UInt64? = nil
    ) throws -> UInt64 {
        let (result, overflow) = current.addingReportingOverflow(UInt64(count))
        guard !overflow, result <= UInt32.max else {
            throw LogExporterError.fileTooLarge(fileURL)
        }
        if let maximumSize {
            let (totalSize, totalOverflow) = existingTotalSize.addingReportingOverflow(result)
            if totalOverflow || totalSize > maximumSize {
                throw LogArchiveError.uncompressedSizeLimitExceeded(maximumSize)
            }
        }
        return result
    }

    private static func method(for compression: LogArchiveCompression) -> UInt16 {
        switch compression {
        case .none:
            return 0
        case .deflate:
            return 8
        }
    }

    private static func zipPath(for fileURL: URL, rootDirectory: URL, rootName: String) throws -> String {
        let rootComponents = rootDirectory.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            throw LogExporterError.invalidRelativePath(fileURL)
        }

        let relativeComponents = fileComponents.dropFirst(rootComponents.count)
        guard !relativeComponents.isEmpty,
              relativeComponents.allSatisfy({ component in
                  component != "."
                      && component != ".."
                      && !component.contains("\\")
                      && component.unicodeScalars.allSatisfy {
                          !CharacterSet.controlCharacters.contains($0)
                      }
              }) else {
            throw LogExporterError.invalidRelativePath(fileURL)
        }
        return ([rootName] + relativeComponents).joined(separator: "/")
    }

    private static func dosDateTime(for fileURL: URL) -> (date: UInt16, time: UInt16) {
        let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: modifiedAt
        )

        let year = min(max((components.year ?? 1980) - 1980, 0), 127)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max((components.second ?? 0) / 2, 0), 29)

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

public enum LogArchiveError: Error, Equatable {
    case pathTooLong(URL)
    case fileCountLimitExceeded(Int)
    case uncompressedSizeLimitExceeded(UInt64)
    case archiveTooLarge
    case compressionUnavailable
    case compressionFailed(URL)
}

private struct CRC32 {
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

    private var value: UInt32 = 0xffffffff

    mutating func update(_ bytes: UnsafePointer<UInt8>, count: Int) {
        for index in 0..<count {
            let tableIndex = Int((value ^ UInt32(bytes[index])) & 0xff)
            value = Self.table[tableIndex] ^ (value >> 8)
        }
    }

    var checksum: UInt32 {
        value ^ 0xffffffff
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
