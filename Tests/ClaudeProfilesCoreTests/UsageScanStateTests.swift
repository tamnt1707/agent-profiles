import XCTest
@testable import ClaudeProfilesCore

/// The state of the counts of the usage.
///
/// A count that is stopped keeps its numbers, and the note of a stopped count
/// is there until the next count starts.
final class UsageScanStateTests: XCTestCase {
    func testACountThatRunsIsRunning() {
        var states = UsageScanStates()
        states.start("work")
        XCTAssertTrue(states.isRunning("work"))
        XCTAssertFalse(states.isStopped("work"))
    }

    func testAnotherProfileIsNotCounted() {
        var states = UsageScanStates()
        states.start("work")
        XCTAssertFalse(states.isRunning("other"))
        XCTAssertFalse(states.isStopped("other"))
    }

    /// A stopped count is not running any more, and it says so.
    func testAStoppedCountIsNotRunningAndSaysSo() {
        var states = UsageScanStates()
        states.start("work")
        states.stop("work")
        XCTAssertFalse(states.isRunning("work"))
        XCTAssertTrue(states.isStopped("work"))
    }

    /// A new count takes the note of a stopped count away.
    func testANewCountTakesTheNoteOfAStoppedCountAway() {
        var states = UsageScanStates()
        states.start("work")
        states.stop("work")
        states.start("work")
        XCTAssertTrue(states.isRunning("work"))
        XCTAssertFalse(states.isStopped("work"))
    }

    /// A count that is done has no note.
    func testACountThatIsDoneHasNoNote() {
        var states = UsageScanStates()
        states.start("work")
        states.finish("work")
        XCTAssertFalse(states.isRunning("work"))
        XCTAssertFalse(states.isStopped("work"))
    }

    /// A profile that is gone has no note.
    func testAForgottenProfileHasNoNote() {
        var states = UsageScanStates()
        states.start("work")
        states.stop("work")
        states.forget("work")
        XCTAssertFalse(states.isRunning("work"))
        XCTAssertFalse(states.isStopped("work"))
    }

    /// The counts of two profiles do not disturb each other.
    func testTheCountsOfTwoProfilesDoNotDisturbEachOther() {
        var states = UsageScanStates()
        states.start("work")
        states.stop("work")
        states.start("other")
        XCTAssertTrue(states.isStopped("work"))
        XCTAssertTrue(states.isRunning("other"))
        XCTAssertFalse(states.isRunning("work"))
    }
}
