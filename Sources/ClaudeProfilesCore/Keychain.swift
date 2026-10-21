import Foundation
import Security

/// Somewhere to keep the API keys. The real implementation is the macOS
/// Keychain; the tests use an in-memory store.
public protocol KeyStore: AnyObject {
    /// Returns the stored key, or `nil` when there is none.
    func get(_ account: String) throws -> String?
    /// Stores the key, replacing an existing one (never creates duplicates).
    func set(_ account: String, key: String) throws
    /// Removes the key. Removing a key that does not exist is not an error.
    func delete(_ account: String) throws
}

/// The macOS Keychain. Service `claude-profiles`, account = profile slug.
public final class KeychainStore: KeyStore {
    /// Service name shared by every profile.
    public static let service = "claude-profiles"

    private let service: String

    public init(service: String = KeychainStore.service) {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func get(_ account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw ProfileError.keychainReadFailed
        }
    }

    public func set(_ account: String, key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(
            query(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ProfileError.keychainWriteFailed }

        var addQuery = query(for: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ProfileError.keychainWriteFailed }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw ProfileError.keychainDeleteFailed
    }
}

/// Key store that only lives in memory. Used by the tests, never by the app.
public final class InMemoryKeyStore: KeyStore {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ account: String) throws -> String? {
        lock.withLock { storage[account] }
    }

    public func set(_ account: String, key: String) throws {
        lock.withLock { storage[account] = key }
    }

    public func delete(_ account: String) throws {
        lock.withLock { _ = storage.removeValue(forKey: account) }
    }

    /// The accounts that currently hold a key.
    public var accounts: [String] {
        lock.withLock { Array(storage.keys) }
    }
}
