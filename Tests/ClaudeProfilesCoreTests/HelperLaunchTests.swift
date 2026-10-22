import XCTest
@testable import ClaudeProfilesCore

/// The helper of an update replaces the app bundle, so it must start with an
/// empty environment: an exported function of the shell, an alias or a shim in
/// the PATH must not be able to change what it does.
final class HelperLaunchTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory(name: "helper-launch")
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - The arguments

    /// The helper is started through `env -i`: an empty environment, a PATH of
    /// its own, the home folder of the user and the script.
    func testTheHelperStartsWithAnEmptyEnvironment() {
        let arguments = HelperLaunch.arguments(
            script: URL(fileURLWithPath: "/tmp/work/install-update.sh"),
            home: URL(fileURLWithPath: "/Users/someone")
        )

        XCTAssertEqual(arguments, [
            "-i",
            "PATH=/usr/bin:/bin",
            "HOME=/Users/someone",
            "/bin/sh",
            "/tmp/work/install-update.sh",
        ])
    }

    /// The empty environment is the first thing: nothing of the environment of
    /// the app can be read before it is dropped.
    func testTheEnvironmentIsEmptiedBeforeAnythingElse() {
        let arguments = HelperLaunch.arguments(
            script: URL(fileURLWithPath: "/tmp/work/install-update.sh"),
            home: URL(fileURLWithPath: "/Users/someone")
        )

        XCTAssertEqual(arguments.first, "-i")
        XCTAssertTrue(arguments.contains("PATH=/usr/bin:/bin"))
        XCTAssertTrue(arguments.contains("HOME=/Users/someone"))
        XCTAssertEqual(arguments.last, "/tmp/work/install-update.sh")
    }

    /// The command that starts the helper in the background goes through
    /// `nohup` and `env`, and every part of it is quoted.
    func testTheCommandStartsTheHelperInTheBackground() {
        let command = HelperLaunch.command(
            script: URL(fileURLWithPath: "/tmp/work/install-update.sh"),
            home: URL(fileURLWithPath: "/Users/some one")
        )

        XCTAssertTrue(command.hasPrefix("/usr/bin/nohup /usr/bin/env "))
        XCTAssertTrue(command.hasSuffix(">/dev/null 2>&1 &"))
        XCTAssertTrue(command.contains("'-i'"))
        XCTAssertTrue(command.contains("'PATH=/usr/bin:/bin'"))
        XCTAssertTrue(command.contains("'HOME=/Users/some one'"))
        XCTAssertTrue(command.contains("'/bin/sh'"))
        XCTAssertTrue(command.contains("'/tmp/work/install-update.sh'"))
    }

    /// A path with a quote in it does not break the command.
    func testTheCommandQuotesEveryPart() {
        let command = HelperLaunch.command(
            script: URL(fileURLWithPath: "/tmp/work/it's here.sh"),
            home: URL(fileURLWithPath: "/Users/some one")
        )

        XCTAssertTrue(command.contains("'/tmp/work/it'\\''s here.sh'"))
        XCTAssertTrue(command.contains("'HOME=/Users/some one'"))
    }

    // MARK: - The helper in the shell

    /// A folder with a fake `open`, so the test sees what the script starts.
    private func makeFakeOpen() throws -> (directory: URL, log: URL) {
        let directory = temp.url.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = temp.url.appendingPathComponent("opened.txt")
        let open = directory.appendingPathComponent("open")
        let text = """
        #!/bin/sh
        echo "$1" >> '\(log.path)'
        """
        try Data(text.utf8).write(to: open)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        return (directory, log)
    }

    /// The tools of a script whose `open` is the fake one of the test.
    private func tools(withFakeOpen directory: URL) -> ToolPaths {
        var tools = ToolPaths.system
        tools.open = directory.appendingPathComponent("open").path
        return tools
    }

    /// The bundles of the test and the helper script that swaps them.
    private func makeHelper(pid: Int32 = 999_999) throws -> Helper {
        let fake = try makeFakeOpen()

        let applications = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let current = applications.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker.txt"))

        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newBundle = work.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundle.appendingPathComponent("marker.txt"))

        let log = temp.url.appendingPathComponent("logs/ClaudeProfilesUpdate.log")
        let script = InstallHelper.script(
            pid: pid,
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            logFile: log,
            tools: tools(withFakeOpen: fake.directory)
        )
        let path = temp.url.appendingPathComponent("helper.sh")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)

        return Helper(
            script: path,
            current: current,
            log: log,
            fake: fake
        )
    }

    /// The pieces of the helper of one test.
    private struct Helper {
        var script: URL
        var current: URL
        var log: URL
        var fake: (directory: URL, log: URL)
    }

    /// The environment of the app, with a function that takes the place of the
    /// `[` builtin of the shell.
    ///
    /// Bash reads such a function from the environment, and the helper uses
    /// `[` to compare the seconds it waited.
    private func hostileEnvironment(home: URL) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "BASH_FUNC_[%%": "() { exit 99; }",
            "BASH_FUNC_foo%%": "() { exit 99; }",
        ]
    }

    /// The helper behaves normally, even when the shell that starts it exports
    /// a function that takes the place of a builtin.
    ///
    /// The helper starts through `env -i`, so the function of the environment
    /// of the app never reaches it.
    func testTheHelperRunsWithAHostileEnvironmentAround() throws {
        // A process that is still alive when the helper starts, so the helper
        // really uses the `[` builtin while it waits.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        defer { sleeper.waitUntilExit() }

        let helper = try makeHelper(pid: sleeper.processIdentifier)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = HelperLaunch.arguments(script: helper.script, home: temp.url)
        process.environment = hostileEnvironment(home: temp.url)
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "the helper did not run normally")
        // The new app is in place and the app was started again.
        XCTAssertEqual(
            try String(contentsOf: helper.current.appendingPathComponent("marker.txt"), encoding: .utf8),
            "new"
        )
        let opened = (try? String(contentsOf: helper.fake.log, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(opened, [helper.current.path])
    }

    /// The function of the environment really would take over, so the empty
    /// environment of the helper is not a belief but a fact.
    func testTheHostileFunctionWouldStopTheHelperWithoutTheEmptyEnvironment() throws {
        // A process that is still alive when the helper starts, so the helper
        // really uses the `[` builtin while it waits.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        defer { sleeper.waitUntilExit() }

        let helper = try makeHelper(pid: sleeper.processIdentifier)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.script.path]
        process.environment = hostileEnvironment(home: temp.url)
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 99, "the function of the environment did not take over")
        // Nothing was swapped.
        XCTAssertEqual(
            try String(contentsOf: helper.current.appendingPathComponent("marker.txt"), encoding: .utf8),
            "old"
        )
    }
}
