import XCTest
@testable import ClaudeProfilesCore

/// Runs the written blocks in the real shells. Sourcing a file twice must add
/// the bin folder to PATH once, even when several files of the same shell carry the block.
final class ShellPathRuntimeTests: XCTestCase {
    private var temp: TempDirectory!
    private var home: URL!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        home = temp.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        temp = nil
        home = nil
    }

    private var bin: URL { home.appendingPathComponent(".claude-profiles/bin", isDirectory: true) }

    /// Runs a command with a clean environment: only HOME and a short PATH.
    private func run(_ executable: String, _ arguments: [String], extra: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// How many PATH entries are the bin folder.
    private func entries(in path: String, folder: String) -> Int {
        path.split(separator: ":").filter { String($0) == folder }.count
    }

    private func setupPath(login: String, binDir: URL? = nil) -> ShellPathSetup {
        ShellPathSetup(home: home, binDir: binDir ?? bin, loginShell: login, environment: [:])
    }

    private func requireExecutable(_ path: String) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path), "\(path) is not installed")
    }

    /// Runs a command with exactly the given environment: no PATH unless it is in `environment`.
    private func runExact(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The block under `set -eu` with PATH unset, empty and with spaces: one entry, never an empty one.
    func testBlockUnderSetUWithPathUnsetEmptyOrWithSpacesAddsExactlyOneEntry() throws {
        try requireExecutable("/bin/sh")
        try requireExecutable("/bin/bash")
        try requireExecutable("/bin/zsh")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let folder = bin.standardizedFileURL.path
        try Data("# existing\n".utf8).write(to: home.appendingPathComponent(".profile"))
        try Data("# existing\n".utf8).write(to: home.appendingPathComponent(".bash_profile"))
        try Data("# existing\n".utf8).write(to: home.appendingPathComponent(".zshrc"))
        // Bash first: once ~/.bash_profile exists, a ~/.profile block is one bash no
        // longer reads, and install refuses to add a second block beside it.
        _ = try setupPath(login: "/bin/bash").install(for: .bash)
        _ = try setupPath(login: "/bin/sh").install(for: .posix)
        _ = try setupPath(login: "/bin/zsh").install(for: .zsh)

        let shells: [(executable: String, arguments: [String], script: String)] = [
            ("/bin/sh", ["-c"], "set -eu; . \"$HOME/.profile\"; . \"$HOME/.profile\"; printf '%s' \"$PATH\""),
            ("/bin/bash", ["-c"], "set -eu; . \"$HOME/.bash_profile\"; . \"$HOME/.bash_profile\"; printf '%s' \"$PATH\""),
            ("/bin/zsh", ["-f", "-c"], "set -eu; . \"$HOME/.zshrc\"; . \"$HOME/.zshrc\"; print -rn -- \"$PATH\""),
        ]
        let pathValues: [String?] = [nil, "", "/opt/my tools:/usr/bin:/bin"]
        for shell in shells {
            for pathValue in pathValues {
                var environment = ["HOME": home.path]
                if let pathValue { environment["PATH"] = pathValue }
                let path = try runExact(shell.executable, shell.arguments + [shell.script], environment: environment)
                let label = "\(shell.executable) PATH=\(pathValue?.debugDescription ?? "unset")"
                let entries = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                XCTAssertEqual(entries.filter { $0 == folder }.count, 1, "\(label): \(path)")
                XCTAssertFalse(entries.contains(""), "\(label) has an empty entry: \(path)")
                if pathValue == "" {
                    XCTAssertEqual(path, folder, label)
                }
                if pathValue == "/opt/my tools:/usr/bin:/bin" {
                    XCTAssertTrue(entries.contains("/opt/my tools"), label)
                }
            }
        }
    }

    func testPosixBlockSourcedTwiceAddsTheFolderOnce() throws {
        try requireExecutable("/bin/sh")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try setupPath(login: "/bin/sh").install(for: .posix)

        let script = ". \"$HOME/.profile\"; . \"$HOME/.profile\"; printf '%s' \"$PATH\""
        let path = try run("/bin/sh", ["-c", script])
        XCTAssertEqual(entries(in: path, folder: bin.standardizedFileURL.path), 1, path)
    }

    func testBashBlocksInBothFilesDoNotDuplicateThePath() throws {
        try requireExecutable("/bin/bash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("# existing\n".utf8).write(to: home.appendingPathComponent(".bash_profile"))
        try Data("# existing\n".utf8).write(to: home.appendingPathComponent(".bashrc"))
        _ = try setupPath(login: "/bin/bash").install(for: .bash)

        let script = ". \"$HOME/.bash_profile\"; . \"$HOME/.bashrc\"; . \"$HOME/.bashrc\"; printf '%s' \"$PATH\""
        let path = try run("/bin/bash", ["-c", script])
        XCTAssertEqual(entries(in: path, folder: bin.standardizedFileURL.path), 1, path)
    }

    func testZshBlockSourcedTwiceAddsTheFolderOnce() throws {
        try requireExecutable("/bin/zsh")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try setupPath(login: "/bin/zsh").install(for: .zsh)

        // -f: no system or user startup files, only the block under test.
        let script = ". \"$HOME/.zshrc\"; . \"$HOME/.zshrc\"; print -rn -- \"$PATH\""
        let path = try run("/bin/zsh", ["-f", "-c", script])
        XCTAssertEqual(entries(in: path, folder: bin.standardizedFileURL.path), 1, path)
    }

    func testAbsolutePathBlockSourcedTwiceAddsTheFolderOnce() throws {
        try requireExecutable("/bin/sh")
        let outside = temp.url.appendingPathComponent("elsewhere/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = try setupPath(login: "/bin/sh", binDir: outside).install(for: .posix)

        let script = ". \"$HOME/.profile\"; . \"$HOME/.profile\"; printf '%s' \"$PATH\""
        let path = try run("/bin/sh", ["-c", script])
        XCTAssertEqual(entries(in: path, folder: outside.standardizedFileURL.path), 1, path)
    }

    func testFishFileSourcedTwiceAddsTheFolderOnce() throws {
        let candidates = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
        guard let fish = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("fish is not installed")
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = try setupPath(login: fish).install(for: .fish)

        let file = home.appendingPathComponent(".config/fish/conf.d/claude-profiles.fish").path
        let script = "source \(file); source \(file); string join : $PATH"
        let path = try run(fish, ["--no-config", "-c", script])
        XCTAssertEqual(entries(in: path, folder: bin.standardizedFileURL.path), 1, path)
    }
}
