import XCTest
@testable import ClaudeProfilesCore

/// The updater is busy from the moment a run begins, refuses a second run,
/// and ignores the progress of a run that was cancelled or ended.
final class UpdateBusyStateTests: XCTestCase {
    /// Busy holds the instant `begin()` returns, before any other call.
    func testBusyTheMomentBeginReturns() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())
        XCTAssertTrue(busy.isBusy, "busy must hold as soon as begin() returns")
        XCTAssertEqual(
            busy.progress,
            .downloading(received: 0, expected: nil),
            "the run starts as a download, before the first byte arrives"
        )
    }

    /// A second start while the first is running is refused and changes nothing.
    func testASecondBeginWhileBusyIsRefused() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())
        busy.report(.downloading(received: 5, expected: 10))

        XCTAssertFalse(busy.begin(), "a second run must not start")
        XCTAssertTrue(busy.isBusy)
        XCTAssertEqual(busy.progress, .downloading(received: 5, expected: 10))
    }

    /// `end()` reopens the updater for the next run.
    func testEndReopensTheUpdater() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())
        busy.end()

        XCTAssertFalse(busy.isBusy)
        XCTAssertNil(busy.progress)
        XCTAssertTrue(busy.begin())
    }

    /// Reports of the running run are recorded in order.
    func testProgressOfTheRunIsRecorded() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())

        busy.report(.verifying)
        XCTAssertEqual(busy.progress, .verifying)
        busy.report(.extracting)
        XCTAssertEqual(busy.progress, .extracting)
        busy.report(.installing)
        XCTAssertEqual(busy.progress, .installing)
    }

    /// A report that arrives after the run ended cannot flip the state back.
    func testALateReportAfterEndIsIgnored() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())
        busy.end()

        busy.report(.downloading(received: 1, expected: 2))
        XCTAssertNil(busy.progress, "a late report must not bring the run back")
        XCTAssertFalse(busy.isBusy)
    }

    /// After a cancel a late report is ignored, and the gate stays closed until
    /// the cancelled run has ended.
    func testALateReportAfterCancelIsIgnoredAndTheGateStaysClosed() {
        var busy = UpdateBusyState()
        XCTAssertTrue(busy.begin())
        busy.cancel()

        busy.report(.downloading(received: 1, expected: 2))
        XCTAssertNil(busy.progress, "a late report after cancel must not flip the state to downloading")
        XCTAssertTrue(busy.isBusy, "the cancelled run has not unwound yet")
        XCTAssertFalse(busy.begin(), "no run starts before the cancelled one ends")

        busy.end()
        XCTAssertTrue(busy.begin())
    }

    /// A report before any run is ignored.
    func testAReportBeforeABeginIsIgnored() {
        var busy = UpdateBusyState()
        busy.report(.installing)
        XCTAssertNil(busy.progress)
        XCTAssertFalse(busy.isBusy)
    }
}
