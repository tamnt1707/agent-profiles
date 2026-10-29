import XCTest
@testable import AgentProfilesCore

/// The "Don't ask again" flag of the PATH setup, kept in `profiles.json`.
final class PathPromptDeclinedTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        store = Store(paths: paths, keys: InMemoryKeyStore())
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        temp = nil
        paths = nil
        store = nil
    }

    private func writeDataFile(_ text: String) throws {
        try Data(text.utf8).write(to: paths.dataFile)
    }

    func testDeclinedFlagRoundTripsAndIsWrittenOnlyWhenSet() throws {
        try store.save(AppData(pathPromptDeclined: true))
        let written = try String(contentsOf: paths.dataFile, encoding: .utf8)
        XCTAssertTrue(written.contains("\"path_prompt_declined\": true"))
        XCTAssertTrue(store.load().data.pathPromptDeclined)

        try store.save(AppData())
        let cleared = try String(contentsOf: paths.dataFile, encoding: .utf8)
        XCTAssertFalse(cleared.contains("path_prompt_declined"), "a file the app did not need the key in stays as before")
        XCTAssertFalse(store.load().data.pathPromptDeclined)
    }

    func testAProfilesFileWithoutTheKeyStillLoads() throws {
        try writeDataFile(#"{"profiles": []}"#)

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertFalse(loaded.data.pathPromptDeclined)
    }

    func testACorruptFileKeepsTheDeclinedFlagAndIsBackedUp() throws {
        // One malformed profile makes the whole file unreadable; its settings are still read.
        try writeDataFile(#"{"path_prompt_declined": true, "profiles": [{"name": 5}]}"#)

        let loaded = store.load()
        guard case .corruptFileBackedUp(_)? = loaded.warning else {
            return XCTFail("expected a backup warning, got \(String(describing: loaded.warning))")
        }
        XCTAssertTrue(loaded.data.pathPromptDeclined)
        XCTAssertTrue(loaded.data.profiles.isEmpty)
    }
}
