import XCTest
@testable import AgentProfilesCore

final class JSONCompatibilityTests: XCTestCase {
    private var temp: TempDirectory!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = Store(paths: temp.paths(), keys: InMemoryKeyStore())
    }

    override func tearDown() {
        temp = nil
        store = nil
    }

    /// The fixture was written by the Rust implementation (serde_json).
    private func rustFixture() throws -> Data {
        try Data(contentsOf: Fixtures.url("rust-profiles", extension: "json"))
    }

    func testDecodesTheRustFixture() throws {
        let data = try JSONDecoder().decode(AppData.self, from: rustFixture())
        XCTAssertEqual(data.terminal, .iTerm)
        XCTAssertEqual(data.profiles.count, 2)

        let first = data.profiles[0]
        XCTAssertEqual(first.name, "Test")
        XCTAssertEqual(first.slug, "test")
        XCTAssertEqual(first.baseURL, "https://example.com/anthropic")
        XCTAssertEqual(first.auth, .bearer)
        XCTAssertEqual(first.model, "m-1")
        XCTAssertEqual(first.opusModel, "o")
        XCTAssertEqual(first.sonnetModel, "s")
        XCTAssertEqual(first.haikuModel, "h")
        XCTAssertEqual(first.extraEnv, "A=1")
        XCTAssertEqual(first.workdir, "/tmp")
        XCTAssertTrue(first.isolate)
        XCTAssertTrue(first.shareFromDefault)

        let second = data.profiles[1]
        XCTAssertEqual(second.name, "Second \"quoted\" / ünïcode")
        XCTAssertEqual(second.slug, "second")
        XCTAssertEqual(second.auth, .bearer)
        XCTAssertFalse(second.isolate)
        XCTAssertFalse(second.shareFromDefault)

        // The new fields default to "system" in files written by the old app.
        XCTAssertEqual(data.language, .system)
        XCTAssertEqual(data.appearance, .system)
    }

    func testUnknownKeysDoNotBreakDecoding() throws {
        let json = """
        {
          "terminal": "Terminal",
          "something_new": {"a": 1},
          "profiles": [
            {
              "name": "Test",
              "slug": "test",
              "unknown_profile_key": [1, 2, 3]
            }
          ]
        }
        """
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles.count, 1)
        XCTAssertEqual(data.profiles[0].name, "Test")
        XCTAssertEqual(data.profiles[0].slug, "test")
    }

    func testMissingFieldsFallBackToTheDefaults() throws {
        let json = #"{ "profiles": [ { "name": "Only a name" } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.terminal, .terminal)
        XCTAssertEqual(data.language, .system)
        XCTAssertEqual(data.appearance, .system)

        let profile = data.profiles[0]
        XCTAssertEqual(profile.name, "Only a name")
        XCTAssertEqual(profile.slug, "")
        XCTAssertEqual(profile.baseURL, "")
        XCTAssertEqual(profile.auth, .bearer)
        XCTAssertEqual(profile.model, "")
        XCTAssertEqual(profile.opusModel, "")
        XCTAssertEqual(profile.sonnetModel, "")
        XCTAssertEqual(profile.haikuModel, "")
        XCTAssertEqual(profile.extraEnv, "")
        XCTAssertEqual(profile.workdir, "")
        XCTAssertFalse(profile.isolate)
        XCTAssertFalse(profile.shareFromDefault)
    }

    func testUnknownEnumValuesFallBackToTheDefault() throws {
        let json = #"{ "terminal": "Alacritty", "profiles": [], "language": "fr", "appearance": "sepia" }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.terminal, .terminal)
        XCTAssertEqual(data.language, .system)
        XCTAssertEqual(data.appearance, .system)
    }

    func testEncodeDecodeRoundTrip() throws {
        let original = AppData(
            terminal: .iTerm,
            profiles: [
                Profile.sample(),
                Profile(
                    name: "Second \"quoted\" / ünïcode",
                    slug: "second",
                    baseURL: "http://localhost:4000",
                    auth: .none,
                    model: "m",
                    opusModel: "o",
                    sonnetModel: "s",
                    haikuModel: "h",
                    extraEnv: "A=1",
                    workdir: "/tmp",
                    isolate: true,
                    shareFromDefault: true
                ),
            ],
            language: .vi,
            appearance: .dark
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppData.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    /// The file we write must stay byte compatible with the Rust implementation.
    func testWrittenFileMatchesTheRustLayout() throws {
        let fixtureText = try String(contentsOf: Fixtures.url("rust-profiles", extension: "json"), encoding: .utf8)
        let data = try JSONDecoder().decode(AppData.self, from: Data(fixtureText.utf8))

        try store.save(data)
        let written = try String(contentsOf: store.paths.dataFile, encoding: .utf8)

        // The Rust file ends with the closing brace of the object, without a
        // trailing newline. The new keys are appended before it.
        let expected = fixtureText.replacingOccurrences(
            of: "  ]\n}",
            with: "  ],\n  \"language\": \"system\",\n  \"appearance\": \"system\",\n  \"auto_check_updates\": true\n}"
        )
        XCTAssertEqual(written, expected)

        // And the result is still valid JSON.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(written.utf8)))
    }

    func testWrittenFileUsesTheSameEscaping() throws {
        let data = AppData(profiles: [
            Profile(name: "tab\tnewline\nquote\"backslash\\", slug: "x"),
        ])
        try store.save(data)
        let written = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertTrue(written.contains("\"name\": \"tab\\tnewline\\nquote\\\"backslash\\\\\""))
    }

    func testEmptyDataFile() throws {
        try store.save(AppData())
        let written = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertEqual(written, """
        {
          "terminal": "Terminal",
          "profiles": [],
          "language": "system",
          "appearance": "system",
          "auto_check_updates": true
        }
        """)
    }

    /// The two update settings are new: an old file has to load without them.
    func testTheUpdateSettingsAreOptional() throws {
        let json = #"{ "profiles": [] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertTrue(data.autoCheckUpdates)
        XCTAssertNil(data.lastUpdateCheck)
    }

    func testTheUpdateSettingsAreReadAndWritten() throws {
        let when = Date(timeIntervalSince1970: 1_762_000_000)
        let data = AppData(autoCheckUpdates: false, lastUpdateCheck: when)
        try store.save(data)

        let written = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertTrue(written.contains("\"auto_check_updates\": false"))
        XCTAssertTrue(written.contains("\"last_update_check\": \"\(Timestamp.string(from: when))\""))

        let loaded = try JSONDecoder().decode(AppData.self, from: Data(written.utf8))
        XCTAssertFalse(loaded.autoCheckUpdates)
        XCTAssertEqual(loaded.lastUpdateCheck?.timeIntervalSince1970 ?? 0, when.timeIntervalSince1970, accuracy: 1)
    }

    func testABrokenTimestampIsIgnored() throws {
        let json = #"{ "profiles": [], "last_update_check": "yesterday" }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertNil(data.lastUpdateCheck)
        XCTAssertTrue(data.autoCheckUpdates)
    }
}
