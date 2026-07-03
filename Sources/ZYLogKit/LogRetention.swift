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
                size: UInt64(values?.fileSize ?? 0)
            )
        }

        if let maximumAge {
            let earliestAllowedDate = now.addingTimeInterval(-maximumAge)
            for file in files where file.modifiedAt < earliestAllowedDate {
                try? fileManager.removeItem(at: file.url)
            }
            files.removeAll { $0.modifiedAt < earliestAllowedDate }
        }

        files.sort { lhs, rhs in
            lhs.modifiedAt < rhs.modifiedAt
        }

        if let maximumFileCount, maximumFileCount >= 0, files.count > maximumFileCount {
            let removeCount = files.count - maximumFileCount
            for file in files.prefix(removeCount) {
                try? fileManager.removeItem(at: file.url)
            }
            files.removeFirst(removeCount)
        }

        if let maximumTotalSizeBytes {
            var totalSize = files.reduce(UInt64(0)) { $0 + $1.size }
            while totalSize > maximumTotalSizeBytes, let file = files.first {
                try? fileManager.removeItem(at: file.url)
                totalSize = totalSize > file.size ? totalSize - file.size : 0
                files.removeFirst()
            }
        }
    }
}

private struct LogFileInfo {
    let url: URL
    let modifiedAt: Date
    let size: UInt64
}
