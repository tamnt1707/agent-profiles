import XCTest
@testable import ClaudeProfilesCore

final class LauncherTests: XCTestCase {
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

    func testCommandWithoutWorkdir() {
        let command = Launcher.command(for: Profile.sample(), paths: paths)
        XCTAssertEqual(command, "'\(paths.script(for: "test").path)'")
    }

    func testCommandWithWorkdir() {
        var profile = Profile.sample()
        profile.workdir = "/tmp/my project"
        let command = Launcher.command(for: profile, paths: paths)
        XCTAssertEqual(command, "cd '/tmp/my project' && '\(paths.script(for: "test").path)'")
    }

    func testTerminalAppleScript() {
        let script = Launcher.appleScript(command: "cd '/tmp' && '/bin/true'", terminal: .terminal)
        XCTAssertTrue(script.contains("tell application \"Terminal\""))
        XCTAssertTrue(script.contains("do script \"cd '/tmp' && '/bin/true'\""))
        XCTAssertTrue(script.contains("end tell"))
    }

    func testITermAppleScript() {
        let script = Launcher.appleScript(command: "cd '/tmp' && '/bin/true'", terminal: .iTerm)
        XCTAssertTrue(script.contains("tell application \"iTerm\""))
        XCTAssertTrue(script.contains("create window with default profile"))
        XCTAssertTrue(script.contains("write text \"cd '/tmp' && '/bin/true'\""))
    }

    func testAppleScriptEscapesQuotesAndBackslashes() {
        let script = Launcher.appleScript(command: #"say "hi" \ bye"#, terminal: .terminal)
        XCTAssertTrue(script.contains(#"do script "say \"hi\" \\ bye""#))
    }
}
