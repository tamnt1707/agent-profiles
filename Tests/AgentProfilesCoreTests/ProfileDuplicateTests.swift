import XCTest
@testable import AgentProfilesCore

final class ProfileDuplicateTests: XCTestCase {
    private let english = "%@ copy"
    private let vietnamese = "%@ (bản sao)"

    private func make(
        _ source: Profile,
        existing: [Profile]? = nil,
        template: String? = nil,
        taken: Set<String> = []
    ) -> Profile {
        ProfileDuplicate.make(
            from: source,
            existing: existing ?? [source],
            nameTemplate: template ?? english,
            isTaken: { taken.contains($0) }
        )
    }

    func testTheCopyGetsACopyNameAndItsOwnSlug() {
        let source = Profile.sample(name: "Work", slug: "work")
        let copy = make(source)
        XCTAssertEqual(copy.name, "Work copy")
        XCTAssertEqual(copy.slug, "work-copy")
    }

    func testTheNameAndTheSlugAreMadeUniqueWithANumber() {
        let source = Profile.sample(name: "Work", slug: "work")
        let first = Profile.sample(name: "Work copy", slug: "work-copy")
        let second = Profile.sample(name: "Work copy 2", slug: "work-copy-2")

        let copy2 = make(source, existing: [source, first])
        XCTAssertEqual(copy2.name, "Work copy 2")
        XCTAssertEqual(copy2.slug, "work-copy-2")

        let copy3 = make(source, existing: [source, first, second])
        XCTAssertEqual(copy3.name, "Work copy 3")
        XCTAssertEqual(copy3.slug, "work-copy-3")
    }

    func testASlugTakenByAFileOnDiskIsSkipped() {
        let source = Profile.sample(name: "Work", slug: "work")
        let copy = make(source, taken: ["work-copy"])
        XCTAssertEqual(copy.name, "Work copy 2")
        XCTAssertEqual(copy.slug, "work-copy-2")
    }

    func testATakenSlugWithAnotherNameIsSkippedToo() {
        let source = Profile.sample(name: "Work", slug: "work")
        let other = Profile.sample(name: "Something else", slug: "work-copy")
        let copy = make(source, existing: [source, other])
        XCTAssertEqual(copy.slug, "work-copy-2")
    }

    func testAVietnameseNameKeepsItsDiacriticsAndTheSlugFoldsThem() {
        let source = Profile.sample(name: "Đường Dẫn", slug: "duong-dan")
        let copy = make(source, template: vietnamese)
        XCTAssertEqual(copy.name, "Đường Dẫn (bản sao)")
        XCTAssertEqual(copy.slug, "duong-dan-ban-sao")

        let again = make(source, existing: [source, copy], template: vietnamese)
        XCTAssertEqual(again.name, "Đường Dẫn (bản sao) 2")
        XCTAssertEqual(again.slug, "duong-dan-ban-sao-2")
    }

    func testEverySettingIsCopied() {
        var source = Profile.sample(name: "Work", slug: "work", auth: .apiKey)
        source.opusModel = "o"
        source.sonnetModel = "s"
        source.haikuModel = "h"
        source.workdir = "/Users/me/work"
        source.shareFromDefault = true
        source.priceInputPerMillion = 3
        source.priceOutputPerMillion = 15
        let copy = make(source)

        var expected = source
        expected.name = copy.name
        expected.slug = copy.slug
        XCTAssertEqual(copy, expected)
    }

    func testTheHeartbeatIsCopiedButOffAndTheRecentFoldersAreEmpty() {
        var source = Profile.sample(name: "Work", slug: "work")
        source.recentDirs = ["/Users/me/a", "/Users/me/b"]
        source.heartbeat = Heartbeat(enabled: true, times: [ClockTime(hour: 7, minute: 30)!], days: [1, 3])
        let copy = make(source)

        XCTAssertFalse(copy.heartbeat.enabled)
        XCTAssertEqual(copy.heartbeat.times, source.heartbeat.times)
        XCTAssertEqual(copy.heartbeat.days, [1, 3])
        XCTAssertEqual(copy.recentDirs, [])
        // The source is not touched.
        XCTAssertTrue(source.heartbeat.enabled)
        XCTAssertEqual(source.recentDirs.count, 2)
    }

    func testTheCopyOfTheDefaultSetupIsAnIsolatedNormalProfile() {
        let copy = make(Profile.defaultClaude, existing: [Profile.defaultClaude])
        XCTAssertEqual(copy.name, "Default copy")
        XCTAssertEqual(copy.slug, "default-copy")
        XCTAssertFalse(copy.isDefaultClaude)
        XCTAssertTrue(copy.isolate)
        XCTAssertTrue(Slug.isSafe(copy.slug))
    }

    // MARK: - The key

    func testATypedKeyWinsOverTheKeyOfTheSource() throws {
        let keys = InMemoryKeyStore()
        try keys.set("work", key: "source-key")
        XCTAssertEqual(
            ProfileDuplicate.keyToStore(typed: "  typed-key \n", sourceSlug: "work", keys: keys),
            "typed-key"
        )
    }

    func testTheKeyOfTheSourceIsUsedWhenNothingIsTyped() throws {
        let keys = InMemoryKeyStore()
        try keys.set("work", key: "source-key")
        XCTAssertEqual(ProfileDuplicate.keyToStore(typed: " ", sourceSlug: "work", keys: keys), "source-key")
        XCTAssertNil(ProfileDuplicate.keyToStore(typed: "", sourceSlug: "other", keys: keys))
        XCTAssertNil(ProfileDuplicate.keyToStore(typed: "", sourceSlug: nil, keys: keys))
    }

    func testTheKeyIsWrittenForTheNewSlugOnlyWhenTheCopyIsSaved() throws {
        let temp = try TempDirectory()
        let keys = InMemoryKeyStore()
        let store = Store(paths: temp.paths(), keys: keys, logins: RecordingLoginStore())
        let source = Profile.sample(name: "Work", slug: "work")
        try keys.set("work", key: "source-key")

        let copy = make(source)
        // Making the copy writes nothing: not a key, not a launcher, not a folder.
        XCTAssertEqual(keys.accounts, ["work"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.script(for: copy.slug).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.home(for: copy.slug).path))

        let key = ProfileDuplicate.keyToStore(typed: "", sourceSlug: source.slug, keys: keys)
        try store.saveProfile(copy, others: [source], previous: nil, key: key)

        XCTAssertEqual(try keys.get("work-copy"), "source-key")
        XCTAssertEqual(try keys.get("work"), "source-key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.script(for: copy.slug).path))
    }

    func testTheCopyIsRefusedWithoutAnyKeyWhenTheSourceHasNone() throws {
        let temp = try TempDirectory()
        let keys = InMemoryKeyStore()
        let store = Store(paths: temp.paths(), keys: keys, logins: RecordingLoginStore())
        let source = Profile.sample(name: "Work", slug: "work")
        let copy = make(source)

        let key = ProfileDuplicate.keyToStore(typed: "", sourceSlug: source.slug, keys: keys)
        XCTAssertThrowsError(try store.saveProfile(copy, others: [source], previous: nil, key: key))
        XCTAssertTrue(keys.accounts.isEmpty)
    }

    func testDiscardingTheCopyWritesNothing() throws {
        let temp = try TempDirectory()
        let keys = InMemoryKeyStore()
        let store = Store(paths: temp.paths(), keys: keys, logins: RecordingLoginStore())
        let source = Profile.sample(name: "Work", slug: "work")
        try keys.set("work", key: "source-key")

        _ = make(source)

        XCTAssertEqual(keys.accounts, ["work"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.binDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.homesDir.path))
    }
}
