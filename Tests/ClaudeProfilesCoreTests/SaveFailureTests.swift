import XCTest
@testable import ClaudeProfilesCore

/// A key store whose writes and deletes can be made to fail. It logs every write,
/// so a test can check which secret was written where.
final class FlakyKeyStore: KeyStore, @unchecked Sendable {
    let inner = InMemoryKeyStore()
    var failingWrites: Set<String> = []
    var failingDeletes: Set<String> = []
    private(set) var writes: [(account: String, key: String)] = []

    func get(_ account: String) throws -> String? {
        try inner.get(account)
    }

    func hasKey(_ account: String) throws -> Bool {
        try inner.hasKey(account)
    }

    func set(_ account: String, key: String) throws {
        writes.append((account, key))
        if failingWrites.contains(account) { throw ProfileError.keychainWriteFailed }
        try inner.set(account, key: key)
    }

    func delete(_ account: String) throws {
        if failingDeletes.contains(account) { throw ProfileError.keychainDeleteFailed }
        try inner.delete(account)
    }
}

/// Saving a profile when a step fails: the Keychain and the files must end up
/// as they were, and a typed secret must never land on the wrong account.
final class SaveFailureTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var keys: FlakyKeyStore!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        keys = FlakyKeyStore()
        store = Store(paths: paths, keys: keys)
    }

    override func tearDown() {
        // A read-only folder must be writable again so the temporary folder can be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.binDir.path)
        temp = nil
        paths = nil
        keys = nil
        store = nil
    }

    private var manager: FileManager { FileManager.default }

    private func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    /// Makes every write into `bin/` fail, so the launcher cannot be written.
    private func makeBinReadOnly() throws {
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.binDir.path)
        if manager.isWritableFile(atPath: paths.binDir.path) {
            throw XCTSkip("file permissions are not enforced for this user")
        }
    }

    private func wroteSecret(_ secret: String) -> Bool {
        keys.writes.contains { $0.key == secret }
    }

    // MARK: - Without a rename

    /// A failed launcher write keeps the key that was stored before.
    func testAFailedMaterializeKeepsTheStoredKey() throws {
        let profile = Profile.sample(name: "Same", slug: "same")
        try keys.set("same", key: "stored-key")
        try store.materialize(profile)
        try makeBinReadOnly()

        XCTAssertThrowsError(try store.saveProfile(profile, others: [], previous: profile, key: "typed-key"))

        XCTAssertEqual(try keys.get("same"), "stored-key")
        XCTAssertFalse(wroteSecret("typed-key"), "the typed key must not be written when the save fails")
    }

    /// A failed save of a new profile leaves no key behind.
    func testAFailedMaterializeStoresNoNewKey() throws {
        try makeBinReadOnly()

        XCTAssertThrowsError(try store.saveProfile(Profile.sample(name: "Fresh", slug: "fresh"), others: [], key: "typed-key"))

        XCTAssertNil(try keys.get("fresh"))
        XCTAssertFalse(wroteSecret("typed-key"))
    }

    func testASuccessfulSaveStoresTheTypedKey() throws {
        let profile = Profile.sample(name: "Fresh", slug: "fresh")
        try store.saveProfile(profile, others: [], key: "typed-key")
        XCTAssertEqual(try keys.get("fresh"), "typed-key")
    }

    // MARK: - With a rename

    /// The new key is typed, the launcher fails: the rollback moves the OLD key
    /// back to the old account and never writes the typed one anywhere.
    func testARenameWithANewKeyAndAFailedMaterializeKeepsTheOldAccountKey() throws {
        let old = Profile.sample(name: "Old", slug: "old")
        try keys.set("old", key: "old-key")
        try store.materialize(old)
        try manager.createDirectory(at: paths.home(for: "old"), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: paths.home(for: "old").appendingPathComponent("session.json"))
        try makeBinReadOnly()

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: old, key: "typed-key"))

        XCTAssertEqual(try keys.get("old"), "old-key")
        XCTAssertNil(try keys.get("new"))
        XCTAssertFalse(wroteSecret("typed-key"))
        XCTAssertTrue(exists(paths.home(for: "old").appendingPathComponent("session.json")))
        XCTAssertFalse(exists(paths.home(for: "new")))
    }

    /// A rename into a folder that already exists is refused before anything
    /// changes: neither key nor folder moves, and the stale folder stays as it was.
    func testARenameOntoAStaleFolderChangesNothing() throws {
        let old = Profile.sample(name: "Old", slug: "old")
        try keys.set("old", key: "old-key")
        try store.materialize(old)
        try manager.createDirectory(at: paths.home(for: "old"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: paths.home(for: "old").appendingPathComponent("session.json"))
        try manager.createDirectory(at: paths.home(for: "new"), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: paths.home(for: "new").appendingPathComponent("stale.json"))

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: old, key: "typed-key")) { error in
            XCTAssertEqual(error as? StoreError, .targetHomeExists(self.paths.home(for: "new").path))
        }

        XCTAssertEqual(try keys.get("old"), "old-key")
        XCTAssertNil(try keys.get("new"))
        XCTAssertTrue(exists(paths.home(for: "old").appendingPathComponent("session.json")))
        XCTAssertTrue(exists(paths.home(for: "new").appendingPathComponent("stale.json")))
        XCTAssertFalse(exists(paths.home(for: "new").appendingPathComponent("session.json")))
    }

    /// A failing Keychain write during a rename is undone: the key is back on the old account.
    func testAFailedKeyWriteDuringARenameIsUndone() throws {
        let old = Profile.sample(name: "Old", slug: "old")
        try keys.set("old", key: "old-key")
        try store.materialize(old)
        keys.failingWrites = ["new"]

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: old))

        XCTAssertEqual(try keys.get("old"), "old-key")
        XCTAssertNil(try keys.get("new"))
    }

    // MARK: - Auth None

    /// `auth none` never uses a credential: the stored key goes, a typed one is not stored.
    func testAuthNoneDeletesTheOldKeyAndNeverStoresATypedSecret() throws {
        let profile = Profile.sample(name: "Local", slug: "local", auth: .none)
        try keys.set("local", key: "old-key")

        try store.saveProfile(profile, others: [], previous: profile, key: "typed-key")

        XCTAssertFalse(try keys.hasKey("local"))
        XCTAssertFalse(wroteSecret("typed-key"))
    }

    // MARK: - Unsafe slugs

    /// A slug that is not a safe file name is refused before any key or file changes.
    func testAnUnsafeSlugChangesNothing() throws {
        let evil = Profile.sample(name: "Evil", slug: "../../x")

        XCTAssertThrowsError(try store.saveProfile(evil, others: [], key: "typed-key")) { error in
            XCTAssertEqual(error as? StoreError, .unsafeSlug("../../x"))
        }

        XCTAssertTrue(keys.writes.isEmpty)
        XCTAssertFalse(exists(paths.root.deletingLastPathComponent().appendingPathComponent("x")))
    }

    func testAMigrationWithAnUnsafeSlugIsRefused() throws {
        try keys.set("old", key: "old-key")
        XCTAssertThrowsError(try store.migrateSlug(from: "old", to: "../x"))
        XCTAssertEqual(try keys.get("old"), "old-key")
        // Only the setup write above was made: the refused migration wrote nothing.
        XCTAssertEqual(keys.writes.map(\.account), ["old"])
    }
}
