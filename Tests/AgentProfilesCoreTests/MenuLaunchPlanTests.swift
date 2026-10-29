import XCTest
@testable import AgentProfilesCore

/// The plan of a launch from the menu bar: which folder it uses and when the
/// folder is remembered.
final class MenuLaunchPlanTests: XCTestCase {
    // MARK: - The plan

    /// A click on the profile itself opens it in its own working folder.
    func testTheProfileItselfIsOpenedInItsOwnFolder() {
        let plan = MenuLaunchPlan.profile("work")
        XCTAssertEqual(plan.slug, "work")
        XCTAssertNil(plan.folder)
        XCTAssertEqual(plan.source, .profile)
        XCTAssertFalse(plan.recordsRecentFolder)
    }

    /// A click on a folder opens the profile in that folder.
    func testAChosenFolderIsTheFolderOfTheLaunch() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/work")
        XCTAssertEqual(plan.slug, "work")
        XCTAssertEqual(plan.folder, "/tmp/work")
        XCTAssertEqual(plan.source, .chosenFolder)
        XCTAssertTrue(plan.recordsRecentFolder)
    }

    // MARK: - Remembering the folder

    /// A folder that was chosen moves to the front after a launch that worked.
    func testTheChosenFolderMovesToTheFrontAfterASuccessfulLaunch() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/new")
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: ["/tmp/old", "/tmp/older"]),
                       ["/tmp/new", "/tmp/old", "/tmp/older"])
    }

    /// A launch in the folder of the profile remembers nothing.
    func testTheProfileItselfRemembersNoFolder() {
        let plan = MenuLaunchPlan.profile("work")
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: ["/tmp/old"]), ["/tmp/old"])
    }

    /// A folder that is already remembered only moves to the front.
    func testAFolderThatIsAlreadyKnownMovesToTheFront() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/old")
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: ["/tmp/old", "/tmp/older"]),
                       ["/tmp/old", "/tmp/older"])
    }

    /// The list never grows past the five newest folders.
    func testTheListStaysAtFiveFolders() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/new")
        let stored = (1...5).map { "/tmp/\($0)" }
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: stored).count, 5)
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: stored).first, "/tmp/new")
    }

    // MARK: - Only after a successful launch

    /// A launch that failed throws, and nothing is remembered: the folder of a
    /// terminal that never opened is not a folder the user works in.
    func testAFailedLaunchRemembersNothing() async {
        let plan = MenuLaunchPlan.folder("work", "/tmp/new")
        var remembered: [String] = []
        var launched = false
        do {
            try await plan.run(launch: {
                launched = true
                throw ProfileError.launcherFailed("boom")
            }, remember: { folder in
                remembered.append(folder)
            })
            XCTFail("the failed launch did not throw")
        } catch {
            XCTAssertEqual(error as? ProfileError, .launcherFailed("boom"))
        }
        XCTAssertTrue(launched, "the launch was not even tried")
        XCTAssertEqual(remembered, [], "the folder was remembered although the launch failed")
    }

    /// A launch that worked hands the folder to the remember step.
    func testASuccessfulLaunchHandsOutTheFolder() async throws {
        let plan = MenuLaunchPlan.folder("work", "/tmp/new")
        var remembered: [String] = []
        try await plan.run(launch: {}, remember: { folder in
            remembered.append(folder)
        })
        XCTAssertEqual(remembered, ["/tmp/new"])
    }

    /// A launch of the profile itself hands out nothing.
    func testASuccessfulLaunchOfTheProfileRemembersNoFolder() async throws {
        let plan = MenuLaunchPlan.profile("work")
        var remembered: [String] = []
        try await plan.run(launch: {}, remember: { folder in
            remembered.append(folder)
        })
        XCTAssertEqual(remembered, [])
    }

    /// Two launches that overlap both keep their folder: the list of the
    /// recent folders is read again when the launch worked, and not before it
    /// started.
    func testTwoLaunchesThatOverlapBothKeepTheirFolder() {
        // The first launch works and its folder is remembered.
        var stored = ["/tmp/old"]
        stored = MenuLaunchPlan.folder("work", "/tmp/one").recentFoldersAfterSuccess(stored: stored)
        XCTAssertEqual(stored, ["/tmp/one", "/tmp/old"])
        // The second launch started before the first one was remembered: it
        // reads the list that is live at that moment.
        let second = MenuLaunchPlan.folder("work", "/tmp/two").recentFoldersAfterSuccess(stored: stored)
        XCTAssertEqual(second, ["/tmp/two", "/tmp/one", "/tmp/old"])
    }

    // MARK: - The key of a launch

    /// Two clicks on the same item of the menu have the same key.
    func testTheKeyOfALaunchIsTheProfileAndTheFolder() {
        XCTAssertEqual(MenuLaunchPlan.folder("work", "/tmp/a").launchKey,
                       MenuLaunchPlan.folder("work", "/tmp/a").launchKey)
        XCTAssertNotEqual(MenuLaunchPlan.folder("work", "/tmp/a").launchKey,
                          MenuLaunchPlan.folder("work", "/tmp/b").launchKey)
        XCTAssertNotEqual(MenuLaunchPlan.folder("work", "/tmp/a").launchKey,
                          MenuLaunchPlan.folder("other", "/tmp/a").launchKey)
        XCTAssertNotEqual(MenuLaunchPlan.profile("work").launchKey,
                          MenuLaunchPlan.folder("work", "/tmp/a").launchKey)
    }

    /// A folder with a control character never enters the list, even when the
    /// plan asks for it.
    func testAnUnsafeFolderIsNeverRemembered() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/\u{15}rm -rf ~ #")
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: ["/tmp/old"]), ["/tmp/old"])
    }
}
