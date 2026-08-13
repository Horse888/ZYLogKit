import Foundation

public enum LogFileProtection: Sendable {
    case systemDefault
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
}

extension LogFileProtection {
    var fileAttributes: [FileAttributeKey: Any]? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let protection: FileProtectionType
        switch self {
        case .systemDefault:
            return nil
        case .complete:
            protection = .complete
        case .completeUnlessOpen:
            protection = .completeUnlessOpen
        case .completeUntilFirstUserAuthentication:
            protection = .completeUntilFirstUserAuthentication
        }
        return [.protectionKey: protection]
        #else
        return nil
        #endif
    }

    func apply(
        to url: URL,
        isDirectory: Bool? = nil,
        usesPrivateFilePermissions: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        var attributes = fileAttributes ?? [:]
        if usesPrivateFilePermissions {
            let directory: Bool
            if let isDirectory {
                directory = isDirectory
            } else {
                directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            }
            attributes[.posixPermissions] = NSNumber(value: directory ? 0o700 : 0o600)
        }
        if !attributes.isEmpty {
            try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        }
    }
}
