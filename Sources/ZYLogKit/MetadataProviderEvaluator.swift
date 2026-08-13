import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum MetadataProviderEvaluator {
    static func evaluate(_ provider: () -> [String: String]) -> [String: String] {
        guard threadLocalKey.isValid else {
            return evaluateUsingThreadDictionary(provider)
        }

        guard pthread_getspecific(threadLocalKey.value) == nil else {
            return [:]
        }

        let activeMarker = UnsafeMutableRawPointer(bitPattern: 1)
        guard pthread_setspecific(threadLocalKey.value, activeMarker) == 0 else {
            return evaluateUsingThreadDictionary(provider)
        }
        defer {
            _ = pthread_setspecific(threadLocalKey.value, nil)
        }
        return provider()
    }

    private static func evaluateUsingThreadDictionary(
        _ provider: () -> [String: String]
    ) -> [String: String] {
        let threadDictionary = Thread.current.threadDictionary
        guard threadDictionary[reentrancyKey] == nil else {
            return [:]
        }

        threadDictionary[reentrancyKey] = true
        defer {
            threadDictionary.removeObject(forKey: reentrancyKey)
        }
        return provider()
    }

    private static let threadLocalKey: (value: pthread_key_t, isValid: Bool) = {
        var key = pthread_key_t()
        let status = pthread_key_create(&key, nil)
        return (key, status == 0)
    }()

    private static let reentrancyKey = "com.zylogkit.metadata-provider.active"
}
