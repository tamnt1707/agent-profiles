import XCTest
@testable import ClaudeProfilesCore

final class ScriptRendererTests: XCTestCase {
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

    /// Ports the Rust test `script_has_no_secret_and_exports`.
    func testScriptHasNoSecretAndExports() throws {
        let profile = Profile.sample()
        let script = try ScriptRenderer.render(profile: profile, paths: paths)
        XCTAssertTrue(script.contains("export ANTHROPIC_AUTH_TOKEN=\"$__k\""))
        XCTAssertTrue(script.contains("export ANTHROPIC_BASE_URL='https://example.com/anthropic'"))
        XCTAssertTrue(script.contains("export ANTHROPIC_MODEL='m-1'"))
        XCTAssertTrue(script.contains("export API_TIMEOUT_MS='600000'"))
        XCTAssertTrue(script.contains("CLAUDE_CONFIG_DIR="))
        XCTAssertFalse(script.contains("ANTHROPIC_DEFAULT_OPUS_MODEL='"))
        XCTAssertTrue(script.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exec claude \"$@\""))
    }

    func testScriptMatchesTheRustGoldenFile() throws {
        let profile = Profile.sample()
        let script = try ScriptRenderer.render(profile: profile, paths: paths, strings: .vietnamese)
        let golden = try Fixtures.script("script_bearer_isolated", root: paths.root)
        XCTAssertEqual(script, golden)
    }

    func testApiKeyScriptMatchesTheRustGoldenFile() throws {
        var profile = Profile.sample()
        profile.auth = .apiKey
        profile.isolate = false
        profile.shareFromDefault = false
        profile.opusModel = "o-1"
        profile.sonnetModel = "s-1"
        profile.haikuModel = "h-1"
        profile.workdir = "/tmp/work"
        let script = try ScriptRenderer.render(profile: profile, paths: paths, strings: .vietnamese)
        let golden = try Fixtures.script("script_apikey_no_isolate", root: paths.root)
        XCTAssertEqual(script, golden)
    }

    func testAuthNoneHasNoKeychainRead() throws {
        var profile = Profile.sample()
        profile.auth = .none
        profile.name = "No Key"
        profile.slug = "nokey"
        let script = try ScriptRenderer.render(profile: profile, paths: paths, strings: .vietnamese)
        let golden = try Fixtures.script("script_auth_none", root: paths.root)
        XCTAssertEqual(script, golden)
        XCTAssertFalse(script.contains("find-generic-password"))
        XCTAssertFalse(script.contains("ANTHROPIC_AUTH_TOKEN=\"$__k\""))
        XCTAssertFalse(script.contains("ANTHROPIC_API_KEY=\"$__k\""))
    }

    /// The marker tells a launcher of this app apart from a foreign file.
    func testTheMarkerSitsInTheFirstThreeLines() throws {
        let script = try ScriptRenderer.render(profile: Profile.sample(), paths: paths)
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines.prefix(3).contains(where: { $0.contains(ScriptRenderer.marker) }))
        XCTAssertTrue(ScriptRenderer.isManagedLauncher(script))
    }

    /// A file of another program does not carry the marker.
    func testAForeignScriptIsNotAManagedLauncher() {
        XCTAssertFalse(ScriptRenderer.isManagedLauncher("#!/bin/sh\necho mine\n"))
        XCTAssertFalse(ScriptRenderer.isManagedLauncher(""))
    }

    func testIsolateOffOmitsConfigDir() throws {
        var profile = Profile.sample()
        profile.isolate = false
        let script = try ScriptRenderer.render(profile: profile, paths: paths)
        XCTAssertFalse(script.contains("CLAUDE_CONFIG_DIR"))
    }

    func testScriptNeverContainsTheSecret() throws {
        let profile = Profile.sample()
        let script = try ScriptRenderer.render(profile: profile, paths: paths)
        XCTAssertFalse(script.contains("super-secret-key"))
        XCTAssertTrue(script.contains("find-generic-password -s 'claude-profiles' -a 'test' -w"))
    }

    func testExtraEnvIsExported() throws {
        var profile = Profile.sample()
        profile.extraEnv = "FOO=bar\nexport BAZ='qux'"
        let script = try ScriptRenderer.render(profile: profile, paths: paths)
        XCTAssertTrue(script.contains("export FOO='bar'"))
        XCTAssertTrue(script.contains("export BAZ='qux'"))
    }

    func testHostileNameCannotBreakOutOfTheScript() throws {
        var profile = Profile.sample()
        profile.name = "it's \"quoted\" $(whoami) `id`\nsecond line"
        profile.slug = "evil"
        profile.baseURL = "https://x.example/$(id)"
        profile.model = "m ' $(x)"
        profile.extraEnv = "EVIL='v' \"w\"\n"

        let script = try ScriptRenderer.render(profile: profile, paths: paths)

        // The script still parses as a shell script.
        XCTAssertTrue(ShellCheck.isValidShellScript(script), "the generated script is not valid zsh")

        // The name does not add a single line to the script.
        let benign = try ScriptRenderer.render(profile: Profile.sample(), paths: paths)
        XCTAssertEqual(script.split(separator: "\n").count, benign.split(separator: "\n").count)

        // Each error message is one closed double quoted string (missing key and access denied).
        let messageLines = script.split(separator: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("echo \"")
        }
        XCTAssertEqual(messageLines.count, 2)
        for line in messageLines {
            XCTAssertTrue(line.hasPrefix("    echo \""))
            XCTAssertTrue(line.hasSuffix("\" >&2"))
            let inner = unescaped(String(line.dropFirst("    echo \"".count).dropLast("\" >&2".count)))
            XCTAssertFalse(inner.contains("\""), "the message must not contain a raw quote")
            XCTAssertFalse(inner.contains("$("), "the message must not contain a command substitution")
            XCTAssertFalse(inner.contains("`"), "the message must not contain a backtick")
        }

        // The other values are single quoted, so they cannot run anything either.
        XCTAssertTrue(script.contains("export ANTHROPIC_BASE_URL='https://x.example/$(id)'"))
        XCTAssertTrue(script.contains("export ANTHROPIC_MODEL='m '\\'' $(x)'"))
    }

    func testHostileNameDoesNotChangeTheStructure() throws {
        var profile = Profile.sample()
        profile.name = "a\"b"
        let script = try ScriptRenderer.render(profile: profile, paths: paths)
        // The header comment keeps the name as it is; only line breaks are removed.
        XCTAssertTrue(script.contains("# Created by Claude Profiles for profile \"a\"b\"."))
        // The message escapes the quotes so that the string cannot be closed early.
        XCTAssertTrue(script.contains("echo \"No API key for profile 'a\\\"b' in the Keychain."))
    }

    /// The characters of a line that are not escaped by a backslash.
    private func unescaped(_ line: String) -> String {
        var out = ""
        var escaped = false
        for character in line {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            out.append(character)
        }
        return out
    }
}

/// Runs `zsh -n` to check that a script is syntactically valid. Nothing is executed.
enum ShellCheck {
    static func isValidShellScript(_ script: String) -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profiles-shellcheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("check.zsh")
            try Data(script.utf8).write(to: file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-n", file.path]
            // A clean environment: the check must not see anything of the
            // machine it runs on.
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
