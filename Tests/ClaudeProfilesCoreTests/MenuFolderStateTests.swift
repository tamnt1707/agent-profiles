import XCTest
@testable import ClaudeProfilesCore

/// The rule that merges the answers of the lookups of the recent folders.
///
/// The menu is drawn from the last answer, never from the file system. Two
/// lookups can be on their way at the same time, and the older one can come
/// back last.
final class MenuFolderStateTests: XCTestCase {
    /// The answer of a lookup that found the folders of the profiles.
    private func lookup(_ generation: Int, _ entries: [String: MenuFolderState.Entry]) -> MenuFolderState.Lookup {
        MenuFolderState.Lookup(generation: generation, entries: entries)
    }

    /// The answer of a lookup is taken when it is the newest one.
    func testTheAnswerOfALookupIsTaken() {
        var state = MenuFolderState()
        let generation = state.begin()
        XCTAssertTrue(state.accept(lookup(generation, ["work": .checked(["/tmp/a"])]), known: ["work"]))
        XCTAssertEqual(state.folders, ["work": ["/tmp/a"]])
    }

    /// An answer that comes back after a newer one is dropped: it says less
    /// about the file system than the newer answer.
    func testAnOlderAnswerIsDropped() {
        var state = MenuFolderState()
        let older = state.begin()
        let newer = state.begin()
        XCTAssertTrue(state.accept(lookup(newer, ["work": .checked(["/tmp/new"])]), known: ["work"]))
        XCTAssertFalse(state.accept(lookup(older, ["work": .checked(["/tmp/old"])]), known: ["work"]))
        XCTAssertEqual(state.folders, ["work": ["/tmp/new"]])
    }

    /// A profile that is not in the list any more is left out.
    func testAnUnknownSlugIsIgnored() {
        var state = MenuFolderState()
        let generation = state.begin()
        XCTAssertTrue(state.accept(
            lookup(generation, ["work": .checked(["/tmp/a"]), "gone": .checked(["/tmp/b"])]),
            known: ["work"]
        ))
        XCTAssertEqual(state.folders, ["work": ["/tmp/a"]])
    }

    /// A profile whose check did not finish in time keeps its folders: they
    /// are shown as they are, and nobody drops them.
    func testATimeoutKeepsTheEntries() {
        var state = MenuFolderState()
        let first = state.begin()
        XCTAssertTrue(state.accept(lookup(first, ["work": .checked(["/tmp/a", "/tmp/b"])]), known: ["work"]))
        // The next lookup did not finish in time for this profile.
        let second = state.begin()
        XCTAssertTrue(state.accept(lookup(second, ["work": .unchecked]), known: ["work"]))
        XCTAssertEqual(state.folders, ["work": ["/tmp/a", "/tmp/b"]])
    }

    /// A profile that was not looked up at all keeps nothing.
    func testAProfileThatWasNotLookedUpHasNoFolders() {
        var state = MenuFolderState()
        let generation = state.begin()
        XCTAssertTrue(state.accept(lookup(generation, ["work": .unchecked]), known: ["work"]))
        XCTAssertEqual(state.folders, ["work": []])
    }

    /// Every lookup gets a number that is higher than the number of the one
    /// before it.
    func testEveryLookupGetsANewNumber() {
        var state = MenuFolderState()
        let first = state.begin()
        let second = state.begin()
        XCTAssertGreaterThan(second, first)
    }

    /// A profile that was deleted or renamed keeps no folders: they must not
    /// be shown any more.
    func testAProfileThatIsGoneKeepsNoFolders() {
        var state = MenuFolderState()
        let generation = state.begin()
        XCTAssertTrue(state.accept(
            lookup(generation, ["work": .checked(["/tmp/a"]), "gone": .checked(["/tmp/b"])]),
            known: ["work", "gone"]
        ))
        XCTAssertEqual(state.folders, ["work": ["/tmp/a"], "gone": ["/tmp/b"]])

        state.forget(slug: "gone")

        XCTAssertEqual(state.folders, ["work": ["/tmp/a"]])
    }

    /// A profile that comes back with the same name starts with nothing: the
    /// folders of the old one are not its folders.
    func testAProfileThatComesBackStartsWithNothing() {
        var state = MenuFolderState()
        let generation = state.begin()
        XCTAssertTrue(state.accept(lookup(generation, ["work": .checked(["/tmp/a"])]), known: ["work"]))
        state.forget(slug: "work")

        let next = state.begin()
        XCTAssertTrue(state.accept(lookup(next, ["work": .unchecked]), known: ["work"]))

        XCTAssertEqual(state.folders, ["work": []])
    }
}

/// The rule that keeps a second click from opening a second terminal.
final class LaunchGuardTests: XCTestCase {
    /// The first click starts the launch.
    func testTheFirstClickStartsTheLaunch() {
        var guard_ = LaunchGuard()
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/a"))
        XCTAssertTrue(guard_.isRunning("work\u{1F}/tmp/a"))
    }

    /// A second click on the same item is ignored while the launch is on its
    /// way.
    func testASecondClickOnTheSameItemIsIgnored() {
        var guard_ = LaunchGuard()
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/a"))
        XCTAssertFalse(guard_.begin("work\u{1F}/tmp/a"))
    }

    /// Another item of the menu is not blocked.
    func testAnotherItemIsNotBlocked() {
        var guard_ = LaunchGuard()
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/a"))
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/b"))
        XCTAssertTrue(guard_.begin("other\u{1F}/tmp/a"))
    }

    /// The item can be clicked again when the launch is done.
    func testTheItemCanBeClickedAgainWhenTheLaunchIsDone() {
        var guard_ = LaunchGuard()
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/a"))
        guard_.end("work\u{1F}/tmp/a")
        XCTAssertFalse(guard_.isRunning("work\u{1F}/tmp/a"))
        XCTAssertTrue(guard_.begin("work\u{1F}/tmp/a"))
    }
}
