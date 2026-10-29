import XCTest
@testable import AgentProfilesCore

final class UpdatePolicyTests: XCTestCase {
    func testTheReleaseAssetsHostIsAllowedOverHTTPS() throws {
        let url = try XCTUnwrap(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/update.zip"))
        XCTAssertNoThrow(try UpdatePolicy.validate(url))
        XCTAssertTrue(UpdatePolicy.isAllowed(url))
    }

    func testTheReleaseAssetsHostOverPlainHTTPIsRefused() throws {
        let url = try XCTUnwrap(URL(string: "http://release-assets.githubusercontent.com/update.zip"))
        XCTAssertFalse(UpdatePolicy.isAllowed(url))
    }

    func testTheOtherKnownHostsStillWork() throws {
        for text in [
            "https://github.com/tamnt1707/claude-profiles/releases/download/v2.0.0/a.zip",
            "https://api.github.com/repos/tamnt1707/claude-profiles/releases",
            "https://objects.githubusercontent.com/a.zip",
        ] {
            XCTAssertTrue(UpdatePolicy.isAllowed(try XCTUnwrap(URL(string: text))), text)
        }
    }

    func testOtherHostsAreRefused() throws {
        for text in [
            "https://evil.example/update.zip",
            "https://githubusercontent.com/update.zip",
            "https://release-assets.githubusercontent.com.evil.example/update.zip",
        ] {
            XCTAssertFalse(UpdatePolicy.isAllowed(try XCTUnwrap(URL(string: text))), text)
        }
    }
}
