import XCTest
@testable import AgentProfilesCore

/// The two optional fields of `profiles.json` added for the menu bar launcher:
/// `recent_dirs` on a profile and `show_menu_bar` on the settings.
final class RecentDirsAndMenuBarSettingTests: XCTestCase {
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

    private func writtenText() throws -> String {
        try String(contentsOf: store.paths.dataFile, encoding: .utf8)
    }

    // MARK: - recent_dirs

    func testAProfileWithoutRecentDirsDecodesWithAnEmptyList() throws {
        let json = #"{ "profiles": [ { "name": "Old", "slug": "old", "workdir": "/tmp" } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles[0].recentDirs, [])
    }

    /// A malformed list is a convenience loss, not a broken profile list.
    func testAMalformedRecentDirsDecodesAsEmptyAndKeepsTheProfile() throws {
        let json = #"{ "profiles": [ { "name": "Odd", "slug": "odd", "recent_dirs": 42 } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles.count, 1)
        XCTAssertEqual(data.profiles[0].recentDirs, [])
    }

    func testRecentDirsRoundTripThroughCodable() throws {
        var profile = Profile.sample()
        profile.recentDirs = ["/a b", "/c \"quoted\""]
        let encoded = try JSONEncoder().encode(AppData(profiles: [profile]))
        let decoded = try JSONDecoder().decode(AppData.self, from: encoded)
        XCTAssertEqual(decoded.profiles[0].recentDirs, ["/a b", "/c \"quoted\""])
    }

    func testRecentDirsAreWrittenAndReadBackByTheStore() throws {
        var profile = Profile.sample()
        profile.recentDirs = ["/Users/me/one", "/Users/me/two"]
        try store.save(AppData(profiles: [profile]))

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data.profiles[0].recentDirs, ["/Users/me/one", "/Users/me/two"])
    }

    func testRecentDirsAreWrittenAsAMultiLineArray() throws {
        var profile = Profile.sample()
        profile.recentDirs = ["/one", "/two"]
        try store.save(AppData(profiles: [profile]))

        let text = try writtenText()
        XCTAssertTrue(text.contains("""
              "share_from_default": false,
              "recent_dirs": [
                "/one",
                "/two"
              ]
            }
        """), text)
    }

    /// An empty list is not written, so a file that never had one stays byte identical.
    func testAnEmptyRecentDirsListIsNotWritten() throws {
        try store.save(AppData(profiles: [Profile.sample()]))
        let text = try writtenText()
        XCTAssertFalse(text.contains("recent_dirs"), text)
        XCTAssertTrue(text.contains("\"share_from_default\": false\n    }"), text)
    }

    func testAFileWithoutRecentDirsSavesAndLoadsUnchanged() throws {
        try store.save(AppData(profiles: [Profile.sample()]))
        let first = try writtenText()
        let loaded = store.load()
        try store.save(loaded.data)
        XCTAssertEqual(try writtenText(), first)
    }

    // MARK: - The list is normalized while it is read

    /// A relative path is not a folder the launcher could open, so it is dropped.
    func testARelativeRecentDirIsDroppedWhileItIsRead() throws {
        let json = #"{ "profiles": [ { "name": "Old", "slug": "old", "recent_dirs": ["relative", "/keep"] } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles[0].recentDirs, ["/keep"])
    }

    /// A folder with a control character is dropped while it is read.
    func testAUnsafeRecentDirIsDroppedWhileItIsRead() throws {
        let json = #"{ "profiles": [ { "name": "Old", "slug": "old", "recent_dirs": ["/tmp/a\u0001b", "/keep"] } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles[0].recentDirs, ["/keep"])
    }

    /// Two spellings of one folder are one entry.
    func testDuplicatesAreDroppedWhileItIsRead() throws {
        let json = #"{ "profiles": [ { "name": "Old", "slug": "old", "recent_dirs": ["/a", "/b/", "/a/"] } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles[0].recentDirs, ["/a", "/b"])
    }

    /// A hand edited file cannot keep an endless list in memory.
    func testAHandEditedLongListIsCutWhileItIsRead() throws {
        let many = (1...50).map { "\"/folder/\($0)\"" }.joined(separator: ",")
        let json = "{ \"profiles\": [ { \"name\": \"Old\", \"slug\": \"old\", \"recent_dirs\": [\(many)] } ] }"
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles[0].recentDirs.count, 5)
        XCTAssertEqual(data.profiles[0].recentDirs.first, "/folder/1")
    }

    /// A list the app wrote is saved again exactly as it was.
    func testAValidListSavesByteIdentical() throws {
        var profile = Profile.sample()
        profile.recentDirs = ["/Users/me/one", "/Users/me/two", "/opt/elsewhere"]
        try store.save(AppData(profiles: [profile]))
        let first = try writtenText()
        let loaded = store.load()
        XCTAssertEqual(loaded.data.profiles[0].recentDirs, ["/Users/me/one", "/Users/me/two", "/opt/elsewhere"])
        try store.save(loaded.data)
        XCTAssertEqual(try writtenText(), first)
    }

    // MARK: - show_menu_bar

    func testShowMenuBarDefaultsToTrueWhenTheFileSaysNothing() throws {
        let json = #"{ "terminal": "Terminal", "profiles": [] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertTrue(data.showMenuBar)
        XCTAssertTrue(AppData().showMenuBar)
    }

    func testAMalformedShowMenuBarFallsBackToTrue() throws {
        let json = #"{ "profiles": [], "show_menu_bar": "maybe" }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertTrue(data.showMenuBar)
    }

    func testShowMenuBarOffIsWrittenAndReadBack() throws {
        try store.save(AppData(showMenuBar: false))
        let text = try writtenText()
        XCTAssertTrue(text.contains("\"show_menu_bar\": false"), text)

        let loaded = store.load()
        XCTAssertFalse(loaded.data.showMenuBar)
    }

    /// The default is not written, so a file that never changed the setting stays as it was.
    func testShowMenuBarOnIsNotWritten() throws {
        try store.save(AppData(showMenuBar: true))
        XCTAssertFalse(try writtenText().contains("show_menu_bar"))
    }

    func testShowMenuBarRoundTripThroughCodable() throws {
        let encoded = try JSONEncoder().encode(AppData(showMenuBar: false))
        XCTAssertFalse(try JSONDecoder().decode(AppData.self, from: encoded).showMenuBar)
        let encodedOn = try JSONEncoder().encode(AppData(showMenuBar: true))
        XCTAssertTrue(try JSONDecoder().decode(AppData.self, from: encodedOn).showMenuBar)
    }

    /// A broken file keeps its settings: the menu bar choice survives the backup path too.
    func testShowMenuBarIsKeptWhenTheProfileListCannotBeRead() {
        let bytes = Data(#"{ "show_menu_bar": false, "profiles": [ { "name": "x", "slug": "../bad" } ] }"#.utf8)
        XCTAssertFalse(AppData.settingsOnly(from: bytes).showMenuBar)
    }
}
