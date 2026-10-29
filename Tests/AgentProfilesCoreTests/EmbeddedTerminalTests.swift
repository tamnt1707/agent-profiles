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

    func testATabRunsAndEnds() {
        var book = TerminalSessionBook()
        XCTAssertEqual(book.sessions(for: "a"), [])
        let tab = book.open("a")
        XCTAssertEqual(book.session(tab.id)?.state, .running)
        XCTAssertEqual(book.runningCount, 1)
        XCTAssertTrue(book.exited(tab.id, run: tab.run, code: 0))
        XCTAssertEqual(book.session(tab.id)?.state, .exited(code: 0))
        XCTAssertEqual(book.runningCount, 0)
    }

    func testAProfileHasSeveralTabsNumberedInOrder() {
        var book = TerminalSessionBook()
        let one = book.open("a")
        let two = book.open("a")
        book.open("b")
        XCTAssertEqual(book.sessions(for: "a").map(\.number), [1, 2])
        XCTAssertEqual(book.sessions(for: "b").map(\.number), [1])
        XCTAssertEqual(book.slug(of: two.id), "a")
        XCTAssertEqual(book.runningCount(for: "a"), 2)
        XCTAssertEqual(book.runningCount, 3)
        // Closing a tab does not renumber the others and its number is not used again.
        book.close(one.id)
        XCTAssertEqual(book.sessions(for: "a").map(\.number), [2])
        book.open("a")
        XCTAssertEqual(book.sessions(for: "a").map(\.number), [2, 3])
    }

    func testTheNumbersStartAgainWhenTheLastTabIsClosed() {
        var book = TerminalSessionBook()
        let tab = book.open("a")
        book.close(tab.id)
        XCTAssertEqual(book.sessions(for: "a"), [])
        book.open("a")
        XCTAssertEqual(book.sessions(for: "a").map(\.number), [1])
    }

    func testRestartGivesANewRunAndTheLateEndOfTheOldOneIsIgnored() {
        var book = TerminalSessionBook()
        let tab = book.open("a")
        let second = book.restart(tab.id)
        XCTAssertNotNil(second)
        XCTAssertFalse(book.exited(tab.id, run: tab.run, code: 1))
        XCTAssertEqual(book.session(tab.id)?.state, .running)
        XCTAssertTrue(book.exited(tab.id, run: second ?? -1, code: nil))
        XCTAssertEqual(book.session(tab.id)?.state, .exited(code: nil))
        // An ended tab runs again.
        XCTAssertNotNil(book.restart(tab.id))
        XCTAssertEqual(book.session(tab.id)?.state, .running)
        XCTAssertNil(book.restart(9999))
    }

    func testEachTabEndsOnItsOwn() {
        var book = TerminalSessionBook()
        let a = book.open("a")
        let b = book.open("a")
        book.exited(a.id, run: a.run, code: 0)
        XCTAssertEqual(book.session(a.id)?.state, .exited(code: 0))
        XCTAssertEqual(book.session(b.id)?.state, .running)
        XCTAssertEqual(book.runningCount(for: "a"), 1)
    }

    func testRenameMovesTheTabsAndTheirRuns() {
        var book = TerminalSessionBook()
        let tab = book.open("old")
        book.open("old")
        book.renamed(from: "old", to: "new")
        XCTAssertEqual(book.sessions(for: "old"), [])
        XCTAssertEqual(book.sessions(for: "new").count, 2)
        XCTAssertTrue(book.exited(tab.id, run: tab.run, code: 0))
        XCTAssertEqual(book.slug(of: tab.id), "new")
    }

    func testCloseAllForgetsTheTabsOfAProfileOnly() {
        var book = TerminalSessionBook()
        let a1 = book.open("a")
        let a2 = book.open("a")
        let b = book.open("b")
        XCTAssertEqual(Set(book.closeAll("a")), [a1.id, a2.id])
        XCTAssertEqual(book.sessions(for: "a"), [])
        XCTAssertNotNil(book.session(b.id))
        XCTAssertFalse(book.exited(a1.id, run: a1.run, code: 0))
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
