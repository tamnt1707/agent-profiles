import XCTest
@testable import AgentProfilesCore

/// Deleting a profile leaves nothing behind: the key, the launcher and the
/// whole config folder go away. The links inside the folder are taken with it,
/// but what they point to stays untouched.
final class RemovalTests: XCTestCase {
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

    /// A profile with a key, a launcher and a config folder with a file.
    private func materialize(_ profile: Profile) throws {
        try keys.set(profile.slug, key: "the-key")
        try store.materialize(profile)
        let home = paths.home(for: profile.slug)
        try manager().createDirectory(at: home, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: home.appendingPathComponent("session.json"))
    }

    /// Everything below a folder: the paths and the content of every file.
    private func snapshot(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return out }
        var stack = [url]
        while let current = stack.popLast() {
            for child in try manager.contentsOfDirectory(atPath: current.path) {
                let childURL = current.appendingPathComponent(child)
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: childURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    out[childURL.path] = "<folder>"
                    stack.append(childURL)
                } else {
                    out[childURL.path] = (try? String(contentsOf: childURL, encoding: .utf8)) ?? "<binary>"
                }
            }
        }
        return out
    }

    // MARK: - The happy path

    /// Everything of the profile is gone afterwards.
    func testRemoveDeletesTheScriptTheKeyAndTheHome() throws {
        let profile = Profile.sample()
        try materialize(profile)

        let report = try store.remove(profile)

        XCTAssertTrue(report.removedKey)
        XCTAssertTrue(report.removedScript)
        XCTAssertTrue(report.removedHome)
        XCTAssertEqual(report.failures, [])
        XCTAssertNil(try keys.get(profile.slug))
        XCTAssertFalse(manager().fileExists(atPath: paths.script(for: profile.slug).path))
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: profile.slug).path))
    }

    /// A Claude Code that still runs for the profile writes into the folder while
    /// it is emptied: the removal is repeated until the folder is gone.
    func testRemoveCatchesFilesWrittenWhileTheFolderIsEmptied() throws {
        let profile = Profile.sample()
        try materialize(profile)
        let home = paths.home(for: profile.slug)

        let writer = Thread {
            let end = Date().addingTimeInterval(0.25)
            var n = 0
            while Date() < end {
                try? Data("late".utf8).write(to: home.appendingPathComponent("late-\(n).json"))
                n += 1
                usleep(2_000)
            }
        }
        writer.start()
        let report = try store.remove(profile)

        XCTAssertTrue(report.removedHome)
        XCTAssertEqual(report.failures, [])
        XCTAssertFalse(manager().fileExists(atPath: home.path))
    }

    /// The folder of a profile goes away even when it is not isolated.
    func testRemoveDeletesTheHomeOfAProfileWithoutIsolation() throws {
        var profile = Profile.sample()
        profile.isolate = false
        try keys.set(profile.slug, key: "the-key")
        try store.materialize(profile)
        try manager().createDirectory(at: paths.home(for: profile.slug), withIntermediateDirectories: true)

        let report = try store.remove(profile)

        XCTAssertTrue(report.removedHome)
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: profile.slug).path))
    }

    /// A profile without a config folder can be deleted as well.
    func testRemoveSucceedsWithoutAHome() throws {
        let profile = Profile.sample()
        try keys.set(profile.slug, key: "the-key")
        try store.materialize(profile)

        let report = try store.remove(profile)

        XCTAssertTrue(report.removedKey)
        XCTAssertTrue(report.removedScript)
        XCTAssertTrue(report.removedHome)
        XCTAssertEqual(report.failures, [])
    }

    /// The other profiles stay as they are.
    func testRemoveLeavesOtherProfilesUntouched() throws {
        let first = Profile.sample(name: "First", slug: "first")
        let second = Profile.sample(name: "Second", slug: "second")
        try materialize(first)
        try materialize(second)

        _ = try store.remove(first)

        XCTAssertEqual(try keys.get("second"), "the-key")
        XCTAssertTrue(manager().fileExists(atPath: paths.script(for: "second").path))
        XCTAssertTrue(manager().fileExists(atPath: paths.home(for: "second").path))
    }

    // MARK: - Symlinks

    /// The links into `~/.claude` are taken with the folder, but the files
    /// behind them stay untouched.
    func testRemoveLeavesTheSymlinkTargetsIntact() throws {
        let manager = FileManager.default
        let claudeDir = paths.defaultClaudeDir
        try manager.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: claudeDir.appendingPathComponent("CLAUDE.md"))
        try manager.createDirectory(at: claudeDir.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: claudeDir.appendingPathComponent("skills/one.md"))

        var profile = Profile.sample()
        profile.isolate = true
        profile.shareFromDefault = true
        try materialize(profile)

        let link = paths.home(for: profile.slug).appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link.path),
                       claudeDir.appendingPathComponent("CLAUDE.md").path)

        let before = try snapshot(claudeDir)
        _ = try store.remove(profile)
        let after = try snapshot(claudeDir)

        XCTAssertEqual(before, after, "the shared configuration was changed")
        XCTAssertEqual(after[claudeDir.appendingPathComponent("CLAUDE.md").path], "notes")
        XCTAssertEqual(after[claudeDir.appendingPathComponent("skills/one.md").path], "skill")
        XCTAssertFalse(manager.fileExists(atPath: paths.home(for: profile.slug).path))
    }

    /// A config folder that is a link is only unlinked, never followed.
    func testRemoveTakesOnlyTheLinkWhenTheHomeIsALink() throws {
        let target = temp.url.appendingPathComponent("outside", isDirectory: true)
        try manager().createDirectory(at: target, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: target.appendingPathComponent("file.txt"))

        try manager().createDirectory(at: paths.homesDir, withIntermediateDirectories: true)
        try manager().createSymbolicLink(at: paths.home(for: "linked"), withDestinationURL: target)

        let profile = Profile.sample(slug: "linked")
        let report = try store.remove(profile)

        XCTAssertTrue(report.removedHome)
        XCTAssertFalse(manager().fileExists(atPath: paths.home(for: "linked").path))
        XCTAssertTrue(manager().fileExists(atPath: target.appendingPathComponent("file.txt").path))
    }

    // MARK: - Foreign files

    /// A launcher of another program is never deleted.
    func testRemoveDoesNotDeleteAForeignScript() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let foreign = paths.script(for: "test")
        let content = "#!/bin/sh\necho mine\n"
        try Data(content.utf8).write(to: foreign)

        let profile = Profile.sample()
        try keys.set(profile.slug, key: "the-key")
        try manager.createDirectory(at: paths.home(for: profile.slug), withIntermediateDirectories: true)

        let report = try store.remove(profile)

        XCTAssertFalse(report.removedScript)
        XCTAssertEqual(report.failures, [.script(foreign.path)])
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), content)
    }

    // MARK: - Unsafe paths

    /// A slug that could point somewhere else refuses the whole removal.
    func testRemoveRefusesAnUnsafeSlug() throws {
        let profile = Profile.sample(slug: "../evil")
        try keys.set(profile.slug, key: "the-key")

        XCTAssertThrowsError(try store.remove(profile)) { error in
            guard case .unsafeDeletePath = error as? ProfileError else {
                return XCTFail("wrong error: \(error)")
            }
        }

        XCTAssertEqual(try keys.get(profile.slug), "the-key")
        XCTAssertFalse(manager().fileExists(atPath: paths.root.appendingPathComponent("evil").path))
    }

    /// A slug with a dot is refused as well.
    func testRemoveRefusesASlugWithADot() throws {
        let profile = Profile.sample(slug: "my.profile")
        try keys.set(profile.slug, key: "the-key")

        XCTAssertThrowsError(try store.remove(profile)) { error in
            guard case .unsafeDeletePath = error as? ProfileError else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(try keys.get(profile.slug), "the-key")
    }

    // MARK: - Failing steps

    /// When a step fails, the other pieces are removed anyway and the leftover
    /// is reported.
    func testRemoveReportsALeftoverWhenTheHomeCannotBeRemoved() throws {
        let manager = FileManager.default
        let profile = Profile.sample()
        try materialize(profile)

        // A folder that cannot be emptied.
        let home = paths.home(for: profile.slug)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.path)
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        }

        let report = try store.remove(profile)

        XCTAssertTrue(report.removedKey)
        XCTAssertTrue(report.removedScript)
        XCTAssertFalse(report.removedHome)
        XCTAssertEqual(report.failures, [.home(home.path)])
        XCTAssertNil(try keys.get(profile.slug))
        XCTAssertFalse(manager.fileExists(atPath: paths.script(for: profile.slug).path))
        XCTAssertTrue(manager.fileExists(atPath: home.path))
    }
}
