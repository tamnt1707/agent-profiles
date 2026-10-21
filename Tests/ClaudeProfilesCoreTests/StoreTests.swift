import XCTest
@testable import ClaudeProfilesCore

final class StoreTests: XCTestCase {
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

    // MARK: - Data file

    func testLoadWithoutFileReturnsEmptyData() {
        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertTrue(loaded.data.profiles.isEmpty)
        XCTAssertEqual(loaded.data.terminal, .terminal)
        XCTAssertEqual(loaded.data.language, .system)
        XCTAssertEqual(loaded.data.appearance, .system)
    }

    func testSaveAndLoadRoundTrip() throws {
        var data = AppData()
        data.terminal = .iTerm
        data.language = .vi
        data.appearance = .dark
        data.profiles = [Profile.sample()]
        try store.save(data)

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data, data)
    }

    func testSaveIsAtomic() throws {
        try store.save(AppData(profiles: [Profile.sample()]))
        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: paths.dataFile.path))
        XCTAssertFalse(manager.fileExists(atPath: paths.root.appendingPathComponent("profiles.json.tmp").path))
    }

    func testCorruptFileIsBackedUpAndNotOverwritten() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let garbage = "{ this is not json"
        try Data(garbage.utf8).write(to: paths.dataFile)

        let loaded = store.load()
        guard case .corruptFileBackedUp(let path)? = loaded.warning else {
            return XCTFail("expected a corruption warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertTrue(manager.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".json.corrupt-\(Int(Date().timeIntervalSince1970))") || path.contains(".json.corrupt-"))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), garbage)
        // The broken file itself is still there, nothing was thrown away silently.
        XCTAssertEqual(try String(contentsOf: paths.dataFile, encoding: .utf8), garbage)
    }

    func testCorruptFileIsBackedUpOnlyOnce() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let garbage = "{ broken"
        try Data(garbage.utf8).write(to: paths.dataFile)

        let first = store.load()
        let second = store.load()
        guard case .corruptFileBackedUp(let firstPath)? = first.warning,
              case .corruptFileBackedUp(let secondPath)? = second.warning else {
            return XCTFail("expected corruption warnings")
        }
        XCTAssertEqual(firstPath, secondPath)
        let backups = try manager.contentsOfDirectory(atPath: paths.root.path)
            .filter { $0.hasPrefix("profiles.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - Materialize

    func testMaterializeWritesAnExecutableScriptWithoutTheSecret() throws {
        let profile = Profile.sample()
        try keys.set(profile.slug, key: "super-secret-key")
        try store.materialize(profile)

        let scriptURL = paths.script(for: profile.slug)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o755)

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertFalse(script.contains("super-secret-key"))
        XCTAssertTrue(script.contains("exec claude \"$@\""))
    }

    func testMaterializeCreatesTheIsolatedHome() throws {
        let profile = Profile.sample()
        try store.materialize(profile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.home(for: profile.slug).path))
    }

    func testMaterializeWithoutIsolationCreatesNoHome() throws {
        var profile = Profile.sample()
        profile.isolate = false
        try store.materialize(profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home(for: profile.slug).path))
    }

    func testSharedItemsAreSymlinkedOnlyWhenTheSourceExists() throws {
        let manager = FileManager.default
        let claudeDir = paths.defaultClaudeDir
        try manager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: claudeDir.appendingPathComponent("CLAUDE.md"))
        try manager.createDirectory(at: claudeDir.appendingPathComponent("skills"), withIntermediateDirectories: true)
        // "commands" deliberately does not exist.

        var profile = Profile.sample()
        profile.isolate = true
        profile.shareFromDefault = true
        try store.materialize(profile)

        let home = paths.home(for: profile.slug)
        let link = home.appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link.path),
                       claudeDir.appendingPathComponent("CLAUDE.md").path)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: home.appendingPathComponent("skills").path),
                       claudeDir.appendingPathComponent("skills").path)
        XCTAssertFalse(manager.fileExists(atPath: home.appendingPathComponent("commands").path))
        XCTAssertFalse(manager.fileExists(atPath: home.appendingPathComponent("agents").path))
    }

    func testExistingDestinationIsNotReplaced() throws {
        let manager = FileManager.default
        let claudeDir = paths.defaultClaudeDir
        try manager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("shared".utf8).write(to: claudeDir.appendingPathComponent("CLAUDE.md"))

        var profile = Profile.sample()
        profile.shareFromDefault = true

        // The profile already owns a CLAUDE.md of its own.
        try manager.createDirectory(at: paths.home(for: profile.slug), withIntermediateDirectories: true)
        let own = paths.home(for: profile.slug).appendingPathComponent("CLAUDE.md")
        try Data("mine".utf8).write(to: own)

        try store.materialize(profile)

        XCTAssertEqual(try String(contentsOf: own, encoding: .utf8), "mine")
        XCTAssertNil(try? manager.destinationOfSymbolicLink(atPath: own.path))
    }

    // MARK: - Migration and removal

    func testMigrateSlugMovesKeyScriptAndHome() throws {
        let old = Profile.sample(slug: "old")
        try keys.set(old.slug, key: "the-key")
        try store.materialize(old)
        try manager().createDirectory(at: paths.home(for: old.slug), withIntermediateDirectories: true)
        try Data("history".utf8).write(to: paths.home(for: old.slug).appendingPathComponent("session.json"))

        try store.migrateSlug(from: "old", to: "new")

        XCTAssertEqual(try keys.get("new"), "the-key")
        XCTAssertNil(try keys.get("old"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script(for: "old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.home(for: "new").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.home(for: "old").path))
    }

    func testMigrateSlugKeepsAnExistingNewHome() throws {
        let manager = FileManager()
        try manager.createDirectory(at: paths.home(for: "old"), withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.home(for: "new"), withIntermediateDirectories: true)
        try store.migrateSlug(from: "old", to: "new")
        XCTAssertTrue(manager.fileExists(atPath: paths.home(for: "old").path))
        XCTAssertTrue(manager.fileExists(atPath: paths.home(for: "new").path))
    }

    func testRemoveDeletesScriptAndKeyButKeepsTheHome() throws {
        let profile = Profile.sample()
        try keys.set(profile.slug, key: "the-key")
        try store.materialize(profile)
        let manager = FileManager.default
        try manager.createDirectory(at: paths.home(for: profile.slug), withIntermediateDirectories: true)

        try store.remove(profile)

        XCTAssertFalse(manager.fileExists(atPath: paths.script(for: profile.slug).path))
        XCTAssertNil(try keys.get(profile.slug))
        XCTAssertTrue(manager.fileExists(atPath: paths.home(for: profile.slug).path))
    }

    private func manager() -> FileManager { FileManager.default }
}
