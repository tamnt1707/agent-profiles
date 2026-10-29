import XCTest
@testable import AgentProfilesCore

final class AgentKindTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    // MARK: - Detection

    func testAUsualFolderIsFoundWithoutAskingTheShell() {
        var asked = false
        let install = AgentDetector.detect(
            .claude, home: home,
            isExecutable: { $0 == "/Users/someone/.local/bin/claude" },
            lookup: { _ in asked = true; return nil }
        )
        XCTAssertEqual(install.path, "/Users/someone/.local/bin/claude")
        XCTAssertTrue(install.isInstalled)
        XCTAssertFalse(asked)
    }

    func testTheShellIsAskedWhenNoUsualFolderHasIt() {
        let install = AgentDetector.detect(
            .claude, home: home,
            isExecutable: { $0 == "/custom/bin/claude" },
            lookup: { name in name == "claude" ? "/custom/bin/claude" : nil }
        )
        XCTAssertEqual(install.path, "/custom/bin/claude")
    }

    func testAnAnswerThatIsNotAProgramIsNotTrusted() {
        let install = AgentDetector.detect(
            .claude, home: home, isExecutable: { _ in false }, lookup: { _ in "/gone/claude" }
        )
        XCTAssertNil(install.path)
        XCTAssertFalse(install.isInstalled)
    }

    func testDetectAllHasEveryAgent() {
        let found = AgentDetector.detectAll(home: home, isExecutable: { _ in false }, lookup: { _ in nil })
        XCTAssertEqual(Set(found.keys), Set(AgentKind.allCases))
    }

    // MARK: - What the shell prints

    func testParseTakesThePathOrTheTargetOfAnAlias() {
        XCTAssertEqual(AgentDetector.parseLookup("/usr/local/bin/claude\n"), "/usr/local/bin/claude")
        XCTAssertEqual(
            AgentDetector.parseLookup("Last login: today\n/opt/x/claude\n"), "/opt/x/claude"
        )
        XCTAssertEqual(
            AgentDetector.parseLookup("claude: aliased to /Users/a/.claude/local/claude --flag\n"),
            "/Users/a/.claude/local/claude"
        )
        XCTAssertNil(AgentDetector.parseLookup(""))
        XCTAssertNil(AgentDetector.parseLookup("claude not found\n"))
    }

    // MARK: - The profile

    func testTheDefaultAgentIsClaudeAndIsNotWritten() throws {
        XCTAssertEqual(Profile().agent, .claude)
        let temp = try TempDirectory()
        let paths = temp.paths()
        let store = Store(paths: paths, keys: InMemoryKeyStore())
        try store.save(AppData(profiles: [Profile.sample()]))
        let text = try String(contentsOf: paths.dataFile, encoding: .utf8)
        XCTAssertFalse(text.contains("\"agent\""))
        XCTAssertEqual(store.load().data.profiles.first?.agent, .claude)
    }

    func testAFileWithAnUnknownAgentStillLoads() throws {
        let json = """
        {"profiles":[{"name":"A","slug":"a","agent":"nobody-knows"}]}
        """
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles.first?.agent, .claude)
    }
}
