import XCTest
@testable import AgentProfilesCore

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

    func testShortNameTypesTheCommandOfCopyCommand() throws {
        var profile = Profile.sample(slug: "mini")
        profile.workdir = "/work/app"
        XCTAssertEqual(
            try Launcher.command(for: profile, paths: paths, useShortName: true),
            "cd '/work/app' && claude-mini"
        )
        XCTAssertEqual(
            try Launcher.command(for: profile, paths: paths, workdirOverride: "/other", useShortName: true),
            "cd '/other' && claude-mini"
        )
        // Without the flag the full path of the launcher is typed, as before.
        XCTAssertEqual(
            try Launcher.command(for: profile, paths: paths),
            "cd '/work/app' && '\(paths.script(for: "mini").path)'"
        )
    }

    func testCommandWithoutWorkdir() throws {
        let command = try Launcher.command(for: Profile.sample(), paths: paths)
        XCTAssertEqual(command, "'\(paths.script(for: "test").path)'")
    }

    func testCommandWithWorkdir() throws {
        var profile = Profile.sample()
        profile.workdir = "/tmp/my project"
        let command = try Launcher.command(for: profile, paths: paths)
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

    // MARK: - Hostile content in the AppleScript string

    /// A backslash and a double quote are the two characters that would end the
    /// AppleScript string. Both are escaped, and the rest of the hostile text
    /// stays where it is.
    func testHostileContentStaysInsideOneAppleScriptString() {
        let hostile = #"say "hi" \ bye; rm -rf ~ ; echo `id`"#
        let script = Launcher.appleScript(command: hostile, terminal: .terminal)
        XCTAssertTrue(script.contains(#"do script "say \"hi\" \\ bye; rm -rf ~ ; echo `id`""#))
        // The string of the script is closed exactly once, at the end.
        XCTAssertEqual(script.components(separatedBy: "\"").count % 2, 1)
    }

    /// The same for iTerm, which writes the text into the session.
    func testHostileContentStaysInsideOneITermString() {
        let hostile = #"say "hi" \ bye"#
        let script = Launcher.appleScript(command: hostile, terminal: .iTerm)
        XCTAssertTrue(script.contains(#"write text "say \"hi\" \\ bye""#))
    }

    /// A control character never reaches the terminal: the folder it could come
    /// from is refused before the command is built, and the escaping writes it
    /// as its name, so it cannot end the string of the script.
    func testAControlCharacterNeverReachesTheAppleScript() throws {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        XCTAssertThrowsError(
            try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths,
                                workdirOverride: "/tmp/a\u{1}b", runner: runner)
        )
        XCTAssertTrue(runner.calls.isEmpty, "osascript was run for an unsafe folder")

        // The escaping writes the control character as its name: the string of
        // the script cannot end before the command does.
        let script = Launcher.appleScript(command: "a\u{1}b", terminal: .terminal)
        XCTAssertTrue(script.contains(#"do script "a\u{1}b""#))
        XCTAssertFalse(script.contains("\u{1}"))
    }

    // MARK: - The AppleScript cannot be broken

    /// The exact text that the escaping writes.
    func testTheExactEscapedText() {
        XCTAssertEqual(Launcher.escapeForAppleScript(#"a\b"c"#), #"a\\b\"c"#)
        XCTAssertEqual(Launcher.escapeForAppleScript("a\tb"), #"a\tb"#)
        XCTAssertEqual(Launcher.escapeForAppleScript("a\nb"), #"a\nb"#)
        XCTAssertEqual(Launcher.escapeForAppleScript("a\rb"), #"a\rb"#)
        XCTAssertEqual(Launcher.escapeForAppleScript("a\u{1B}b"), #"a\u{1B}b"#)
    }

    /// A string with the characters that could end the string of the script
    /// stays inside it: no control character is left in the command, and the
    /// command does not add a line to the script.
    func testTheAppleScriptKeepsADangerousStringInsideOneStatement() {
        var dangerous = "\\ \" ' $ ` "
        for value in 0x00...0x1F {
            dangerous.unicodeScalars.append(Unicode.Scalar(value)!)
        }
        dangerous.unicodeScalars.append(Unicode.Scalar(0x7F)!)
        for value in 0x80...0x9F {
            dangerous.unicodeScalars.append(Unicode.Scalar(value)!)
        }
        dangerous.unicodeScalars.append(Unicode.Scalar(0x2028)!)
        dangerous.unicodeScalars.append(Unicode.Scalar(0x2029)!)

        // Not one control character is left in the command.
        let escaped = Launcher.escapeForAppleScript(dangerous)
        for scalar in escaped.unicodeScalars {
            XCTAssertFalse(FolderPathSafety.isControl(scalar),
                           "the command holds a raw control character")
        }

        for terminal in [TerminalApp.terminal, .iTerm] {
            let script = Launcher.appleScript(command: dangerous, terminal: terminal)
            let plain = Launcher.appleScript(command: "harmless", terminal: terminal)
            // The command did not become a second statement of the script.
            XCTAssertEqual(script.components(separatedBy: "\n").count,
                           plain.components(separatedBy: "\n").count)
            // The quote of the command and the backslash are escaped, so the
            // string of the script cannot end before the command does.
            XCTAssertTrue(script.contains(escaped))
            XCTAssertTrue(script.contains("\\\""))
            XCTAssertTrue(script.contains("\\\\"))
        }
    }

    /// The command of the profile goes into the script as one string, and the
    /// quote of the command does not end it.
    func testTheQuoteOfTheCommandDoesNotEndTheString() {
        let script = Launcher.appleScript(command: #"say "hi""#, terminal: .terminal)
        XCTAssertTrue(script.contains(#"do script "say \"hi\"""#))
    }

    // MARK: - The paths that go into the command

    /// The script of the profile goes into the command too: a path with a
    /// control character in it is refused there as well.
    func testTheCommandRefusesAScriptPathWithAControlCharacter() {
        let unsafe = Paths(root: paths.root.appendingPathComponent("ro\u{1}ot", isDirectory: true),
                           home: paths.home)
        XCTAssertThrowsError(try Launcher.command(for: Profile.sample(), paths: unsafe)) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToOpen(unsafe.script(for: "test").path))
        }
    }

    /// The home folder of the profile goes into the command too.
    func testTheCommandRefusesAHomePathWithAControlCharacter() {
        let unsafe = Paths(root: paths.root,
                           home: paths.home.appendingPathComponent("ho\u{1}me", isDirectory: true))
        XCTAssertThrowsError(try Launcher.command(for: Profile.sample(), paths: unsafe)) { error in
            XCTAssertEqual(error as? ProfileError, .unsafeFolderToOpen(unsafe.home.path))
        }
    }

    /// Nothing is typed into the terminal when a path of the command is not
    /// safe.
    func testAnUnsafePathOfTheCommandNeverReachesTheTerminal() {
        let unsafe = Paths(root: paths.root,
                           home: paths.home.appendingPathComponent("ho\u{1}me", isDirectory: true))
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        XCTAssertThrowsError(
            try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: unsafe, runner: runner)
        )
        XCTAssertTrue(runner.calls.isEmpty, "osascript was run for an unsafe path")
    }

    // MARK: - Working directory
    func testTildeInTheWorkdirIsExpandedToTheHomeDirectory() throws {
        var profile = Profile.sample()
        profile.workdir = "~/work dir"
        let command = try Launcher.command(for: profile, paths: paths)
        XCTAssertEqual(command, "cd '\(paths.home.path)/work dir' && '\(paths.script(for: "test").path)'")
        XCTAssertFalse(command.contains("'~"))
    }

    func testABareTildeIsTheHomeDirectory() throws {
        var profile = Profile.sample()
        profile.workdir = "~"
        XCTAssertEqual(try Launcher.command(for: profile, paths: paths),
                       "cd '\(paths.home.path)' && '\(paths.script(for: "test").path)'")
    }

    /// `~user` is another user's home, which is not ours to guess: it stays as it is.
    func testTildeWithAUserNameIsNotExpanded() throws {
        var profile = Profile.sample()
        profile.workdir = "~bob/x"
        XCTAssertTrue(try Launcher.command(for: profile, paths: paths).hasPrefix("cd '~bob/x' && "))
    }

    // MARK: - Running osascript

    func testLaunchRunsOsascriptWithTheScript() throws {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        let status = try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths, runner: runner)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.executable, "/usr/bin/osascript")
        XCTAssertEqual(runner.calls.first?.arguments.first, "-e")
    }

    /// The text that osascript printed is part of the error.
    func testLaunchFailureCarriesOsascriptsOutput() {
        let runner = LauncherStubRunner(result: ProcessResult(status: 1, output: "execution error: Terminal got an error (-1743)\n"))
        XCTAssertThrowsError(try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths, runner: runner)) { error in
            XCTAssertEqual(error as? ProfileError,
                           .launcherFailed("osascript failed for Terminal: execution error: Terminal got an error (-1743)"))
        }
    }

    func testLaunchFailureWithoutOutputNamesTheTerminal() {
        let runner = LauncherStubRunner(result: ProcessResult(status: 1))
        XCTAssertThrowsError(try Launcher.launch(profile: Profile.sample(), terminal: .iTerm, paths: paths, runner: runner)) { error in
            XCTAssertEqual(error as? ProfileError, .launcherFailed("osascript failed for ITerm"))
        }
    }

    func testLaunchReportsAnOsascriptThatCannotStart() {
        let runner = LauncherStubRunner(error: UpdateError.installFailed)
        XCTAssertThrowsError(try Launcher.launch(profile: Profile.sample(), terminal: .terminal, paths: paths, runner: runner)) { error in
            XCTAssertEqual(error as? ProfileError, .launcherFailed("osascript could not be started"))
        }
    }

    func testLaunchInBackgroundRunsTheSameCommand() async throws {
        let runner = LauncherStubRunner(result: ProcessResult(status: 0))
        let status = try await Launcher.launchInBackground(profile: Profile.sample(), terminal: .terminal, paths: paths, runner: runner)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(runner.calls.first?.executable, "/usr/bin/osascript")
    }
}

/// Records the commands it is asked to run and answers with a fixed result.
final class LauncherStubRunner: ProcessRunner, @unchecked Sendable {
    private let result: ProcessResult?
    private let error: Error?
    private(set) var calls: [(executable: String, arguments: [String])] = []

    init(result: ProcessResult? = nil, error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments))
        if let error { throw error }
        return result ?? ProcessResult(status: 0)
    }
}
