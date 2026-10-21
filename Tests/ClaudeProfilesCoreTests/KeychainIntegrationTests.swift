import Security
import XCTest
@testable import ClaudeProfilesCore

/// Talks to the real login Keychain under a throwaway service name that no
/// profile uses. Every item the test creates is deleted in tearDown, also when
/// an assertion fails. The test skips when the Keychain is not available.
final class KeychainIntegrationTests: XCTestCase {
    private var service = ""
    private var store: KeychainStore!
    private var accounts: [String] = []

    override func setUpWithError() throws {
        service = "claude-profiles-test-\(UUID().uuidString)"
        XCTAssertNotEqual(service, KeychainStore.service)
        store = KeychainStore(service: service)
        accounts = []
    }

    override func tearDown() {
        for account in accounts {
            try? store?.delete(account)
        }
        store = nil
        accounts = []
    }

    /// Skips the test when the login Keychain refuses a new item (for example
    /// no unlocked keychain). The probe uses the attributes `KeychainStore.set` uses.
    private func requireKeychain() throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
        ]
        var add = item
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw XCTSkip("The login Keychain is not available to this test (OSStatus \(status)).")
        }
        SecItemDelete(item as CFDictionary)
    }

    /// Registers an account so that tearDown removes it.
    private func account(_ name: String) -> String {
        accounts.append(name)
        return name
    }

    func testSetGetUpdateDeleteRoundTrip() throws {
        try requireKeychain()
        let name = account("round-trip")
        XCTAssertNil(try store.get(name))
        XCTAssertFalse(try store.hasKey(name))

        try store.set(name, key: "first-secret")
        XCTAssertEqual(try store.get(name), "first-secret")
        XCTAssertTrue(try store.hasKey(name))

        // An update replaces the value instead of adding a second item.
        try store.set(name, key: "second-secret")
        XCTAssertEqual(try store.get(name), "second-secret")

        try store.delete(name)
        XCTAssertNil(try store.get(name))
        XCTAssertFalse(try store.hasKey(name))
    }

    func testDeletingAMissingItemIsNotAnError() throws {
        try requireKeychain()
        XCTAssertNoThrow(try store.delete(account("never-stored")))
    }

    func testTheServiceNameSeparatesItems() throws {
        try requireKeychain()
        let name = account("isolated")
        try store.set(name, key: "value")
        let other = KeychainStore(service: service + "-other")
        XCTAssertNil(try other.get(name))
        XCTAssertFalse(try other.hasKey(name))
    }
}
