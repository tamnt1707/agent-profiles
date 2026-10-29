import Foundation
import XCTest
@testable import AgentProfilesCore

/// A folder name with a control character is refused everywhere: the recent
/// folders, the launcher and the save of a profile.
final class UnsafeFolderTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        store = Store(paths: paths, keys: InMemoryKeyStore())
    }

    override func tearDown() {
        temp = nil
        paths = nil
        store = nil
    }

    /// The name of the reproduced attack: Ctrl-U clears the line of the shell,
    /// so the command behind it runs.
    private let attack = "/tmp/\u{15}rm -rf ~ #"

    /// A path as it stands in a JSON file: a control character is written the
    /// way JSON writes it.
    private func jsonPath(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - The launcher

    /// The folder chosen in the menu is refused, and nothing is typed into the
    /// terminal.
    func testTheChosenFolderWithAControlCharacterIsRefused() {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        XCTAssertThrowsError(
            try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths,
                                workdirOverride: attack, runner: runner)
        ) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToOpen(attack))
        }
        XCTAssertTrue(runner.calls.isEmpty, "osascript was run for an unsafe folder")
    }

    /// The working folder of the profile is refused as well.
    func testTheWorkdirOfTheProfileWithAControlCharacterIsRefused() {
        var profile = Profile.sample()
        profile.workdir = attack
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        XCTAssertThrowsError(
            try Launcher.launch(profile: profile, terminal: .terminal, paths: paths, runner: runner)
        ) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToOpen(attack))
        }
        XCTAssertTrue(runner.calls.isEmpty, "osascript was run for an unsafe folder")
    }

    /// The same in the background: the caller gets the error, the terminal stays
    /// closed.
    func testTheBackgroundLaunchRefusesAnUnsafeFolder() async {
        var profile = Profile.sample()
        profile.workdir = "/tmp/ok"
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        do {
            _ = try await Launcher.launchInBackground(profile: profile, terminal: .terminal, paths: paths,
                                                     workdirOverride: attack, runner: runner)
            XCTFail("the unsafe folder was launched")
        } catch {
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToOpen(attack))
        }
        XCTAssertTrue(runner.calls.isEmpty, "osascript was run for an unsafe folder")
    }

    /// The command itself refuses to be built from an unsafe folder.
    func testTheCommandRefusesAnUnsafeFolder() {
        XCTAssertThrowsError(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: attack))
    }

    /// A folder with a newline or a carriage return is refused too.
    func testAFolderWithANewlineIsRefused() {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        XCTAssertThrowsError(
            try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths,
                                workdirOverride: "/tmp/a\nb", runner: runner)
        )
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// A normal folder with Vietnamese letters, an emoji and spaces is not
    /// refused.
    func testANormalFolderIsLaunched() throws {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        let status = try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths,
                                         workdirOverride: "/Users/me/Việt Nam/🚀 app", runner: runner)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(runner.calls.count, 1)
    }

    // MARK: - The recent folders

    /// A folder with a control character never enters the list.
    func testTheRecentFoldersRefuseAControlCharacter() {
        var recent = RecentFolders(["/keep"])
        recent.add(attack)
        XCTAssertEqual(recent.paths, ["/keep"])
    }

    /// A stored list with such a folder loses that folder when it is read.
    func testAStoredRecentFolderWithAControlCharacterIsDropped() {
        let recent = RecentFolders([attack, "/keep"])
        XCTAssertEqual(recent.paths, ["/keep"])
    }

    /// An old `profiles.json` with such a recent folder loads, and the entry is
    /// gone.
    func testAnOldFileWithSuchARecentDirLoadsAndTheEntryIsDropped() throws {
        let json = """
        {
          "terminal": "Terminal",
          "profiles": [
            { "name": "Old", "slug": "old", "workdir": "", "recent_dirs": ["\(jsonPath(attack))", "/keep"] }
          ],
          "language": "en",
          "appearance": "system",
          "auto_check_updates": true
        }
        """
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.paths.dataFile)
        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data.profiles.count, 1)
        XCTAssertEqual(loaded.data.profiles[0].recentDirs, ["/keep"])
    }

    // MARK: - Saving a profile

    /// The working folder of a profile is checked when it is saved.
    func testSavingAProfileWithAnUnsafeWorkdirIsRefused() {
        var profile = Profile.sample()
        profile.workdir = attack
        XCTAssertThrowsError(try store.saveProfile(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToSave(attack))
        }
    }

    /// The check of the store refuses it on its own too.
    func testTheValidationRefusesAnUnsafeWorkdir() {
        var profile = Profile.sample()
        profile.workdir = attack
        XCTAssertThrowsError(try store.validate(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToSave(attack))
        }
    }

    /// A normal working folder passes the check.
    func testANormalWorkdirPassesTheValidation() throws {
        var profile = Profile.sample()
        profile.workdir = "/Users/me/Việt Nam"
        XCTAssertNoThrow(try store.validate(profile, others: []))
    }

    /// An empty working folder is not a folder and is not refused.
    func testAnEmptyWorkdirPassesTheValidation() throws {
        var profile = Profile.sample()
        profile.workdir = ""
        XCTAssertNoThrow(try store.validate(profile, others: []))
    }
}
