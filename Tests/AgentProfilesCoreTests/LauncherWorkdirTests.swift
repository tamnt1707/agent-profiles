import Foundation
import XCTest
@testable import AgentProfilesCore

/// The folder override of the menu bar launcher, and the quoting of folder names.
final class LauncherWorkdirTests: XCTestCase {
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

    private var script: String { paths.script(for: "test").path }

    func testWithoutOverrideTheProfileWorkdirIsUsed() throws {
        var profile = Profile.sample()
        profile.workdir = "/tmp/from profile"
        XCTAssertEqual(try Launcher.command(for: profile, paths: paths, workdirOverride: nil),
                       "cd '/tmp/from profile' && '\(script)'")
    }

    func testTheOverrideReplacesTheProfileWorkdir() throws {
        var profile = Profile.sample()
        profile.workdir = "/tmp/from profile"
        XCTAssertEqual(try Launcher.command(for: profile, paths: paths, workdirOverride: "/tmp/chosen"),
                       "cd '/tmp/chosen' && '\(script)'")
    }

    func testTheOverrideAddsACdWhenTheProfileHasNoWorkdir() throws {
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "/tmp/chosen"),
                       "cd '/tmp/chosen' && '\(script)'")
    }

    func testAnEmptyOverrideMeansNoCd() throws {
        var profile = Profile.sample()
        profile.workdir = "/tmp/from profile"
        XCTAssertEqual(try Launcher.command(for: profile, paths: paths, workdirOverride: ""), "'\(script)'")
    }

    func testAFolderWithSpacesIsOneQuotedArgument() throws {
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "/Users/me/My Projects/app"),
                       "cd '/Users/me/My Projects/app' && '\(script)'")
    }

    func testASingleQuoteInTheFolderIsEscaped() throws {
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "/tmp/it's here"),
                       "cd '/tmp/it'\\''s here' && '\(script)'")
    }

    func testATildeInTheOverrideIsExpandedToTheHomeDirectory() throws {
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "~/work dir"),
                       "cd '\(paths.home.path)/work dir' && '\(script)'")
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "~"),
                       "cd '\(paths.home.path)' && '\(script)'")
    }

    func testATildeInsideANameIsNotExpanded() throws {
        XCTAssertEqual(try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: "/tmp/a~b"),
                       "cd '/tmp/a~b' && '\(script)'")
    }

    /// Quotes and shell syntax in a folder name stay inside the single quotes.
    func testHostileFolderNamesAreQuotedAsOneWord() throws {
        let hostile = "/tmp/x'; rm -rf ~; echo '$(id)`id`\"q\"&|<>"
        let command = try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: hostile)
        XCTAssertEqual(command,
                       "cd '/tmp/x'\\''; rm -rf ~; echo '\\''$(id)`id`\"q\"&|<>' && '\(script)'")
    }

    /// Runs the real `/bin/sh` on the command. A folder named like shell syntax must
    /// neither break out of the `cd` nor run anything: the shell prints the folder it
    /// is in, and the sentinel file the name asks for is never created.
    func testAHostileFolderNameRunsNothingAndOpensThatFolder() throws {
        let manager = FileManager.default
        let hostileName = "a b'c \"d\" $(touch SENTINEL_HIT) `touch SENTINEL_HIT` ; x"
        let folder = temp.url.appendingPathComponent(hostileName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        // A launcher stand-in that prints its working directory.
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\npwd\n".utf8).write(to: URL(fileURLWithPath: script))
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

        let command = try Launcher.command(for: Profile.sample(), paths: paths, workdirOverride: folder.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // A clean environment: no shim, no alias and no exported function of
        // this machine can change what the command does.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": temp.url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), folder.path)

        // The folder name itself contains the text, so only a file named exactly like the sentinel counts.
        let enumerator = manager.enumerator(at: temp.url, includingPropertiesForKeys: nil)
        let names = enumerator?.allObjects.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(names.contains("SENTINEL_HIT"), "a shell expansion created the sentinel file")
    }
}
