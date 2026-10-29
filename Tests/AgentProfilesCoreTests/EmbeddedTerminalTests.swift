import XCTest
@testable import AgentProfilesCore

final class EmbeddedTerminalTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    // MARK: - The command

    func testTheCommandIsTheOneThatCopyCommandCopies() throws {
        var profile = Profile.sample(slug: "mini")
        profile.workdir = "/work/app"
        let command = try EmbeddedTerminalSpec.shellCommand(for: profile, paths: paths)
        XCTAssertEqual(
            command,
            "export PATH='\(paths.binDir.path)':\"$PATH\"; cd '/work/app' && claude-mini"
        )
    }

    func testTheFolderOfAChosenOneReplacesTheFolderOfTheProfile() throws {
        var profile = Profile.sample(slug: "mini")
        profile.workdir = "/work/app"
        let command = try EmbeddedTerminalSpec.shellCommand(for: profile, paths: paths, workdirOverride: "/other")
        XCTAssertTrue(command.hasSuffix("cd '/other' && claude-mini"))
    }

    func testAFolderWithAControlCharacterIsRefused() {
        var profile = Profile.sample(slug: "mini")
        profile.workdir = "/work/a\tb"
        XCTAssertThrowsError(try EmbeddedTerminalSpec.shellCommand(for: profile, paths: paths))
    }

    func testTheShellIsALoginInteractiveShell() {
        XCTAssertEqual(EmbeddedTerminalSpec.arguments(command: "x"), ["-l", "-i", "-c", "x"])
    }

    // MARK: - The book

    func testAStartedSessionRunsAndEnds() {
        var book = TerminalSessionBook()
        XCTAssertNil(book.state(for: "a"))
        let run = book.started("a")
        XCTAssertEqual(book.state(for: "a"), .running)
        XCTAssertEqual(book.runningSlugs, ["a"])
        XCTAssertTrue(book.exited("a", run: run, code: 0))
        XCTAssertEqual(book.state(for: "a"), .exited(code: 0))
        XCTAssertEqual(book.runningSlugs, [])
    }

    func testTheLateEndOfAnOlderRunIsIgnored() {
        var book = TerminalSessionBook()
        let first = book.started("a")
        book.started("a")
        XCTAssertFalse(book.exited("a", run: first, code: 1))
        XCTAssertEqual(book.state(for: "a"), .running)
    }

    func testEachProfileHasItsOwnSession() {
        var book = TerminalSessionBook()
        let a = book.started("a")
        book.started("b")
        book.exited("a", run: a, code: nil)
        XCTAssertEqual(book.state(for: "a"), .exited(code: nil))
        XCTAssertEqual(book.state(for: "b"), .running)
    }

    func testRenameMovesTheSessionAndItsRun() {
        var book = TerminalSessionBook()
        let run = book.started("old")
        book.renamed(from: "old", to: "new")
        XCTAssertNil(book.state(for: "old"))
        XCTAssertEqual(book.state(for: "new"), .running)
        XCTAssertTrue(book.exited("new", run: run, code: 0))
    }

    func testClosedForgetsTheSession() {
        var book = TerminalSessionBook()
        let run = book.started("a")
        book.closed("a")
        XCTAssertNil(book.state(for: "a"))
        XCTAssertFalse(book.exited("a", run: run, code: 0))
    }
}

/// The setting that chooses the terminal of the app or an outside one.
final class EmbeddedTerminalSettingTests: XCTestCase {
    private func roundTrip(_ data: AppData) throws -> AppData {
        let temp = try TempDirectory()
        let store = Store(paths: temp.paths(), keys: InMemoryKeyStore())
        try store.save(data)
        return store.load().data
    }

    func testItIsOnByDefaultAndNotWritten() throws {
        XCTAssertTrue(AppData().embeddedTerminal)
        let temp = try TempDirectory()
        let paths = temp.paths()
        try Store(paths: paths, keys: InMemoryKeyStore()).save(AppData())
        let text = try String(contentsOf: paths.dataFile, encoding: .utf8)
        XCTAssertFalse(text.contains("embedded_terminal"))
    }

    func testOffIsWrittenAndRead() throws {
        var data = AppData()
        data.embeddedTerminal = false
        XCTAssertFalse(try roundTrip(data).embeddedTerminal)
    }
}
