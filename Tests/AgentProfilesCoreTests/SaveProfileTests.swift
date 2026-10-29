import XCTest
@testable import AgentProfilesCore

/// Saving a profile: the checks come first, a rename moves everything and a
/// failure after the rename is rolled back.
final class SaveProfileTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var keys: InMemoryKeyStore!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        keys = InMemoryKeyStore()
        store = Store(paths: paths, keys: keys)
    }

    override func tearDown() {
        temp = nil
        paths = nil
        keys = nil
        store = nil
    }

    private func manager() -> FileManager { FileManager.default }

    /// A profile with a key, a launcher and a config folder.
    private func materialize(_ profile: Profile) throws {
        try keys.set(profile.slug, key: "the-key")
        try store.materialize(profile)
        let home = paths.home(for: profile.slug)
        try manager().createDirectory(at: home, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: home.appendingPathComponent("session.json"))
    }

    // MARK: - Duplicates

    /// A profile that already uses the command is an error that names it.
    func testADuplicateCommandNamesTheOtherProfile() {
        let other = Profile.sample(name: "MiniMax", slug: "minimax")
        let profile = Profile.sample(name: "MiniMax 2", slug: "minimax")
        XCTAssertThrowsError(try store.saveProfile(profile, others: [other])) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("minimax", "MiniMax"))
        }
    }

    /// Two names that slugify to the same value collide.
    func testTwoNamesWithTheSameSlugCollide() {
        let other = Profile.sample(name: "GLM", slug: "glm")
        let profile = Profile.sample(name: "glm ", slug: "glm")
        XCTAssertThrowsError(try store.saveProfile(profile, others: [other])) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("glm", "GLM"))
        }
    }

    /// A profile is never a duplicate of itself.
    func testEditingAProfileWithoutChangingItsSlugIsNoDuplicate() throws {
        let profile = Profile.sample(name: "Test", slug: "test")
        try keys.set(profile.slug, key: "the-key")
        XCTAssertNoThrow(try store.saveProfile(profile, others: [], previous: profile))
    }

    // MARK: - Foreign files

    /// A file in `bin/` that this app did not write is never overwritten.
    func testAForeignScriptIsRejectedAndLeftUntouched() throws {
        try manager().createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let foreign = paths.script(for: "taken")
        let content = "#!/bin/sh\necho mine\n"
        try Data(content.utf8).write(to: foreign)

        let profile = Profile.sample(name: "Taken", slug: "taken")
        XCTAssertThrowsError(try store.saveProfile(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .foreignCommandExists("taken", foreign.path))
        }
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), content)
    }

    /// The launcher of the profile itself belongs to the app.
    func testTheOwnMarkedScriptIsAccepted() throws {
        let profile = Profile.sample()
        try materialize(profile)
        XCTAssertNoThrow(try store.saveProfile(profile, others: [], previous: profile))
    }

    /// A launcher of this app that no profile uses anymore is not foreign.
    func testAMarkedScriptOfAnotherProfileIsAccepted() throws {
        let other = Profile.sample(slug: "test")
        try store.materialize(other)

        let profile = Profile.sample(name: "Test", slug: "test")
        try keys.set(profile.slug, key: "the-key")
        XCTAssertNoThrow(try store.saveProfile(profile, others: []))
    }

    // MARK: - Renaming

    /// A rename moves the key, the launcher and the config folder.
    func testARenameMovesKeyScriptAndHome() throws {
        let profile = Profile.sample(slug: "old")
        try materialize(profile)

        let renamed = Profile.sample(name: "New", slug: "new")
        let result = try store.saveProfile(renamed, others: [], previous: profile)

        XCTAssertEqual(result.renamedFrom, "old")
        XCTAssertEqual(result.slug, "new")
        XCTAssertEqual(try keys.get("new"), "the-key")
        XCTAssertNil(try keys.get("old"))
        XCTAssertFalse(manager().fileExists(atPath: paths.script(for: "old").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "new").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: "old").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "new").path))
        XCTAssertTrue(manager().fileExists(
            atPath: paths.home(for: "new").appendingPathComponent("session.json").path
        ))
    }

    /// A rename to a command another profile uses changes nothing at all.
    func testARenameWithADuplicateTargetChangesNothing() throws {
        let profile = Profile.sample(slug: "old")
        try materialize(profile)

        let renamed = Profile.sample(name: "New", slug: "new")
        let other = Profile.sample(name: "Other", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [other], previous: profile)) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("new", "Other"))
        }

        XCTAssertEqual(try keys.get("old"), "the-key")
        XCTAssertNil(try keys.get("new"))
        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.script(for: "new").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: "new").path))
    }

    /// A rename to a command a foreign file uses changes nothing at all.
    func testARenameToAForeignFileChangesNothing() throws {
        let profile = Profile.sample(slug: "old")
        try materialize(profile)

        try manager().createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let foreign = paths.script(for: "new")
        try Data("#!/bin/sh\necho mine\n".utf8).write(to: foreign)

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: profile)) { error in
            XCTAssertEqual(error as? ProfileError, .foreignCommandExists("new", foreign.path))
        }

        XCTAssertEqual(try keys.get("old"), "the-key")
        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "old").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "old").path))
    }

    /// A rename without a key that is neither typed nor stored is refused
    /// before anything moves: no key, launcher or folder changes.
    func testARenameWithoutAKeyChangesNothingBeforehand() throws {
        let profile = Profile.sample(slug: "old")
        try store.materialize(profile)
        let home = paths.home(for: "old")
        try manager().createDirectory(at: home, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: home.appendingPathComponent("session.json"))

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: profile)) { error in
            XCTAssertEqual(error as? ProfileError, .missingAPIKey)
        }

        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.script(for: "new").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: "new").path))
        XCTAssertNil(try keys.get("new"))
    }

    /// When a step after the rename fails, the rename is rolled back.
    func testAFailedSaveRollsTheRenameBack() throws {
        // No key in the store: the save fails after the rename.
        let profile = Profile.sample(slug: "old")
        try store.materialize(profile)
        let home = paths.home(for: "old")
        try manager().createDirectory(at: home, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: home.appendingPathComponent("session.json"))

        let renamed = Profile.sample(name: "New", slug: "new")
        XCTAssertThrowsError(try store.saveProfile(renamed, others: [], previous: profile)) { error in
            XCTAssertEqual(error as? ProfileError, .missingAPIKey)
        }

        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.script(for: "new").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "old").path))
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: "new").path))
        XCTAssertTrue(manager().fileExists(
            atPath: paths.home(for: "old").appendingPathComponent("session.json").path
        ))
    }
}
