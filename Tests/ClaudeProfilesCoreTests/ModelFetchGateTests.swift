import XCTest
@testable import ClaudeProfilesCore

/// The rule that keeps the list of the models and the check of the profiles
/// apart: they both send requests to the provider.
final class ModelFetchGateTests: XCTestCase {
    func testTheListMayBeFetchedWhenNothingElseRuns() {
        XCTAssertTrue(ModelFetchGate.canFetch(isFetching: false, isCheckingHealth: false))
    }

    func testTheListIsNotFetchedWhileAnotherFetchRuns() {
        XCTAssertFalse(ModelFetchGate.canFetch(isFetching: true, isCheckingHealth: false))
    }

    func testTheListIsNotFetchedWhileTheCheckOfTheProfilesRuns() {
        XCTAssertFalse(ModelFetchGate.canFetch(isFetching: false, isCheckingHealth: true))
    }

    func testTheListIsNotFetchedWhileBothRun() {
        XCTAssertFalse(ModelFetchGate.canFetch(isFetching: true, isCheckingHealth: true))
    }
}
