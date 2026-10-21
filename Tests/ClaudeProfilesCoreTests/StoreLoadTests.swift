import XCTest
@testable import ClaudeProfilesCore

/// Reading `profiles.json`: strict decoding, the backup of a broken file, and
/// the guard that keeps an automatic save from overwriting a file that could
/// not be read.
final class StoreLoadTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var keys: InMemoryKeyStore!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        keys = InMemoryKeyStore()
        store = Store(paths: paths, keys: keys)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // A file made unreadable by a test must be readable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: paths.dataFile.path)
        temp = nil
        paths = nil
        keys = nil
        store = nil
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: paths.dataFile)
    }

    private func read() throws -> String {
        try String(contentsOf: paths.dataFile, encoding: .utf8)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasPrefix("profiles.json.corrupt-") }
    }

    /// One good profile and one whose `isolate` is text instead of a boolean.
    private let partlyMalformed = """
    {
      "terminal": "Terminal",
      "profiles": [
        { "name": "Good", "slug": "good", "base_url": "https://example.com", "auth": "Bearer" },
        { "name": "Bad", "slug": "bad", "isolate": "yes" }
      ],
      "auto_check_updates": true
    }
    """

    // MARK: - Strict decoding

    func testPartlyMalformedFileIsBackedUpWithAWarning() throws {
        try write(partlyMalformed)

        let loaded = store.load()

        guard case .corruptFileBackedUp(let path)? = loaded.warning else {
            return XCTFail("expected a backup warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), partlyMalformed)
        // The good profile is not shown either: the file is treated as unreadable as a whole.
        XCTAssertTrue(loaded.data.profiles.isEmpty)
        XCTAssertTrue(store.loadFailed)
    }

    func testAnAutomaticSettingsSaveDoesNotOverwriteThePartlyMalformedFile() throws {
        try write(partlyMalformed)
        var loaded = store.load()
        loaded.data.autoCheckUpdates = false

        XCTAssertThrowsError(try store.save(loaded.data)) { error in
            XCTAssertEqual(error as? StoreError, .dataFileNotLoaded(paths.dataFile.path))
        }
        XCTAssertEqual(try read(), partlyMalformed)
    }

    /// An explicit profile save is the user's own decision, so it clears the state.
    func testAnExplicitProfileSaveClearsTheFailedLoad() throws {
        try write(partlyMalformed)
        _ = store.load()
        XCTAssertTrue(store.loadFailed)

        let profile = Profile.sample(name: "New", slug: "new")
        try store.saveProfile(profile, others: [], key: "the-key")
        XCTAssertTrue(store.loadFailed, "the failed state ends only when profiles.json is written")

        try store.save(AppData(profiles: [profile]))
        XCTAssertFalse(store.loadFailed)
        let reloaded = store.load()
        XCTAssertNil(reloaded.warning)
        XCTAssertEqual(reloaded.data.profiles, [profile])
    }

    /// The explicit save succeeded, but profiles.json cannot be written: the file
    /// is still unreadable, so the failed state, the warning and the refusal of
    /// automatic saves all stay.
    func testAFailedWriteAfterARecoveringProfileSaveKeepsTheLoadFailure() throws {
        try write(partlyMalformed)
        _ = store.load()
        try FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.root.path) }
        if FileManager.default.isWritableFile(atPath: paths.root.path) {
            throw XCTSkip("file permissions are not enforced for this user")
        }

        // The launcher goes into bin/, which stays writable; no config folder is made.
        let profile = Profile.sample(name: "New", slug: "new", isolate: false)
        XCTAssertNoThrow(try store.saveProfile(profile, others: [], key: "the-key"))
        XCTAssertTrue(store.loadFailed)

        XCTAssertThrowsError(try store.save(AppData(profiles: [profile])))
        XCTAssertTrue(store.loadFailed, "a write that failed must not end the failed state")
        XCTAssertEqual(try read(), partlyMalformed)
    }

    func testAFailedSaveProfileKeepsTheLoadFailure() throws {
        try write(partlyMalformed)
        _ = store.load()
        // The profile has no key and no key is typed: the save fails, so the state stays.
        XCTAssertThrowsError(try store.saveProfile(Profile.sample(name: "New", slug: "new"), others: []))
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(try read(), partlyMalformed)
    }

    /// The settings survive a broken profile list and an explicit save of a profile.
    func testAFailedLoadKeepsTheSettingsThroughAnExplicitSave() throws {
        try write("""
        {
          "terminal": "ITerm",
          "profiles": [ { "name": "Bad", "slug": "bad", "isolate": "yes" } ],
          "language": "vi",
          "appearance": "dark",
          "auto_check_updates": false
        }
        """)
        var loaded = store.load()
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(loaded.data.profiles.isEmpty)
        XCTAssertEqual(loaded.data.language, .vi)
        XCTAssertEqual(loaded.data.appearance, .dark)
        XCTAssertEqual(loaded.data.terminal, .iTerm)
        XCTAssertFalse(loaded.data.autoCheckUpdates)

        let profile = Profile.sample(name: "New", slug: "new")
        try store.saveProfile(profile, others: [], key: "the-key")
        loaded.data.profiles.append(profile)
        try store.save(loaded.data)

        let reloaded = store.load()
        XCTAssertNil(reloaded.warning)
        XCTAssertEqual(reloaded.data.language, .vi)
        XCTAssertEqual(reloaded.data.appearance, .dark)
        XCTAssertEqual(reloaded.data.terminal, .iTerm)
        XCTAssertFalse(reloaded.data.autoCheckUpdates)
        XCTAssertEqual(reloaded.data.profiles, [profile])
        XCTAssertEqual(try backups().count, 1, "the copy of the original file is kept")
    }

    /// No copy of the unreadable file means no explicit save either: the list is never replaced.
    func testAnExplicitSaveIsRefusedWhenTheCopyCannotBeMade() throws {
        try write(partlyMalformed)
        let failing = Store(paths: paths, keys: keys, writeBackup: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let loaded = failing.load()
        guard case .dataUnreadable? = loaded.warning else {
            return XCTFail("expected an unreadable-file warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertTrue(failing.loadFailed)
        XCTAssertThrowsError(try failing.save(AppData())) { error in
            XCTAssertEqual(error as? StoreError, .dataFileUnreadable(self.paths.dataFile.path))
        }

        XCTAssertThrowsError(
            try failing.saveProfile(Profile.sample(name: "New", slug: "new"), others: [], key: "the-key")
        ) { error in
            XCTAssertEqual(error as? StoreError, .noBackup(self.paths.dataFile.path))
        }
        XCTAssertTrue(failing.loadFailed)
        XCTAssertEqual(try read(), partlyMalformed)
        XCTAssertNil(try keys.get("new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script(for: "new").path))
    }

    /// Reload: a file that is still broken stays failed without a second copy;
    /// a fixed file clears the failed state and the save works again.
    func testReloadStaysFailedWhileBrokenAndClearsWhenFixed() throws {
        try write("{ broken")
        let first = store.load()
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(try backups().count, 1)

        let second = store.load()
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(second.warning, first.warning)
        XCTAssertEqual(try backups().count, 1, "identical content is not copied twice")

        try write(#"{"terminal":"Terminal","profiles":[{"name":"Test","slug":"test"}]}"#)
        let third = store.load()
        XCTAssertNil(third.warning)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(third.data.profiles.map(\.slug), ["test"])
        XCTAssertNoThrow(try store.save(third.data))
    }

    /// The readability check changes nothing: a broken file gets no new copy and
    /// the failed state is not touched, and a valid file is reported as readable.
    func testIsReadableReportsTheFileWithoutChangingTheState() throws {
        try write(partlyMalformed)
        XCTAssertFalse(store.isReadable())
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(try backups().count, 0, "the check makes no copy")

        _ = store.load()
        XCTAssertFalse(store.isReadable())
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(try backups().count, 1)

        try write(#"{"terminal":"Terminal","profiles":[]}"#)
        XCTAssertTrue(store.isReadable())
        XCTAssertTrue(store.loadFailed, "the check does not clear the failed state")
    }

    func testTheValidRustFixtureStillLoads() throws {
        let fixture = try Fixtures.text("rust-profiles", extension: "json")
        try write(fixture)

        let loaded = store.load()

        XCTAssertNil(loaded.warning)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(loaded.data.profiles.count, 2)
        XCTAssertEqual(loaded.data.profiles[1].name, "Second \"quoted\" / ünïcode")
        XCTAssertEqual(try read(), fixture, "a valid file is never rewritten by a load")
    }

    func testUnknownKeysAreStillIgnored() throws {
        try write(#"{"terminal":"Terminal","future":{"x":[1,2]},"profiles":[{"name":"Test","slug":"test","future_key":true}]}"#)

        let loaded = store.load()

        XCTAssertNil(loaded.warning)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(loaded.data.profiles.map(\.slug), ["test"])
    }

    func testAMissingFileIsNotAFailure() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.dataFile.path))
        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertFalse(store.loadFailed)
        XCTAssertNoThrow(try store.save(AppData()))
    }

    // MARK: - Slugs from disk

    /// A hand-edited slug that is not a safe file name refuses the file.
    func testAnUnsafeSlugOnDiskIsRejectedWithABackup() throws {
        let text = #"{"profiles":[{"name":"Evil","slug":"../../x"}]}"#
        try write(text)

        let loaded = store.load()

        guard case .corruptFileBackedUp? = loaded.warning else {
            return XCTFail("expected a backup warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertTrue(loaded.data.profiles.isEmpty)
        XCTAssertTrue(store.loadFailed)
        XCTAssertEqual(try backups().count, 1)
        XCTAssertEqual(try read(), text)
    }

    // MARK: - Unreadable files

    func testNonUTF8FileIsBackedUpAsItIs() throws {
        let bytes = Data([0x7B, 0xFF, 0xFE, 0x7D])
        try bytes.write(to: paths.dataFile)

        let loaded = store.load()

        guard case .corruptFileBackedUp(let path)? = loaded.warning else {
            return XCTFail("expected a backup warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertTrue(store.loadFailed)
    }

    func testAnUnreadableFileIsReportedAndNeverOverwritten() throws {
        try write(partlyMalformed)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.dataFile.path)
        if (try? Data(contentsOf: paths.dataFile)) != nil {
            throw XCTSkip("file permissions are not enforced for this user")
        }

        let loaded = store.load()

        guard case .dataUnreadable(let path)? = loaded.warning else {
            return XCTFail("expected an unreadable-file warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertEqual(path, paths.dataFile.path)
        XCTAssertTrue(store.loadFailed)
        XCTAssertThrowsError(try store.save(AppData()))
    }

    // MARK: - Backups

    func testTwoDifferentBrokenFilesInOneSecondKeepBothBackups() throws {
        try write("{ one")
        let first = store.load()
        try write("{ two")
        let second = store.load()

        guard case .corruptFileBackedUp(let firstPath)? = first.warning,
              case .corruptFileBackedUp(let secondPath)? = second.warning else {
            return XCTFail("expected backup warnings")
        }
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: firstPath), encoding: .utf8), "{ one")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: secondPath), encoding: .utf8), "{ two")
    }

    /// The data file is written through a unique temporary name, never `profiles.json.tmp`.
    func testSaveLeavesNoTemporaryFileBehind() throws {
        try store.save(AppData(profiles: [Profile.sample()]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
