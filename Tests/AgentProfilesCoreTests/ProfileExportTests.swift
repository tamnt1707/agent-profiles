import XCTest
@testable import AgentProfilesCore

/// The export file: what it holds, what it never holds, how strictly it is
/// read, how conflicts are planned and how an imported profile is saved.
final class ProfileExportTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var keys: InMemoryKeyStore!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        keys = InMemoryKeyStore()
        store = Store(paths: paths, keys: keys)
    }

    override func tearDown() {
        temp = nil
        paths = nil
        keys = nil
        store = nil
    }

    private let moment = Date(timeIntervalSince1970: 1_790_000_000)

    /// A profile with every field set to something that is not the default.
    private func fullProfile() -> Profile {
        Profile(
            name: "Công việc \"đặc biệt\"",
            slug: "cong-viec-dac-biet",
            baseURL: "https://api.example.com/anthropic",
            auth: .apiKey,
            model: "model-main",
            opusModel: "model-opus",
            sonnetModel: "model-sonnet",
            haikuModel: "model-haiku",
            extraEnv: "API_TIMEOUT_MS=600000\n# comment\tтаб",
            workdir: "/Users/someone/Projects/Dự án",
            isolate: true,
            shareFromDefault: true,
            recentDirs: ["/Users/someone/secret-folder", "/tmp/other"],
            priceInputPerMillion: 3.25,
            priceOutputPerMillion: 15,
            agent: .claude,
            heartbeat: Heartbeat(
                enabled: true,
                times: [ClockTime(hour: 6, minute: 0)!, ClockTime(hour: 11, minute: 30)!],
                days: [1, 3, 5]
            )
        )
    }

    // MARK: - Writing

    /// Every setting of every profile comes back, except the recent folders.
    func testEveryFieldSurvivesTheRoundTrip() throws {
        let original = fullProfile()
        let plain = Profile.sample(name: "Plain", slug: "plain", auth: .none)
        let text = ProfileExport.encode([original, plain], exportedAt: moment)
        let document = try ProfileExport.decode(Data(text.utf8))

        var expected = original
        expected.recentDirs = []
        XCTAssertEqual(document.profiles, [expected, plain])
        XCTAssertEqual(document.exportedAt, moment)
    }

    /// The header names the format, its version and the moment of the export.
    func testTheHeaderNamesTheFormatAndTheVersion() throws {
        let text = ProfileExport.encode([Profile.sample()], exportedAt: moment)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "agent-profiles-export")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["exported_at"] as? String, Timestamp.string(from: moment))
        XCTAssertEqual((object["profiles"] as? [Any])?.count, 1)
    }

    /// No key, ever: the Keychain holds one, the file does not. The recent
    /// folders stay on this Mac as well.
    func testTheFileHoldsNoKeyAndNoRecentFolders() throws {
        let profile = fullProfile()
        try keys.set(profile.slug, key: "sk-secret-value-123")
        let text = ProfileExport.encode([profile], exportedAt: moment)

        XCTAssertFalse(text.contains("sk-secret-value-123"))
        XCTAssertFalse(text.contains("recent_dirs"))
        XCTAssertFalse(text.contains("secret-folder"))
        XCTAssertFalse(text.contains("\"key\""))
        XCTAssertFalse(text.contains("api_key"))
        XCTAssertFalse(text.contains("token"))
        // Nothing of the app settings either.
        XCTAssertFalse(text.contains("\"terminal\""))
        XCTAssertFalse(text.contains("\"language\""))
        XCTAssertFalse(text.contains("default_heartbeat"))
    }

    /// The default setup lives in memory only and is never exported.
    func testTheDefaultSetupIsNotExported() throws {
        let text = ProfileExport.encode([.defaultClaude, Profile.sample()], exportedAt: moment)
        XCTAssertFalse(text.contains("\"\(Profile.defaultSlug)\""))
        XCTAssertEqual(try ProfileExport.decode(Data(text.utf8)).profiles.map(\.slug), ["test"])
    }

    /// An empty list is still a valid file.
    func testAnEmptyListIsAValidFile() throws {
        let text = ProfileExport.encode([], exportedAt: moment)
        XCTAssertEqual(try ProfileExport.decode(Data(text.utf8)).profiles, [])
    }

    /// The file is readable by the user only, and a second export replaces it.
    func testTheFileIsWrittenWithMode0600() throws {
        let target = temp.url.appendingPathComponent("agent-profiles.json")
        try ProfileExport.write("old", to: target)
        try ProfileExport.write(ProfileExport.encode([Profile.sample()], exportedAt: moment), to: target)

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try ProfileExport.read(from: target).profiles.map(\.slug), ["test"])
        // No temporary file is left next to it.
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".tmp") }, [])
    }

    /// A folder that does not exist is an error, not a crash.
    func testAWriteIntoAMissingFolderFails() {
        let target = temp.url.appendingPathComponent("missing/agent-profiles.json")
        XCTAssertThrowsError(try ProfileExport.write("{}", to: target)) { error in
            XCTAssertEqual(error as? ProfileExportError, .writeFailed(target.path))
        }
    }

    /// The suggested name carries the date on the clock of the Mac.
    func testTheDefaultFileNameCarriesTheDate() {
        let date = Date(timeIntervalSince1970: 1_762_819_200) // 2025-11-11T00:00:00Z
        XCTAssertEqual(
            ProfileExport.defaultFileName(for: date, timeZone: TimeZone(secondsFromGMT: 0)!),
            "agent-profiles-2025-11-11.json"
        )
        XCTAssertEqual(
            ProfileExport.defaultFileName(for: date, timeZone: TimeZone(secondsFromGMT: -3600)!),
            "agent-profiles-2025-11-10.json"
        )
    }

    // MARK: - Reading

    private func decode(_ text: String) throws -> ExportDocument {
        try ProfileExport.decode(Data(text.utf8))
    }

    private func assertRefused(_ text: String, _ expected: ProfileExportError, line: UInt = #line) {
        XCTAssertThrowsError(try decode(text), line: line) { error in
            XCTAssertEqual(error as? ProfileExportError, expected, line: line)
        }
    }

    func testGarbageIsRefused() {
        assertRefused("", .notAnExport)
        assertRefused("not json at all", .notAnExport)
        assertRefused("[1, 2, 3]", .notAnExport)
        assertRefused("\"agent-profiles-export\"", .notAnExport)
        XCTAssertThrowsError(try ProfileExport.decode(Data([0xFF, 0xFE, 0x00]))) { error in
            XCTAssertEqual(error as? ProfileExportError, .notAnExport)
        }
    }

    /// `profiles.json` itself, or any other JSON, is not an export.
    func testAnotherFormatIsRefused() {
        assertRefused(#"{"terminal": "Terminal", "profiles": []}"#, .notAnExport)
        assertRefused(#"{"format": "something-else", "version": 1, "profiles": []}"#, .notAnExport)
        assertRefused(#"{"format": 1, "version": 1, "profiles": []}"#, .notAnExport)
    }

    func testAnotherVersionIsRefused() {
        assertRefused(#"{"format": "agent-profiles-export", "version": 2, "profiles": []}"#, .unsupportedVersion("2"))
        assertRefused(#"{"format": "agent-profiles-export", "version": 0, "profiles": []}"#, .unsupportedVersion("0"))
        assertRefused(#"{"format": "agent-profiles-export", "profiles": []}"#, .unsupportedVersion("?"))
        assertRefused(#"{"format": "agent-profiles-export", "version": "1", "profiles": []}"#, .unsupportedVersion("?"))
        assertRefused(#"{"format": "agent-profiles-export", "version": 1.5, "profiles": []}"#, .unsupportedVersion("?"))
    }

    func testAMissingProfileListIsRefused() {
        assertRefused(#"{"format": "agent-profiles-export", "version": 1}"#, .notAnExport)
        assertRefused(#"{"format": "agent-profiles-export", "version": 1, "profiles": {}}"#, .notAnExport)
    }

    /// One profile that does not read refuses the whole file and names it.
    func testABrokenProfileRefusesTheWholeFile() {
        let header = #"{"format": "agent-profiles-export", "version": 1, "profiles": ["#
        let good = #"{"name": "A", "slug": "a"}"#
        let broken = [
            #"{"slug": "b"}"#,                                   // no name
            #"{"name": "  ", "slug": "b"}"#,                     // empty name
            #"{"name": "B"}"#,                                   // no slug
            #"{"name": "B", "slug": "../b"}"#,                   // unsafe slug
            #"{"name": "B", "slug": "B b"}"#,                    // not a slug
            #"{"name": "B", "slug": "_default"}"#,               // the default setup
            #"{"name": "B", "slug": "b", "auth": "Password"}"#,  // unknown auth
            #"{"name": "B", "slug": "b", "isolate": "yes"}"#,    // wrong type
            #"{"name": "B", "slug": "b", "price_input_per_million": -1}"#,
            #"{"name": "B", "slug": "b", "agent": "codex"}"#,
            #"{"name": "B", "slug": "b", "heartbeat": {"enabled": true, "times": ["25:00"]}}"#,
            #"{"name": "B", "slug": "b", "heartbeat": {"enabled": true, "times": [], "days": [8]}}"#,
            #""just text""#,
        ]
        for entry in broken {
            assertRefused(header + good + ", " + entry + "]}", .invalidProfile(2))
        }
    }

    /// Two profiles of one command in one file are refused.
    func testDuplicateCommandsInTheFileAreRefused() {
        let text = #"{"format": "agent-profiles-export", "version": 1, "profiles": [{"name": "A", "slug": "a"}, {"name": "B", "slug": "a"}]}"#
        assertRefused(text, .duplicateProfile("a"))
    }

    /// Keys the format does not know are ignored; recent folders and keys in
    /// a hand edited file are never read.
    func testUnknownKeysAndRecentFoldersAreIgnored() throws {
        let text = """
        {"format": "agent-profiles-export", "version": 1, "future": true, "profiles": [
          {"name": "A", "slug": "a", "recent_dirs": ["/x"], "key": "sk-1", "something": 1}
        ]}
        """
        let document = try decode(text)
        XCTAssertEqual(document.profiles, [Profile(name: "A", slug: "a")])
        XCTAssertNil(document.exportedAt)
    }

    func testAFileThatIsTooLargeIsRefused() {
        let bytes = Data(repeating: 0x20, count: ProfileExport.maxFileSize + 1)
        XCTAssertThrowsError(try ProfileExport.decode(bytes)) { error in
            XCTAssertEqual(error as? ProfileExportError, .fileTooLarge)
        }
    }

    // MARK: - Planning

    func testNewNameAndCommandConflictsAreTold() {
        let existing = [Profile.defaultClaude, Profile.sample(name: "Work", slug: "work")]
        let imported = [
            Profile.sample(name: "Fresh", slug: "fresh"),
            Profile.sample(name: " work ", slug: "job"),
            Profile.sample(name: "Job", slug: "work"),
            Profile.sample(name: "WORK", slug: "work"),
            Profile.sample(name: "On disk", slug: "on-disk"),
        ]
        let candidates = ImportPlanner.candidates(for: imported, existing: existing) { $0 == "on-disk" }
        XCTAssertEqual(candidates.map(\.status), [.new, .nameExists, .commandExists, .nameAndCommandExist, .commandExists])
        XCTAssertEqual(candidates.map(\.id), [0, 1, 2, 3, 4])
    }

    /// A conflict is skipped unless a copy is chosen; nothing is overwritten.
    func testAConflictIsSkippedByDefault() {
        let existing = [Profile.sample(name: "Work", slug: "work")]
        let imported = [Profile.sample(name: "Work", slug: "work"), Profile.sample(name: "Other", slug: "other")]
        let candidates = ImportPlanner.candidates(for: imported, existing: existing)
        let actions = ImportPlanner.actions(for: candidates, choices: [:], existing: existing)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0], .skip)
        guard case .create(let other) = actions[1] else { return XCTFail("not created") }
        XCTAssertEqual(other.slug, "other")
    }

    /// A copy gets the first name and command that nothing uses.
    func testACopyGetsAFreeNameAndCommand() {
        let existing = [
            Profile.sample(name: "Work", slug: "work"),
            Profile.sample(name: "Work (2)", slug: "something"),
        ]
        let imported = [
            Profile.sample(name: "Work", slug: "work"),
            Profile.sample(name: "Work", slug: "work-b"),
            Profile.sample(name: "Lab", slug: "lab"),
        ]
        let candidates = ImportPlanner.candidates(for: imported, existing: existing) { $0 == "work-3" || $0 == "lab" }
        let actions = ImportPlanner.actions(
            for: candidates,
            choices: [0: .importAsCopy, 1: .importAsCopy, 2: .importAsCopy],
            existing: existing
        ) { $0 == "work-3" || $0 == "lab" }
        let created = actions.compactMap { action -> Profile? in
            if case .create(let profile) = action { return profile }
            return nil
        }
        // "Work (2)" exists and claude-work-3 is a file on disk.
        XCTAssertEqual(created.map(\.name), ["Work (4)", "Work (3)", "Lab (2)"])
        XCTAssertEqual(created.map(\.slug), ["work-4", "work-b-3", "lab-2"])
    }

    /// A copy never takes the name of another profile of the same file.
    func testACopyDoesNotTakeTheNameOfAnotherImportedProfile() {
        let existing = [Profile.sample(name: "Work", slug: "work")]
        let imported = [
            Profile.sample(name: "Work", slug: "work"),
            Profile.sample(name: "Work (2)", slug: "work-2"),
        ]
        let candidates = ImportPlanner.candidates(for: imported, existing: existing)
        XCTAssertEqual(candidates.map(\.status), [.nameAndCommandExist, .new])
        let actions = ImportPlanner.actions(for: candidates, choices: [0: .importAsCopy], existing: existing)
        guard case .create(let copy) = actions[0], case .create(let second) = actions[1] else {
            return XCTFail("both should be created")
        }
        XCTAssertEqual(copy.name, "Work (3)")
        XCTAssertEqual(copy.slug, "work-3")
        XCTAssertEqual(second.name, "Work (2)")
    }

    /// Vietnamese names keep their letters; the command stays ASCII.
    func testVietnameseNamesAreCopiedWithTheirLetters() {
        let existing = [Profile.sample(name: "Công việc", slug: "cong-viec")]
        let imported = [Profile.sample(name: "CÔNG VIỆC", slug: "cong-viec")]
        let candidates = ImportPlanner.candidates(for: imported, existing: existing)
        XCTAssertEqual(candidates.map(\.status), [.nameAndCommandExist])
        let actions = ImportPlanner.actions(for: candidates, choices: [0: .importAsCopy], existing: existing)
        guard case .create(let copy) = actions[0] else { return XCTFail("not created") }
        XCTAssertEqual(copy.name, "CÔNG VIỆC (2)")
        XCTAssertEqual(copy.slug, "cong-viec-2")
        XCTAssertTrue(Slug.isSafe(copy.slug))
    }

    /// An imported schedule is kept but off, and no recent folder comes along.
    func testAnImportedProfileHasItsHeartbeatOff() {
        let candidates = ImportPlanner.candidates(for: [fullProfile()], existing: [])
        let actions = ImportPlanner.actions(for: candidates, choices: [:], existing: [])
        guard case .create(let profile) = actions[0] else { return XCTFail("not created") }
        XCTAssertFalse(profile.heartbeat.enabled)
        XCTAssertEqual(profile.heartbeat.times, fullProfile().heartbeat.times)
        XCTAssertEqual(profile.heartbeat.days, [1, 3, 5])
        XCTAssertEqual(profile.recentDirs, [])
    }

    // MARK: - Saving

    /// A profile that needs a key is saved without one: the launcher and the
    /// folder exist, the Keychain is untouched and the health says "no key".
    func testAnImportedProfileIsSavedWithoutAKey() throws {
        let profile = Profile.sample(name: "Imported", slug: "imported", auth: .bearer)
        XCTAssertThrowsError(try store.saveProfile(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .missingAPIKey)
        }
        try store.saveImportedProfile(profile, others: [])

        XCTAssertTrue(ScriptRenderer.isManagedLauncher(at: paths.script(for: "imported")))
        XCTAssertEqual(SafeFileSystem.kind(of: paths.home(for: "imported")), .directory)
        XCTAssertEqual(keys.accounts, [])
        let health = ProfileHealth.evaluate(profile: profile, key: .missing, lastTest: nil, now: moment)
        XCTAssertEqual(health.reason, .noKeyStored)
    }

    /// An existing config folder (the login and the history of another
    /// profile) is never adopted, and an existing launcher is never replaced.
    func testAnImportedProfileNeverAdoptsFilesOnDisk() throws {
        let home = paths.home(for: "taken")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertTrue(store.isCommandTakenOnDisk("taken"))
        XCTAssertThrowsError(try store.saveImportedProfile(Profile.sample(name: "T", slug: "taken"), others: [])) { error in
            XCTAssertEqual(error as? StoreError, .targetHomeExists(home.path))
        }
        XCTAssertEqual(SafeFileSystem.kind(of: paths.script(for: "taken")), .missing)

        try store.saveImportedProfile(Profile.sample(name: "Once", slug: "once"), others: [])
        XCTAssertTrue(store.isCommandTakenOnDisk("once"))
        XCTAssertThrowsError(try store.saveImportedProfile(Profile.sample(name: "Twice", slug: "once"), others: []))
        XCTAssertFalse(store.isCommandTakenOnDisk("free"))
    }

    /// The usual checks still apply, and nothing is left behind.
    func testAnInvalidImportedProfileLeavesNothing() {
        var profile = Profile.sample(name: "Bad", slug: "bad")
        profile.baseURL = "ftp://nope"
        XCTAssertThrowsError(try store.saveImportedProfile(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .invalidBaseURL)
        }
        XCTAssertFalse(store.isCommandTakenOnDisk("bad"))
        XCTAssertThrowsError(try store.saveImportedProfile(Profile.sample(name: "Dup", slug: "dup"),
                                                           others: [Profile.sample(name: "X", slug: "dup")]))
    }

    /// While `profiles.json` is unread nothing is imported.
    func testNothingIsImportedWhileTheFileIsUnread() throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: paths.dataFile)
        _ = store.load()
        XCTAssertTrue(store.loadFailed)
        XCTAssertThrowsError(try store.saveImportedProfile(Profile.sample(), others: [])) { error in
            XCTAssertEqual(error as? StoreError, .dataFileNotLoaded(paths.dataFile.path))
        }
        XCTAssertFalse(store.isCommandTakenOnDisk("test"))
    }
}
