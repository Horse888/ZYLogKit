import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum POSIXFileAccess {
    case appendCreate(usesPrivatePermissions: Bool)
    case read
    case exclusiveCreate(usesPrivatePermissions: Bool)
}

enum POSIXFileError: Error, Equatable {
    case openFailed(URL, Int32)
    case notRegularFile(URL)
    case readFailed(URL, Int32)
    case writeFailed(URL, Int32)
    case synchronizeFailed(URL, Int32)
    case offsetOverflow(URL)
}

final class POSIXFile {
    let url: URL
    private(set) var offset: UInt64 = 0
    private var descriptor: Int32

    init(url: URL, access: POSIXFileAccess) throws {
        self.url = url
        descriptor = Self.open(path: url.path, access: access)
        guard descriptor >= 0 else {
            throw POSIXFileError.openFailed(url, errno)
        }

        guard Self.isRegularFile(descriptor) else {
            close()
            throw POSIXFileError.notRegularFile(url)
        }
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, maximumCount: Int) throws -> Int {
        while true {
            let result = systemRead(descriptor, buffer, maximumCount)
            if result >= 0 {
                return result
            }
            if errno != EINTR {
                throw POSIXFileError.readFailed(url, errno)
            }
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            try write(baseAddress, count: buffer.count)
        }
    }

    func write(_ buffer: UnsafeRawPointer, count: Int) throws {
        var writtenBytes = 0
        while writtenBytes < count {
            let result = systemWrite(
                descriptor,
                buffer.advanced(by: writtenBytes),
                count - writtenBytes
            )
            if result > 0 {
                writtenBytes += result
                let (newOffset, overflow) = offset.addingReportingOverflow(UInt64(result))
                guard !overflow else {
                    throw POSIXFileError.offsetOverflow(url)
                }
                offset = newOffset
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw POSIXFileError.writeFailed(url, errno)
            }
        }
    }

    func synchronize() throws {
        while systemSynchronize(descriptor) != 0 {
            if errno != EINTR {
                throw POSIXFileError.synchronizeFailed(url, errno)
            }
        }
    }

    func close() {
        guard descriptor >= 0 else {
            return
        }
        _ = systemClose(descriptor)
        descriptor = -1
    }

    deinit {
        close()
    }

    private static func open(path: String, access: POSIXFileAccess) -> Int32 {
        #if canImport(Darwin)
        switch access {
        case let .appendCreate(usesPrivatePermissions):
            let permissions: mode_t = usesPrivatePermissions ? mode_t(S_IRUSR | S_IWUSR) : mode_t(0o666)
            return Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, permissions)
        case .read:
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        case let .exclusiveCreate(usesPrivatePermissions):
            let permissions: mode_t = usesPrivatePermissions ? mode_t(S_IRUSR | S_IWUSR) : mode_t(0o666)
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        }
        #elseif canImport(Glibc)
        switch access {
        case let .appendCreate(usesPrivatePermissions):
            let permissions: mode_t = usesPrivatePermissions ? mode_t(S_IRUSR | S_IWUSR) : mode_t(0o666)
            return Glibc.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, permissions)
        case .read:
            return Glibc.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        case let .exclusiveCreate(usesPrivatePermissions):
            let permissions: mode_t = usesPrivatePermissions ? mode_t(S_IRUSR | S_IWUSR) : mode_t(0o666)
            return Glibc.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        }
        #else
        return -1
        #endif
    }

    private static func isRegularFile(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
        var info = Darwin.stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG
        #elseif canImport(Glibc)
        var info = Glibc.stat()
        guard Glibc.fstat(descriptor, &info) == 0 else {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG
        #else
        return false
        #endif
    }
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
    #else
    -1
    #endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
    #else
    -1
    #endif
}

private func systemSynchronize(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.fsync(descriptor)
    #elseif canImport(Glibc)
    Glibc.fsync(descriptor)
    #else
    -1
    #endif
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #elseif canImport(Glibc)
    Glibc.close(descriptor)
    #else
    -1
    #endif
}
