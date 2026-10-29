import XCTest
@testable import AgentProfilesCore

/// The delete confirmation lists what the SAVED profile owns. A command name
/// typed in the editor but not saved yet must not leak into that list.
final class DeleteTargetTests: XCTestCase {
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

    func testItemsNameTheSavedProfile() {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in 42 })

        XCTAssertEqual(target?.name, "Work")
        XCTAssertEqual(target?.items, [
            .key(account: "work"),
            .command(name: "claude-work"),
            .folder(path: paths.home(for: "work").path, bytes: 42),
        ])
    }

    func testDraftSlugDoesNotChangeTheTarget() {
        // The editor shows "renamed" while the saved profile is still "work".
        // The target is built from the index of the saved profile only, so the
        // unsaved slug never appears in the list.
        let saved = Profile.sample(name: "Work", slug: "work")
        var draft = saved
        draft.slug = "renamed"
        draft.name = "Renamed"
        let data = AppData(profiles: [saved])

        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        let text = String(describing: target?.items ?? [])

        XCTAssertEqual(target?.name, "Work")
        XCTAssertTrue(text.contains("work"))
        XCTAssertFalse(text.contains("renamed"))
        XCTAssertEqual(target?.items.last, .folder(path: paths.home(for: "work").path, bytes: nil))
    }

    func testNoTargetWithoutSavedProfile() {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        XCTAssertNil(DeleteTarget(index: nil, in: data, paths: paths))
        XCTAssertNil(DeleteTarget(index: 3, in: data, paths: paths))
    }

    func testFolderSizeIsMeasuredFromTheSavedHome() throws {
        let home = paths.home(for: "work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: home.appendingPathComponent("history.txt"))
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])

        let target = DeleteTarget(index: 0, in: data, paths: paths)

        guard case .folder(_, let bytes)? = target?.items.last else {
            return XCTFail("the last item is the folder")
        }
        XCTAssertEqual(bytes, 1000)
    }
}
