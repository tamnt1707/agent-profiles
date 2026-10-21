import XCTest
@testable import ClaudeProfilesCore

final class InstallHelperTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory(name: "install-helper")
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    // MARK: - The text of the script

    func testEveryPathIsQuoted() {
        let script = InstallHelper.script(
            pid: 4242,
            currentBundle: URL(fileURLWithPath: "/Applications/Claude Profiles.app"),
            newBundle: URL(fileURLWithPath: "/tmp/work/Claude Profiles.app"),
            workDirectory: URL(fileURLWithPath: "/tmp/work"),
            logFile: logFile
        )

        XCTAssertTrue(script.contains("PID='4242'"))
        XCTAssertTrue(script.contains("CURRENT='/Applications/Claude Profiles.app'"))
        XCTAssertTrue(script.contains("NEW='/tmp/work/Claude Profiles.app'"))
        XCTAssertTrue(script.contains("WORK='/tmp/work'"))
        XCTAssertTrue(script.contains("BACKUP='/Applications/Claude Profiles.app.old'"))
        // The script waits, checks the signature, starts the app and cleans up.
        XCTAssertTrue(script.contains("kill -0 \"$PID\""))
        XCTAssertTrue(script.contains("xattr -dr com.apple.quarantine"))
        XCTAssertTrue(script.contains("open \"$CURRENT\""))
        XCTAssertTrue(script.contains("rm -rf \"$BACKUP\""))
    }

    func testAPathWithAQuoteIsQuoted() {
        let script = InstallHelper.script(
            pid: 1,
            currentBundle: URL(fileURLWithPath: "/Applications/Claude Profile's.app"),
            newBundle: URL(fileURLWithPath: "/tmp/work/new.app"),
            workDirectory: URL(fileURLWithPath: "/tmp/work"),
            logFile: logFile
        )

        // The single quote inside the name is closed, escaped and opened again.
        XCTAssertTrue(script.contains("CURRENT='/Applications/Claude Profile'\\''s.app'"))
    }

    func testTheBackupSitsNextToTheBundle() {
        let backup = InstallHelper.backupURL(for: URL(fileURLWithPath: "/Applications/Claude Profiles.app"))
        XCTAssertEqual(backup.path, "/Applications/Claude Profiles.app.old")
    }

    // MARK: - The script in the shell

    /// A folder with a fake `open`, so the test sees what the script starts.
    private func makeFakeOpen() throws -> (directory: URL, log: URL) {
        let directory = temp.url.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = temp.url.appendingPathComponent("opened.txt")
        let open = directory.appendingPathComponent("open")
        let text = """
        #!/bin/sh
        echo "$1" >> "$OPEN_LOG"
        """
        try Data(text.utf8).write(to: open)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)
        return (directory, log)
    }

    /// Runs the helper and waits for it.
    private func run(_ script: String, extraPath: URL?, log: URL) throws -> Int32 {
        let path = temp.url.appendingPathComponent("helper.sh")
        try Data(script.utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        var environment = ProcessInfo.processInfo.environment
        if let extraPath {
            environment["PATH"] = extraPath.path + ":" + (environment["PATH"] ?? "")
        }
        environment["OPEN_LOG"] = log.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The log the helper writes to, inside the test folder.
    private var logFile: URL { temp.url.appendingPathComponent("logs/ClaudeProfilesUpdate.log") }

    private func logText() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    private func openedApps(_ log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func testTheHelperReplacesTheBundleAndStartsIt() throws {
        let fake = try makeFakeOpen()

        // The app that is running now.
        let applications = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let current = applications.appendingPathComponent("Claude Profile's.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker.txt"))

        // The new app, still in the working folder.
        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newBundle = work.appendingPathComponent("Claude Profile's.app")
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundle.appendingPathComponent("marker.txt"))

        let script = InstallHelper.script(
            pid: 999_999,           // a process that does not exist
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            logFile: logFile
        )
        XCTAssertEqual(try run(script, extraPath: fake.directory, log: fake.log), 0)

        // The new app is in place.
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("marker.txt").path))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker.txt"), encoding: .utf8), "new")
        // The old one is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Claude Profile's.app.old").path))
        // The app was started again.
        XCTAssertEqual(openedApps(fake.log), [current.path])
    }

    func testTheHelperPutsTheOldBundleBackWhenTheMoveFails() throws {
        let fake = try makeFakeOpen()

        let applications = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let current = applications.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker.txt"))

        // The working folder cannot be written, so the new app cannot be
        // moved out of it.
        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newBundle = work.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundle.appendingPathComponent("marker.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: work.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: work.path) }

        let script = InstallHelper.script(
            pid: 999_999,
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            logFile: logFile
        )
        XCTAssertEqual(try run(script, extraPath: fake.directory, log: fake.log), 1)

        // The failure is in the log, one line.
        XCTAssertEqual(logText().split(separator: "\n").count, 1)
        XCTAssertTrue(logText().contains("update failed"))

        // The old app is still there and was started again.
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("marker.txt").path))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker.txt"), encoding: .utf8), "old")
        XCTAssertEqual(openedApps(fake.log), [current.path])
    }

    func testTheHelperWaitsForTheAppToQuit() throws {
        let fake = try makeFakeOpen()

        let applications = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let current = applications.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)

        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newBundle = work.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)

        // A process that is still alive when the helper starts.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()
        let pid = sleeper.processIdentifier

        let script = InstallHelper.script(
            pid: pid,
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            logFile: logFile
        )

        let start = Date()
        XCTAssertEqual(try run(script, extraPath: fake.directory, log: fake.log), 0)
        let duration = Date().timeIntervalSince(start)

        sleeper.waitUntilExit()
        // The helper waited for the process to end.
        XCTAssertGreaterThan(duration, 0.5)
        // And the new app is in place.
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    // MARK: - The failure branches

    func testTheStaleBackupIsRemovedBeforeTheFirstMove() throws {
        let fake = try makeFakeOpen()

        let applications = temp.url.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let current = applications.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker.txt"))
        // A leftover of an earlier attempt.
        let stale = applications.appendingPathComponent("Claude Profiles.app.old", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("marker.txt"))

        let work = temp.url.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let newBundle = work.appendingPathComponent("Claude Profiles.app")
        try FileManager.default.createDirectory(at: newBundle, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: newBundle.appendingPathComponent("marker.txt"))

        let script = InstallHelper.script(
            pid: 999_999,
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            logFile: logFile
        )
        XCTAssertEqual(try run(script, extraPath: fake.directory, log: fake.log), 0)

        // The new app is in place and the old one is gone; nothing was nested in the stale copy.
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker.txt"), encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Claude Profiles.app.old").path))
        // A success writes nothing to the log.
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))
    }

    func testTheBundleIsLeftAloneWhenTheAppStillRuns() throws {
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

        // A process that keeps running, like an app that did not quit.
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["30"]
        try running.run()
        defer {
            running.terminate()
            running.waitUntilExit()
        }

        let script = InstallHelper.script(
            pid: running.processIdentifier,
            currentBundle: current,
            newBundle: newBundle,
            workDirectory: work,
            waitSeconds: 1,
            logFile: logFile
        )
        XCTAssertEqual(try run(script, extraPath: fake.directory, log: fake.log), 1)

        // Nothing was swapped and the app was not started.
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker.txt"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: applications.appendingPathComponent("Claude Profiles.app.old").path))
        XCTAssertEqual(openedApps(fake.log), [])
        XCTAssertTrue(logText().contains("update failed"))
    }

    func testTheScriptHasItsFailureBranches() {
        let script = InstallHelper.script(
            pid: 1,
            currentBundle: URL(fileURLWithPath: "/Applications/Claude Profiles.app"),
            newBundle: URL(fileURLWithPath: "/tmp/work/Claude Profiles.app"),
            workDirectory: URL(fileURLWithPath: "/tmp/work"),
            logFile: URL(fileURLWithPath: "/tmp/logs/ClaudeProfilesUpdate.log")
        )

        // The log file and its folder are quoted; the folder is created on failure.
        XCTAssertTrue(script.contains("LOG='/tmp/logs/ClaudeProfilesUpdate.log'"))
        XCTAssertTrue(script.contains("LOG_DIR='/tmp/logs'"))
        XCTAssertTrue(script.contains("mkdir -p \"$LOG_DIR\""))
        XCTAssertTrue(script.contains(">> \"$LOG\""))
        // Every failure stops with a non zero status.
        XCTAssertTrue(script.contains("exit 1"))
        XCTAssertTrue(script.contains("fail \"the app did not quit in time\""))
        // A running app stops the helper before anything is moved.
        XCTAssertLessThan(
            script.range(of: "fail \"the app did not quit in time\"")!.lowerBound,
            script.range(of: "mv \"$CURRENT\" \"$BACKUP\"")!.lowerBound
        )
        // A stale copy is removed before the first move.
        XCTAssertLessThan(
            script.range(of: "rm -rf \"$BACKUP\"")!.lowerBound,
            script.range(of: "mv \"$CURRENT\" \"$BACKUP\"")!.lowerBound
        )
        // A half moved bundle is removed before the old one is put back.
        XCTAssertLessThan(
            script.range(of: "rm -rf \"$CURRENT\"")!.lowerBound,
            script.range(of: "mv \"$BACKUP\" \"$CURRENT\"")!.lowerBound
        )
    }

    func testTheDefaultLogFileIsInTheUserLibrary() {
        XCTAssertTrue(InstallHelper.defaultLogFile.path.hasSuffix("/Library/Logs/ClaudeProfilesUpdate.log"))
    }
}
