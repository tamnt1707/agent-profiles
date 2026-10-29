import XCTest
@testable import AgentProfilesCore

/// The gate that keeps one update from starting while another is running.
final class UpdateRunGateTests: XCTestCase {
    /// A second start while the first one is still starting is refused.
    func testASecondBeginWhileTheFirstIsStartingIsRefused() {
        var gate = UpdateRunGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.begin(), "a second start must not pass the gate")
        XCTAssertTrue(gate.isRunning)
    }

    /// After the run completes the gate opens again.
    func testTheGateReopensAfterCompletion() {
        var gate = UpdateRunGate()
        XCTAssertTrue(gate.begin())
        gate.end()
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin())
    }

    /// After a failed run the gate opens again as well: the caller ends the run in both cases.
    func testTheGateReopensAfterFailure() {
        var gate = UpdateRunGate()
        XCTAssertTrue(gate.begin())
        // The failure path ends the run the same way as completion does.
        gate.end()
        XCTAssertTrue(gate.begin())
    }

    /// Ending a run that is not running changes nothing and leaves the gate open.
    func testEndWithoutABeginLeavesTheGateOpen() {
        var gate = UpdateRunGate()
        gate.end()
        XCTAssertFalse(gate.isRunning)
        XCTAssertTrue(gate.begin())
    }
}
