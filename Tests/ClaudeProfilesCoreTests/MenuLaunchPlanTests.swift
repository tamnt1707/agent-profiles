import XCTest
@testable import ClaudeProfilesCore

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
            try await plan.run(stored: ["/tmp/old"], launch: {
                launched = true
                throw ProfileError.launcherFailed("boom")
            }, remember: { folders in
                remembered = folders
            })
            XCTFail("the failed launch did not throw")
        } catch {
            XCTAssertEqual(error as? ProfileError, .launcherFailed("boom"))
        }
        XCTAssertTrue(launched, "the launch was not even tried")
        XCTAssertEqual(remembered, [], "the folder was remembered although the launch failed")
    }

    /// A launch that worked hands the new list to the remember step.
    func testASuccessfulLaunchHandsOutTheNewList() async throws {
        let plan = MenuLaunchPlan.folder("work", "/tmp/new")
        var remembered: [String] = []
        try await plan.run(stored: ["/tmp/old"], launch: {}, remember: { folders in
            remembered = folders
        })
        XCTAssertEqual(remembered, ["/tmp/new", "/tmp/old"])
    }

    /// A launch of the profile itself hands out the list unchanged.
    func testASuccessfulLaunchOfTheProfileHandsOutTheSameList() async throws {
        let plan = MenuLaunchPlan.profile("work")
        var remembered: [String] = []
        try await plan.run(stored: ["/tmp/old"], launch: {}, remember: { folders in
            remembered = folders
        })
        XCTAssertEqual(remembered, ["/tmp/old"])
    }

    /// A folder with a control character never enters the list, even when the
    /// plan asks for it.
    func testAnUnsafeFolderIsNeverRemembered() {
        let plan = MenuLaunchPlan.folder("work", "/tmp/\u{15}rm -rf ~ #")
        XCTAssertEqual(plan.recentFoldersAfterSuccess(stored: ["/tmp/old"]), ["/tmp/old"])
    }
}
