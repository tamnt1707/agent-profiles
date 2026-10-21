import XCTest
@testable import ClaudeProfilesCore

final class UpdateConfigurationTests: XCTestCase {
    private func info(
        repo: String? = "tamnt1707/claude-profiles",
        key: String? = "cHVibGljLWtleQ==",
        version: String? = "0.1.0",
        identifier: String? = "local.claude-profiles"
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        if let repo { result["UpdateRepo"] = repo }
        if let key { result["UpdatePublicKey"] = key }
        if let version { result["CFBundleShortVersionString"] = version }
        if let identifier { result["CFBundleIdentifier"] = identifier }
        return result
    }

    func testACompleteBundleIsReady() {
        let configuration = UpdateConfiguration.from(
            info: info(),
            bundleURL: URL(fileURLWithPath: "/Applications/Claude Profiles.app")
        )
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertNil(configuration.disabledReason)
        XCTAssertEqual(configuration.repo, "tamnt1707/claude-profiles")
        XCTAssertEqual(configuration.versionText, "0.1.0")
        XCTAssertEqual(configuration.bundleIdentifier, "local.claude-profiles")
        XCTAssertEqual(configuration.appBundleURL?.path, "/Applications/Claude Profiles.app")
    }

    func testWithoutAVersionTheUpdaterIsOff() {
        let configuration = UpdateConfiguration.from(info: info(version: nil), bundleURL: nil)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.disabledReason, .noVersion)
        XCTAssertTrue(configuration.versionText.isEmpty)
    }

    func testWithoutARepositoryTheUpdaterIsOff() {
        let configuration = UpdateConfiguration.from(info: info(repo: nil), bundleURL: nil)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.disabledReason, .noRepo)
    }

    func testAnEmptyRepositoryTurnsTheUpdaterOff() {
        let configuration = UpdateConfiguration.from(info: info(repo: ""), bundleURL: nil)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.disabledReason, .noRepo)
    }

    func testWithoutAPublicKeyTheUpdaterIsOff() {
        let configuration = UpdateConfiguration.from(info: info(key: nil), bundleURL: nil)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.disabledReason, .noPublicKey)
    }

    func testAVersionThatIsNoVersionTurnsTheUpdaterOff() {
        let configuration = UpdateConfiguration.from(info: info(version: "nightly"), bundleURL: nil)
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertEqual(configuration.disabledReason, .noVersion)
    }

    func testAnAppThatDoesNotRunFromABundleHasNoBundleURL() {
        // `swift run` has no `.app` around it.
        let configuration = UpdateConfiguration.from(
            info: info(),
            bundleURL: URL(fileURLWithPath: "/tmp/build/ClaudeProfiles")
        )
        XCTAssertNil(configuration.appBundleURL)
    }
}
