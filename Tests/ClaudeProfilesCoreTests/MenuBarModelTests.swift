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
        unknown: Set<String> = [],
        folders: [String: [String]] = [:],
        error: String? = nil
    ) -> [MenuBarModel.Entry] {
        MenuBarModel.entries(
            profiles: profiles,
            paths: paths,
            keyPresence: { slug in
                // A Keychain that could not be read is not "no key".
                if unknown.contains(slug) { return .unreadable }
                return keys.contains(slug) ? .stored : .missing
            },
            recentFolders: folders,
            folderTitle: "Open in a folder…",
            lastError: error
        )
    }

    private func profileEntry(_ entries: [MenuBarModel.Entry], at index: Int = 0) -> MenuBarModel.ProfileEntry? {
        guard index < entries.count, case .profile(let entry) = entries[index] else { return nil }
        return entry
    }

    private func folderMenu(_ entries: [MenuBarModel.Entry]) -> MenuBarModel.FolderMenu? {
        for entry in entries {
            if case .openInFolder(let menu) = entry { return menu }
        }
        return nil
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

    /// A Keychain that could not be read is not "no key": the profile stays
    /// enabled and gets no hint.
    func testAProfileWhoseKeychainFailedIsEnabledWithoutTheNoKeyHint() {
        let result = entries([Profile.sample(name: "A", slug: "a")], unknown: ["a"])
        XCTAssertEqual(profileEntry(result)?.hint, nil)
        XCTAssertEqual(profileEntry(result)?.isEnabled, true)
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

    /// With no profile there is no submenu to open a folder in.
    func testWithNoProfilesThereIsNoFolderSubmenu() {
        XCTAssertNil(folderMenu(entries([])))
    }

    func testTheLastErrorIsShownAfterTheProfiles() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"], error: "Could not open Terminal")
        XCTAssertEqual(result.last, .lastError("Could not open Terminal"))
    }

    func testWithNoProfilesTheErrorFollowsTheNoProfilesItem() {
        XCTAssertEqual(entries([], error: "boom"), [.noProfiles, .lastError("boom")])
    }

    func testWithoutAnErrorNoErrorItemIsShown() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"], error: nil)
        XCTAssertFalse(result.contains { if case .lastError = $0 { return true } else { return false } })
    }

    // MARK: - The one click entry

    /// Every profile is a top level entry of its own: it is opened with one
    /// click, in the folder of the profile.
    func testEveryProfileIsATopLevelEntry() {
        let result = entries([
            Profile.sample(name: "A", slug: "a"),
            Profile.sample(name: "B", slug: "b"),
        ], keys: ["a", "b"])
        XCTAssertEqual(result.filter { if case .profile = $0 { return true } else { return false } }.count, 2)
    }

    /// The one click entry does not carry the recent folders: they belong to
    /// the submenu.
    func testTheOneClickEntryHasNoRecentFolders() {
        let entry = profileEntry(entries([Profile.sample(slug: "a")], keys: ["a"],
                                          folders: ["a": ["/Users/me/code"]]))
        XCTAssertEqual(entry?.recentFolders, [])
    }

    // MARK: - The folder submenu

    /// There is one submenu that lists every profile.
    func testThereIsOneSubmenuWithEveryProfile() {
        let result = entries([
            Profile.sample(name: "A", slug: "a"),
            Profile.sample(name: "B", slug: "b"),
        ], keys: ["a", "b"])
        let menu = folderMenu(result)
        XCTAssertEqual(menu?.title, "Open in a folder…")
        XCTAssertEqual(menu?.profiles.map(\.name), ["A", "B"])
        XCTAssertEqual(menu?.profiles.map(\.slug), ["a", "b"])
    }

    /// The submenu comes after the profiles, and the error after the submenu.
    func testTheOrderOfTheMenuIsProfilesSubmenuError() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"], error: "boom")
        XCTAssertEqual(result.count, 3)
        if case .profile = result[0] {} else { XCTFail("the profile is not first") }
        if case .openInFolder = result[1] {} else { XCTFail("the submenu is not second") }
        XCTAssertEqual(result[2], .lastError("boom"))
    }

    /// A profile that needs a key but has none is disabled in the submenu too.
    func testADisabledProfileIsAlsoDisabledInTheSubmenu() {
        let result = entries([Profile.sample(slug: "a", auth: .bearer)])
        XCTAssertEqual(folderMenu(result)?.profiles.first?.isEnabled, false)
        XCTAssertEqual(folderMenu(result)?.profiles.first?.hint, .noKey)
    }

    // MARK: - Recent folders

    func testRecentFoldersShownAreTheExistingOnesInOrder() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"],
                             folders: ["a": ["/Users/me/one", "/Users/me/two"]])
        XCTAssertEqual(folderMenu(result)?.profiles.first?.recentFolders.map(\.path),
                       ["/Users/me/one", "/Users/me/two"])
    }

    func testAMissingRecentFolderIsDroppedWhenTheMenuIsBuilt() {
        let result = MenuBarModel.entries(
            profiles: [Profile.sample(slug: "a")],
            paths: paths,
            keyPresence: { _ in .stored },
            recentFolders: ["a": ["/gone"]],
            folderTitle: "Open in a folder…",
            lastError: nil
        )
        // The folders that are gone are left out before the menu is built.
        let existing = MenuBarModel.existingFolders(
            profiles: [Profile.sample(slug: "a")],
            folderExists: { _ in false }
        )
        XCTAssertEqual(existing["a"], [])
        XCTAssertNotNil(result)
    }

    func testRecentFoldersAreShownWithTheHomeFolderAsTilde() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"],
                             folders: ["a": ["/Users/me/code", "/opt/elsewhere"]])
        XCTAssertEqual(folderMenu(result)?.profiles.first?.recentFolders.map(\.display),
                       ["~/code", "/opt/elsewhere"])
    }

    func testAProfileWithoutRecentFoldersHasNone() {
        let result = entries([Profile.sample(slug: "a")], keys: ["a"])
        XCTAssertEqual(folderMenu(result)?.profiles.first?.recentFolders, [])
    }

    /// A disabled profile still lists what it remembers; only its entry is
    /// disabled in the view.
    func testADisabledProfileKeepsItsRecentFolders() {
        let result = entries([Profile.sample(slug: "a", auth: .bearer)],
                             folders: ["a": ["/Users/me/code"]])
        XCTAssertEqual(folderMenu(result)?.profiles.first?.isEnabled, false)
        XCTAssertEqual(folderMenu(result)?.profiles.first?.recentFolders.map(\.path), ["/Users/me/code"])
    }

    // MARK: - The folders that still exist

    /// The folders that are gone are left out, the order stays.
    func testTheExistingFoldersAreTheOnesThatStillExist() {
        var profile = Profile.sample(slug: "a")
        profile.recentDirs = ["/Users/me/one", "/gone", "/Users/me/two"]
        let existing = MenuBarModel.existingFolders(
            profiles: [profile],
            folderExists: { $0 == "/Users/me/one" || $0 == "/Users/me/two" }
        )
        XCTAssertEqual(existing["a"], ["/Users/me/one", "/Users/me/two"])
    }

    /// A profile without folders gets an empty list, not nothing.
    func testEveryProfileHasAnEntryInTheExistingFolders() {
        let existing = MenuBarModel.existingFolders(
            profiles: [Profile.sample(slug: "a"), Profile.sample(slug: "b")],
            folderExists: { _ in true }
        )
        XCTAssertEqual(existing.keys.sorted(), ["a", "b"])
        XCTAssertEqual(existing["a"], [])
    }
}
