import Foundation
import XCTest
@testable import AgentProfilesCore

/// The editor of `settings.json` and `.claude.json` of an isolated profile:
/// it keeps what it does not edit, and refuses to write when that is not safe.
final class ClaudeConfigFileTests: XCTestCase {
    private var temp: TempDirectory!
    private var folder: URL!
    private var location: ClaudeConfigLocation!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        folder = temp.url.appendingPathComponent("homes/work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        location = ClaudeConfigLocation(folder: folder)
    }

    override func tearDown() {
        temp = nil
    }

    // MARK: - Helpers

    private func put(_ text: String, _ kind: ClaudeConfigFileKind, mode: Int? = nil) throws {
        let url = folder.appendingPathComponent(kind.fileName)
        try Data(text.utf8).write(to: url)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    private func object(_ kind: ClaudeConfigFileKind) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent(kind.fileName))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func text(_ kind: ClaudeConfigFileKind) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(kind.fileName), encoding: .utf8)
    }

    private func mode(_ kind: ClaudeConfigFileKind) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(kind.fileName).path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// A `.claude.json` with the kind of things Claude Code keeps in it.
    private let stateFixture = """
    {
      "numStartups": 42,
      "ratio": 0.1,
      "big": 12345678901234567890,
      "flag": true,
      "nothing": null,
      "userID": "abc/def",
      "name": "Nguyễn Văn A 😀",
      "projects": {
        "/Users/me/work": {
          "allowedTools": [],
          "mcpServers": { "local": { "type": "stdio", "command": "x" } },
          "history": [{ "display": "hi", "pastedContents": {} }]
        }
      },
      "mcpServers": {
        "files": { "type": "stdio", "command": "npx", "args": ["-y", "server-files"], "env": { "ROOT": "/tmp" }, "timeout": 5000 },
        "remote": { "type": "http", "url": "https://mcp.example.com", "headers": { "Authorization": "Bearer sk-123" }, "oauth": { "clientId": "c1" } }
      }
    }
    """

    // MARK: - Keeping what is not edited

    func testUnknownKeysAreKeptWhenServersChange() throws {
        try put(stateFixture, .state, mode: 0o600)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        servers.append(McpServer(name: "new", command: "run-me"))
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try object(.state)
        XCTAssertEqual(saved["numStartups"] as? Int, 42)
        XCTAssertEqual(saved["flag"] as? Bool, true)
        XCTAssertTrue(saved["nothing"] is NSNull)
        XCTAssertEqual(saved["userID"] as? String, "abc/def")
        XCTAssertEqual(saved["name"] as? String, "Nguyễn Văn A 😀")
        XCTAssertEqual((saved["big"] as? NSNumber)?.uint64Value, 12345678901234567890)
        let projects = try XCTUnwrap(saved["projects"] as? [String: Any])
        let project = try XCTUnwrap(projects["/Users/me/work"] as? [String: Any])
        XCTAssertNotNil((project["mcpServers"] as? [String: Any])?["local"], "project-scope servers are not user-scope servers")
        XCTAssertEqual(((project["history"] as? [[String: Any]])?.first)?["display"] as? String, "hi")

        // Numbers keep their text, slashes and letters are not escaped.
        let written = try text(.state)
        XCTAssertTrue(written.contains("\"ratio\": 0.1,"), written)
        XCTAssertTrue(written.contains("\"big\": 12345678901234567890"), written)
        XCTAssertTrue(written.contains("abc/def"))
        XCTAssertTrue(written.contains("Nguyễn Văn A 😀"))
    }

    func testUnchangedServerKeepsItsWholeEntry() throws {
        try put(stateFixture, .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        servers.removeAll { $0.name == "files" }
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try XCTUnwrap(try object(.state)["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["remote"])
        let remote = try XCTUnwrap(saved["remote"] as? [String: Any])
        XCTAssertEqual((remote["oauth"] as? [String: Any])?["clientId"] as? String, "c1")
        XCTAssertEqual((remote["headers"] as? [String: String])?["Authorization"], "Bearer sk-123")
    }

    func testNothingChangedWritesNothing() throws {
        try put(stateFixture, .state)
        let before = try text(.state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply(try McpServers.read(from: document), to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertEqual(try text(.state), before, "an unchanged file is not rewritten")
    }

    // MARK: - Servers

    func testServersAreRead() throws {
        try put(stateFixture, .state)
        let servers = try McpServers.read(from: try ClaudeConfigFile.read(.state, in: location))
        XCTAssertEqual(servers.map(\.name), ["files", "remote"])
        XCTAssertEqual(servers[0].transport, .stdio)
        XCTAssertEqual(servers[0].command, "npx")
        XCTAssertEqual(servers[0].args, ["-y", "server-files"])
        XCTAssertEqual(servers[0].env.map(\.key), ["ROOT"])
        XCTAssertEqual(servers[1].transport, .http)
        XCTAssertEqual(servers[1].url, "https://mcp.example.com")
        XCTAssertEqual(servers[1].headers.first?.value, "Bearer sk-123")
    }

    func testEntryWithoutTypeIsStdioAndKeepsHavingNoType() throws {
        try put(#"{"mcpServers": {"plain": {"command": "a", "args": ["1"]}}}"#, .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        XCTAssertEqual(servers.first?.transport, .stdio)
        servers[0].args = ["1", "2"]
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let entry = try XCTUnwrap((try object(.state)["mcpServers"] as? [String: Any])?["plain"] as? [String: Any])
        XCTAssertNil(entry["type"])
        XCTAssertEqual(entry["args"] as? [String], ["1", "2"])
    }

    func testEditingAServerKeepsItsUnknownKeys() throws {
        try put(stateFixture, .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        servers[0].command = "bunx"
        servers[0].env.append(ConfigPair(key: "DEBUG", value: "1"))
        servers[1].url = "https://other.example.com/mcp"
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try XCTUnwrap(try object(.state)["mcpServers"] as? [String: Any])
        let files = try XCTUnwrap(saved["files"] as? [String: Any])
        XCTAssertEqual(files["command"] as? String, "bunx")
        XCTAssertEqual(files["timeout"] as? Int, 5000)
        XCTAssertEqual(files["env"] as? [String: String], ["ROOT": "/tmp", "DEBUG": "1"])
        let remote = try XCTUnwrap(saved["remote"] as? [String: Any])
        XCTAssertEqual(remote["url"] as? String, "https://other.example.com/mcp")
        XCTAssertNotNil(remote["oauth"])
    }

    func testRenamingAndChangingTheTransport() throws {
        try put(stateFixture, .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        servers[0].name = "files-sse"
        servers[0].transport = .sse
        servers[0].url = "https://sse.example.com"
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try XCTUnwrap(try object(.state)["mcpServers"] as? [String: Any])
        XCTAssertNil(saved["files"])
        let entry = try XCTUnwrap(saved["files-sse"] as? [String: Any])
        XCTAssertEqual(entry["type"] as? String, "sse")
        XCTAssertEqual(entry["url"] as? String, "https://sse.example.com")
        XCTAssertNil(entry["command"])
        XCTAssertNil(entry["args"])
        XCTAssertEqual(entry["timeout"] as? Int, 5000, "keys of no transport stay")
    }

    func testNewServersGetTheirType() throws {
        try put("{}", .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply([
            McpServer(name: "local", command: "node", args: ["server.js"], env: [ConfigPair(key: "K", value: "v")]),
            McpServer(name: "web", transport: .http, url: "https://x.example.com", headers: [ConfigPair(key: "X-Api-Key", value: "s")]),
        ], to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try XCTUnwrap(try object(.state)["mcpServers"] as? [String: Any])
        let local = try XCTUnwrap(saved["local"] as? [String: Any])
        XCTAssertEqual(local["type"] as? String, "stdio")
        XCTAssertEqual(local["command"] as? String, "node")
        XCTAssertEqual(local["args"] as? [String], ["server.js"])
        XCTAssertEqual(local["env"] as? [String: String], ["K": "v"])
        let web = try XCTUnwrap(saved["web"] as? [String: Any])
        XCTAssertEqual(web["type"] as? String, "http")
        XCTAssertEqual(web["headers"] as? [String: String], ["X-Api-Key": "s"])
        XCTAssertNil(web["command"])
    }

    func testUnsupportedServerIsKeptAsItIs() throws {
        try put(#"{"mcpServers": {"sock": {"type": "ws", "url": "wss://x", "extra": [1]}, "odd": {"command": 5}}}"#, .state)
        var document = try ClaudeConfigFile.read(.state, in: location)
        var servers = try McpServers.read(from: document)
        XCTAssertEqual(servers.map(\.isEditable), [false, false])
        XCTAssertEqual(servers.first { $0.name == "sock" }?.unsupportedType, "ws")
        servers.removeAll { $0.name == "odd" }
        servers.append(McpServer(name: "n", command: "c"))
        try McpServers.apply(servers, to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try XCTUnwrap(try object(.state)["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["sock", "n"])
        XCTAssertEqual((saved["sock"] as? [String: Any])?["extra"] as? [Int], [1])
    }

    func testInvalidServersAreRefused() throws {
        var document = try ClaudeConfigFile.read(.state, in: location)
        XCTAssertThrowsError(try McpServers.apply([McpServer(name: " ", command: "c")], to: &document)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .emptyServerName)
        }
        XCTAssertThrowsError(try McpServers.apply([McpServer(name: "a", command: "c"), McpServer(name: "a", command: "d")], to: &document)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .duplicateServerName("a"))
        }
        XCTAssertThrowsError(try McpServers.apply([McpServer(name: "w", transport: .http)], to: &document)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .incompleteServer("w"))
        }
    }

    func testServersOfAnUnexpectedShapeAreRefused() throws {
        try put(#"{"mcpServers": []}"#, .state)
        let document = try ClaudeConfigFile.read(.state, in: location)
        XCTAssertThrowsError(try McpServers.read(from: document)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .unexpectedShape(path: document.url.path, key: "mcpServers"))
        }
    }

    // MARK: - Permissions

    private let settingsFixture = """
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "model": "opus",
      "env": { "API_TIMEOUT_MS": "600000" },
      "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "say done" }] }] },
      "permissions": {
        "allow": ["Bash(npm run lint)", "Read(~/notes/**)"],
        "deny": ["Read(./.env)"],
        "defaultMode": "acceptEdits",
        "additionalDirectories": ["../docs/"]
      }
    }
    """

    func testPermissionsAreRead() throws {
        try put(settingsFixture, .settings)
        let rules = try PermissionRules.read(from: try ClaudeConfigFile.read(.settings, in: location))
        XCTAssertEqual(rules, PermissionRules(allow: ["Bash(npm run lint)", "Read(~/notes/**)"], ask: [], deny: ["Read(./.env)"]))
    }

    func testPermissionsEditKeepsTheRest() throws {
        try put(settingsFixture, .settings, mode: 0o640)
        var document = try ClaudeConfigFile.read(.settings, in: location)
        var rules = try PermissionRules.read(from: document)
        rules.allow.removeFirst()
        rules.ask = ["Bash(git push *)", "  "]
        rules.deny = []
        try rules.apply(to: &document)
        try ClaudeConfigFile.write(document, in: location)

        let saved = try object(.settings)
        XCTAssertEqual(saved["model"] as? String, "opus")
        XCTAssertEqual(saved["$schema"] as? String, "https://json.schemastore.org/claude-code-settings.json")
        XCTAssertEqual((saved["env"] as? [String: String])?["API_TIMEOUT_MS"], "600000")
        XCTAssertNotNil((saved["hooks"] as? [String: Any])?["Stop"])
        let permissions = try XCTUnwrap(saved["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Read(~/notes/**)"])
        XCTAssertEqual(permissions["ask"] as? [String], ["Bash(git push *)"], "blank rules are left out")
        XCTAssertNil(permissions["deny"], "an emptied list is removed")
        XCTAssertEqual(permissions["defaultMode"] as? String, "acceptEdits")
        XCTAssertEqual(permissions["additionalDirectories"] as? [String], ["../docs/"])
        XCTAssertEqual(try mode(.settings), 0o640, "the permissions of the file are kept")
    }

    func testPermissionsOfAnUnexpectedShapeAreRefused() throws {
        try put(#"{"permissions": {"allow": "Bash"}}"#, .settings)
        let document = try ClaudeConfigFile.read(.settings, in: location)
        XCTAssertThrowsError(try PermissionRules.read(from: document)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .unexpectedShape(path: document.url.path, key: "permissions.allow"))
        }
    }

    // MARK: - Missing files

    func testMissingSettingsIsCreatedWith0644() throws {
        var document = try ClaudeConfigFile.read(.settings, in: location)
        XCTAssertFalse(document.exists)
        try PermissionRules(deny: ["WebFetch"]).apply(to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertEqual(try mode(.settings), 0o644)
        XCTAssertEqual(try object(.settings)["permissions"] as? [String: [String]], ["deny": ["WebFetch"]])
    }

    func testMissingSettingsIsNotCreatedForNothing() throws {
        var document = try ClaudeConfigFile.read(.settings, in: location)
        try PermissionRules().apply(to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.settingsFile.path))
    }

    func testMissingStateFileIsCreatedWithOnlyTheServersAnd0600() throws {
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply([McpServer(name: "a", command: "b")], to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertEqual(try mode(.state), 0o600)
        XCTAssertEqual(Set(try object(.state).keys), ["mcpServers"])
    }

    func testMissingStateFileIsNeverCreatedWithOtherKeys() throws {
        var document = try ClaudeConfigFile.read(.state, in: location)
        document.root["theme"] = "dark"
        XCTAssertThrowsError(try ClaudeConfigFile.write(document, in: location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.stateFile.path))
    }

    func testMissingStateFileIsNotCreatedWithoutServers() throws {
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply([], to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.stateFile.path))
    }

    func testStateFileModeIsKept() throws {
        try put(stateFixture, .state, mode: 0o600)
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply([], to: &document)
        try ClaudeConfigFile.write(document, in: location)
        XCTAssertEqual(try mode(.state), 0o600)
        XCTAssertEqual((try object(.state)["mcpServers"] as? [String: Any])?.isEmpty, true)
    }

    // MARK: - Refusals

    func testUnparsableFileIsRefused() throws {
        try put(#"{"permissions": {"allow": ["a",]}"#, .settings)
        XCTAssertThrowsError(try ClaudeConfigFile.read(.settings, in: location)) { error in
            guard case .notParsable(let path, _)? = error as? ClaudeConfigError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(path, self.location.settingsFile.path)
        }
        try put("[1, 2]", .settings)
        XCTAssertThrowsError(try ClaudeConfigFile.read(.settings, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .notAnObject(path: self.location.settingsFile.path))
        }
    }

    func testExternalChangeIsRefusedAndKept() throws {
        try put(settingsFixture, .settings)
        var document = try ClaudeConfigFile.read(.settings, in: location)
        try PermissionRules(allow: ["Bash(ls)"]).apply(to: &document)

        // Claude Code writes the file meanwhile.
        try put(#"{"model": "sonnet"}"#, .settings)
        XCTAssertThrowsError(try ClaudeConfigFile.write(document, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .changedOnDisk(path: self.location.settingsFile.path))
        }
        XCTAssertEqual(try text(.settings), #"{"model": "sonnet"}"#)
    }

    func testFileCreatedMeanwhileIsRefused() throws {
        var document = try ClaudeConfigFile.read(.state, in: location)
        try McpServers.apply([McpServer(name: "a", command: "b")], to: &document)
        try put(#"{"numStartups": 1}"#, .state)
        XCTAssertThrowsError(try ClaudeConfigFile.write(document, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .changedOnDisk(path: self.location.stateFile.path))
        }
        XCTAssertEqual(try text(.state), #"{"numStartups": 1}"#)
    }

    func testSymlinkedFileIsRefused() throws {
        let elsewhere = temp.url.appendingPathComponent("real-settings.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: location.settingsFile, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ClaudeConfigFile.read(.settings, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .symlink(path: self.location.settingsFile.path))
        }
    }

    func testFileTurnedIntoASymlinkIsRefused() throws {
        try put("{}", .settings)
        var document = try ClaudeConfigFile.read(.settings, in: location)
        try PermissionRules(allow: ["Bash(ls)"]).apply(to: &document)
        let elsewhere = temp.url.appendingPathComponent("real-settings.json")
        try Data("{}".utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: location.settingsFile)
        try FileManager.default.createSymbolicLink(at: location.settingsFile, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try ClaudeConfigFile.write(document, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .symlink(path: self.location.settingsFile.path))
        }
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "{}", "the file behind the link is untouched")
    }

    func testSymlinkedFolderIsRefused() throws {
        let real = temp.url.appendingPathComponent("real-home", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let linked = temp.url.appendingPathComponent("homes/linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
        XCTAssertThrowsError(try ClaudeConfigFile.read(.settings, in: ClaudeConfigLocation(folder: linked))) {
            XCTAssertEqual($0 as? ClaudeConfigError, .symlink(path: linked.path))
        }
    }

    func testPathOutsideTheFolderIsRefused() throws {
        try put("{}", .settings)
        var document = try ClaudeConfigFile.read(.settings, in: location)
        try PermissionRules(allow: ["Bash(ls)"]).apply(to: &document)
        let outside = temp.url.appendingPathComponent("settings.json")
        let moved = ClaudeConfigDocument(url: outside, kind: .settings, original: nil, root: document.root)
        XCTAssertThrowsError(try ClaudeConfigFile.write(moved, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .outsideFolder(path: outside.path))
        }
        let sneaky = folder.appendingPathComponent("../settings.json")
        XCTAssertThrowsError(try ClaudeConfigFile.checkTarget(sneaky, in: folder)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .outsideFolder(path: sneaky.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testDefaultSetupIsNotEditable() throws {
        let paths = temp.paths()
        let location = ClaudeConfigLocation.of(.defaultClaude, paths: paths)
        XCTAssertFalse(location.isEditable)
        XCTAssertEqual(location.settingsFile, paths.defaultClaudeDir.appendingPathComponent("settings.json"))
        XCTAssertEqual(location.stateFile, paths.home.appendingPathComponent(".claude.json"))
        XCTAssertThrowsError(try ClaudeConfigFile.read(.settings, in: location)) {
            XCTAssertEqual($0 as? ClaudeConfigError, .notEditable(path: location.settingsFile.path))
        }
        let document = ClaudeConfigDocument(url: location.settingsFile, kind: .settings, original: nil, root: ["a": 1])
        XCTAssertThrowsError(try ClaudeConfigFile.write(document, in: location))

        let shared = ClaudeConfigLocation.of(.sample(isolate: false), paths: paths)
        XCTAssertFalse(shared.isEditable, "a profile that is not isolated uses the user's own files")

        let isolated = ClaudeConfigLocation.of(.sample(slug: "work", isolate: true), paths: paths)
        XCTAssertEqual(isolated.folder, paths.home(for: "work"))
        XCTAssertEqual(isolated.stateFile, paths.home(for: "work").appendingPathComponent(".claude.json"))
    }

    func testNoTemporaryFileIsLeftBehind() throws {
        try put(settingsFixture, .settings)
        var document = try ClaudeConfigFile.read(.settings, in: location)
        try PermissionRules(allow: ["Bash(ls)"]).apply(to: &document)
        let written = try ClaudeConfigFile.write(document, in: location)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["settings.json"])

        // The returned document is the new state on disk: a second save works.
        var again = written
        try PermissionRules(allow: ["Bash(pwd)"]).apply(to: &again)
        try ClaudeConfigFile.write(again, in: location)
        XCTAssertEqual((try object(.settings)["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(pwd)"])
    }

    // MARK: - Masking

    func testSecretsAreMasked() {
        XCTAssertTrue(SecretMask.looksSecret(key: "Authorization", value: "Bearer abc"))
        XCTAssertTrue(SecretMask.looksSecret(key: "GITHUB_TOKEN", value: "x"))
        XCTAssertTrue(SecretMask.looksSecret(key: "X-Api-Key", value: "abc"))
        XCTAssertTrue(SecretMask.looksSecret(key: "OTHER", value: "sk-ant-123"))
        XCTAssertFalse(SecretMask.looksSecret(key: "ROOT", value: "/tmp"))
        XCTAssertFalse(SecretMask.looksSecret(key: "API_KEY", value: "${API_KEY}"))
        XCTAssertFalse(SecretMask.looksSecret(key: "Authorization", value: "Bearer ${TOKEN}"))
        XCTAssertEqual(SecretMask.masked("sk-ant-0123456789"), "••••••••6789")
        XCTAssertEqual(SecretMask.masked("short"), "•••••")
    }
}
