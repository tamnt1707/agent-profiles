import XCTest
@testable import ClaudeProfilesCore

/// The Keychain itself is never touched by the tests: they use the in-memory
/// store that has the same contract as `KeychainStore`.
final class KeyStoreTests: XCTestCase {
    func testMissingKeyIsNotAnError() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try store.get("nope"))
        XCTAssertNoThrow(try store.delete("nope"))
    }

    func testSetReplacesTheKeyInsteadOfAddingADuplicate() throws {
        let store = InMemoryKeyStore()
        try store.set("slug", key: "first")
        try store.set("slug", key: "second")
        XCTAssertEqual(try store.get("slug"), "second")
        XCTAssertEqual(store.accounts, ["slug"])
    }

    func testDeleteRemovesTheKey() throws {
        let store = InMemoryKeyStore()
        try store.set("slug", key: "secret")
        try store.delete("slug")
        XCTAssertNil(try store.get("slug"))
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testAccountsAreIndependent() throws {
        let store = InMemoryKeyStore()
        try store.set("one", key: "a")
        try store.set("two", key: "b")
        XCTAssertEqual(try store.get("one"), "a")
        XCTAssertEqual(try store.get("two"), "b")
        try store.delete("one")
        XCTAssertNil(try store.get("one"))
        XCTAssertEqual(try store.get("two"), "b")
    }

    func testTheKeychainServiceIsTheOneOfTheOldApp() {
        XCTAssertEqual(KeychainStore.service, "claude-profiles")
        XCTAssertEqual(ScriptRenderer.keychainService, "claude-profiles")
    }
}
