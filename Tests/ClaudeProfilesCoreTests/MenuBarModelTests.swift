import XCTest
@testable import ClaudeProfilesCore

final class MenuBarModelTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths(home: URL(fileURLWithPath: "/Users/me", isDirectory: true))
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    private func entries(
        _ profiles: [Profile],
        keys: Set<String> = [],
        exists: Set<String> = [],
        error: String? = nil
    ) -> [MenuBarModel.Entry] {
        MenuBarModel.entries(
            profiles: profiles,
            paths: paths,
            hasKey: { keys.contains($0) },
            folderExists: { exists.contains($0) },
            lastError: error
        )
    }

    private func profileEntry(_ entries: [MenuBarModel.Entry], at index: Int = 0) -> MenuBarModel.ProfileEntry? {
        guard index < entries.count, case .profile(let entry) = entries[index] else { return nil }
        return entry
    }

    // MARK: - Profile rows

    func testAProfileWithAKeyIsEnabledAndNamesItsCommand() {
        let entry = profileEntry(entries([Profile.sample(name: "Work", slug: "work")], keys: ["work"]))
        XCTAssertEqual(entry?.name, "Work")
        XCTAssertEqual(entry?.command, "claude-work")
        XCTAssertNil(entry?.hint)
        XCTAssertEqual(entry?.isEnabled, true)
    }

    /// A profile that needs a key but has none stored is disabled with the "no key" hint.
    func testAProfileThatNeedsAKeyWithoutOneIsDisabledWithTheNoKeyHint() {
        let entry = profileEntry(entries([Profile.sample(name: "Work", slug: "work", auth: .bearer)]))
        XCTAssertEqual(entry?.hint, .noKey)
        XCTAssertEqual(entry?.isEnabled, false)
    }

    func testTheApiKeyAuthAlsoNeedsAKey() {
        let entry = profileEntry(entries([Profile.sample(slug: "api", auth: .apiKey)]))
        XCTAssertEqual(entry?.hint, .noKey)
    }

    /// A profile with no credential at all (a local proxy) never needs a key.
    func testAProfileWithoutAuthNeverNeedsAKey() {
        let entry = profileEntry(entries([Profile.sample(slug: "proxy", auth: .none)]))
        XCTAssertNil(entry?.hint)
        XCTAssertEqual(entry?.isEnabled, true)
    }

    /// The key of one profile does not enable another one that has none.
    func testTheKeyCheckIsDonePerProfile() {
        let result = entries(
            [Profile.sample(name: "A", slug: "a"), Profile.sample(name: "B", slug: "b")],
            keys: ["a"]
        )
        XCTAssertEqual(profileEntry(result, at: 0)?.isEnabled, true)
        XCTAssertEqual(profileEntry(result, at: 1)?.hint, .noKey)
    }

    func testTheOrderOfTheProfilesIsKept() {
        let result = entries(
            [Profile.sample(name: "Zeta", slug: "zeta"), Profile.sample(name: "Alpha", slug: "alpha")],
            keys: ["zeta", "alpha"]
        )
        XCTAssertEqual(result.compactMap { if case .profile(let e) = $0 { return e.name } else { return nil } }, ["Zeta", "Alpha"])
    }

    // MARK: - Empty list and last error

    func testWithNoProfilesTheMenuShowsOnlyTheNoProfilesItem() {
        XCTAssertEqual(entries([]), [.noProfiles])
    }

    func testTheLastErrorIsShownAfterTheProfiles() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"], error: "Could not open Terminal")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.last, .lastError("Could not open Terminal"))
    }

    func testWithNoProfilesTheErrorFollowsTheNoProfilesItem() {
        XCTAssertEqual(entries([], error: "boom"), [.noProfiles, .lastError("boom")])
    }

    func testWithoutAnErrorNoErrorItemIsShown() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"], error: nil)
        XCTAssertFalse(result.contains { if case .lastError = $0 { return true } else { return false } })
    }

    // MARK: - Recent folders

    func testRecentFoldersShownAreTheExistingOnesInOrder() {
        var profile = Profile.sample(slug: "a")
        profile.recentDirs = ["/Users/me/one", "/gone", "/Users/me/two"]
        let entry = profileEntry(entries([profile], keys: ["a"], exists: ["/Users/me/one", "/Users/me/two"]))
        XCTAssertEqual(entry?.recentFolders.map(\.path), ["/Users/me/one", "/Users/me/two"])
    }

    func testAMissingRecentFolderIsDroppedWhenTheMenuIsBuilt() {
        var profile = Profile.sample(slug: "a")
        profile.recentDirs = ["/gone"]
        let entry = profileEntry(entries([profile], keys: ["a"], exists: []))
        XCTAssertEqual(entry?.recentFolders, [])
    }

    func testRecentFoldersAreShownWithTheHomeFolderAsTilde() {
        var profile = Profile.sample(slug: "a")
        profile.recentDirs = ["/Users/me/code", "/opt/elsewhere"]
        let entry = profileEntry(entries([profile], keys: ["a"], exists: ["/Users/me/code", "/opt/elsewhere"]))
        XCTAssertEqual(entry?.recentFolders.map(\.display), ["~/code", "/opt/elsewhere"])
    }

    func testAProfileWithoutRecentFoldersHasNone() {
        let entry = profileEntry(entries([Profile.sample(slug: "a")], keys: ["a"]))
        XCTAssertEqual(entry?.recentFolders, [])
    }

    /// A disabled profile still lists what it remembers; only its submenu is disabled in the view.
    func testADisabledProfileKeepsItsRecentFolders() {
        var profile = Profile.sample(slug: "a", auth: .bearer)
        profile.recentDirs = ["/Users/me/code"]
        let entry = profileEntry(entries([profile], exists: ["/Users/me/code"]))
        XCTAssertEqual(entry?.isEnabled, false)
        XCTAssertEqual(entry?.recentFolders.map(\.path), ["/Users/me/code"])
    }
}
