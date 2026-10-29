import XCTest
@testable import AgentProfilesCore

final class LoginShellPathTests: XCTestCase {
    func testTheNoiseBeforeThePathIsDropped() {
        let output = "Restored session: Thu Oct 29 13:58:16 +07 2026\n\(AgentDetector.pathMarker)/usr/bin:/bin"
        XCTAssertEqual(AgentDetector.pathValue(in: output), "/usr/bin:/bin")
    }

    func testTheLastMarkerWins() {
        let output = "\(AgentDetector.pathMarker)/old\n\(AgentDetector.pathMarker)/new"
        XCTAssertEqual(AgentDetector.pathValue(in: output), "/new")
    }

    func testNoMarkerOrNoValueGivesNothing() {
        XCTAssertNil(AgentDetector.pathValue(in: "/usr/bin:/bin"))
        XCTAssertNil(AgentDetector.pathValue(in: AgentDetector.pathMarker))
    }

    func testTheRealShellGivesACleanPath() throws {
        let path = try XCTUnwrap(AgentDetector.loginShellPath())
        XCTAssertFalse(path.contains("\n"))
        XCTAssertFalse(path.contains("Restored"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}
