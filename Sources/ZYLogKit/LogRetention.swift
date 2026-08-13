import Foundation

public struct LogRetention: Sendable {
    public var maximumAge: TimeInterval?
    public var maximumTotalSizeBytes: UInt64?
    public var maximumFileCount: Int?

    public init(
        maximumAge: TimeInterval? = 7 * 24 * 60 * 60,
        maximumTotalSizeBytes: UInt64? = 20 * 1024 * 1024,
        maximumFileCount: Int? = 30
    ) {
        self.maximumAge = maximumAge
        self.maximumTotalSizeBytes = maximumTotalSizeBytes
        self.maximumFileCount = maximumFileCount
    }

    public static let `default` = LogRetention()
    public static let disabled = LogRetention(
        maximumAge: nil,
        maximumTotalSizeBytes: nil,
        maximumFileCount: nil
    )

    func apply(to directory: URL, fileManager: FileManager = .default, now: Date = Date()) {
        guard maximumAge != nil || maximumTotalSizeBytes != nil || maximumFileCount != nil else {
            return
        }

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var files = urls.compactMap { url -> LogFileInfo? in
            guard url.pathExtension == "log" else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else {
                return nil
            }

            return LogFileInfo(
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                size: UInt64(max(0, values?.fileSize ?? 0))
            )
        }

        if let maximumAge, maximumAge.isFinite {
            let earliestAllowedDate = now.addingTimeInterval(-max(0, maximumAge))
            files.removeAll { file in
                guard file.modifiedAt < earliestAllowedDate else {
                    return false
                }
                return remove(file, fileManager: fileManager)
            }
        }

        files.sort { lhs, rhs in
            lhs.modifiedAt < rhs.modifiedAt
        }

        if let maximumFileCount, maximumFileCount >= 0, files.count > maximumFileCount {
            var removeCount = files.count - maximumFileCount
            files.removeAll { file in
                guard removeCount > 0, remove(file, fileManager: fileManager) else {
                    return false
                }
                removeCount -= 1
                return true
            }
        }

        if let maximumTotalSizeBytes {
            var totalSize: UInt64 = 0
            for file in files {
                let (newSize, overflow) = totalSize.addingReportingOverflow(file.size)
                totalSize = overflow ? .max : newSize
            }
            files.removeAll { file in
                guard totalSize > maximumTotalSizeBytes,
                      remove(file, fileManager: fileManager) else {
                    return false
                }
                totalSize = totalSize > file.size ? totalSize - file.size : 0
                return true
            }
        }
    }

    private func remove(_ file: LogFileInfo, fileManager: FileManager) -> Bool {
        do {
            try fileManager.removeItem(at: file.url)
            return true
        } catch {
            return false
        }
    }
}

private struct LogFileInfo {
    let url: URL
    let modifiedAt: Date
    let size: UInt64
}
