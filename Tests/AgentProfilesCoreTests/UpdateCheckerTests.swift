import XCTest
@testable import AgentProfilesCore

final class UpdateCheckerTests: XCTestCase {
    private let repo = "tamnt1707/claude-profiles"
    private let apiURL = "https://api.github.com/repos/tamnt1707/claude-profiles/releases/latest"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func checker(timeout: TimeInterval = 15) -> UpdateChecker {
        UpdateChecker(repo: repo, session: StubURLProtocol.session(), timeout: timeout)
    }

    private func current(_ text: String = "1.0.0") throws -> SemVer {
        try XCTUnwrap(SemVer(text: text))
    }

    /// A release of the repository, as GitHub answers it.
    private func release(
        tag: String = "v1.2.0",
        body: String = "What is new",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: Bool = true
    ) -> String {
        let assetList: String
        if assets {
            assetList = """
              "assets": [
                {
                  "name": "Agent-Profiles-1.2.0-macos.zip",
                  "browser_download_url": "https://github.com/tamnt1707/claude-profiles/releases/download/v1.2.0/Agent-Profiles-1.2.0-macos.zip"
                },
                {
                  "name": "Agent-Profiles-1.2.0-macos.zip.sig",
                  "browser_download_url": "https://github.com/tamnt1707/claude-profiles/releases/download/v1.2.0/Agent-Profiles-1.2.0-macos.zip.sig"
                }
              ]
            """
        } else {
            assetList = "\"assets\": []"
        }
        return """
        {
          "tag_name": "\(tag)",
          "name": "\(tag)",
          "body": "\(body)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          \(assetList)
        }
        """
    }

    func testFindsANewerVersion() async throws {
        StubURLProtocol.answer(.json(release()), for: apiURL)

        let result = try await checker().check(current: try current())

        guard case .available(let info) = result else {
            return XCTFail("expected a new version, got \(result)")
        }
        XCTAssertEqual(info.version.description, "1.2.0")
        XCTAssertEqual(info.notes, "What is new")
        XCTAssertEqual(info.zipURL.host, "github.com")
        XCTAssertEqual(info.zipURL.path, "/tamnt1707/claude-profiles/releases/download/v1.2.0/Agent-Profiles-1.2.0-macos.zip")
        XCTAssertEqual(info.sigURL.path, "/tamnt1707/claude-profiles/releases/download/v1.2.0/Agent-Profiles-1.2.0-macos.zip.sig")
    }

    func testTheSameVersionIsUpToDate() async throws {
        StubURLProtocol.answer(.json(release(tag: "v1.0.0")), for: apiURL)

        let result = try await checker().check(current: try current())

        guard case .upToDate(let version) = result else {
            return XCTFail("expected to be up to date, got \(result)")
        }
        XCTAssertEqual(version.description, "1.0.0")
    }

    func testAnOlderVersionIsUpToDate() async throws {
        StubURLProtocol.answer(.json(release(tag: "v0.9.0")), for: apiURL)

        let result = try await checker().check(current: try current())

        guard case .upToDate = result else {
            return XCTFail("expected to be up to date, got \(result)")
        }
    }

    func testAPrereleaseOfTheSameVersionIsNotNewer() async throws {
        // 1.2.3-beta is older than 1.2.3.
        StubURLProtocol.answer(.json(release(tag: "v1.2.3-beta")), for: apiURL)

        let result = try await checker().check(current: try current("1.2.3"))

        guard case .upToDate = result else {
            return XCTFail("expected to be up to date, got \(result)")
        }
    }

    func testDraftsAreIgnored() async throws {
        StubURLProtocol.answer(.json(release(draft: true)), for: apiURL)

        await assertThrows(.noReleases) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testThePreReleasesAreIgnored() async throws {
        StubURLProtocol.answer(.json(release(prerelease: true)), for: apiURL)

        await assertThrows(.noReleases) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testWithoutReleases() async throws {
        StubURLProtocol.answer(.json("{\"message\": \"Not Found\"}", statusCode: 404), for: apiURL)

        await assertThrows(.noReleases) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testTheRateLimitIsReported() async throws {
        StubURLProtocol.answer(.json("{\"message\": \"rate limit\"}", statusCode: 403), for: apiURL)
        await assertThrows(.rateLimited) {
            try await self.checker().check(current: try self.current())
        }

        StubURLProtocol.answer(.json("{\"message\": \"rate limit\"}", statusCode: 429), for: apiURL)
        await assertThrows(.rateLimited) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testABrokenAnswerIsReported() async throws {
        StubURLProtocol.answer(.json("this is not json"), for: apiURL)

        await assertThrows(.invalidResponse) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testATagThatIsNoVersionIsRefused() async throws {
        StubURLProtocol.answer(.json(release(tag: "nightly")), for: apiURL)

        await assertThrows(.invalidResponse) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testAReleaseWithoutAssetsIsRefused() async throws {
        StubURLProtocol.answer(.json(release(assets: false)), for: apiURL)

        await assertThrows(.invalidResponse) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testOfflineIsReported() async throws {
        StubURLProtocol.answer(.failure(URLError(.notConnectedToInternet)), for: apiURL)

        await assertThrows(.networkUnavailable) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testATimeoutIsReported() async throws {
        StubURLProtocol.answer(.failure(URLError(.timedOut)), for: apiURL)

        await assertThrows(.timedOut) {
            try await self.checker().check(current: try self.current())
        }
    }

    func testTheRequestAsksGithubProperly() async throws {
        StubURLProtocol.answer(.json(release()), for: apiURL)

        _ = try await checker().check(current: try current())

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, apiURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AgentProfiles")
        // No token is sent.
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testTheRepositoryHasToLookLikeARepository() {
        XCTAssertTrue(UpdateChecker.isValidRepo("tamnt1707/claude-profiles"))
        XCTAssertFalse(UpdateChecker.isValidRepo(""))
        XCTAssertFalse(UpdateChecker.isValidRepo("claude-profiles"))
        XCTAssertFalse(UpdateChecker.isValidRepo("owner/name/extra"))
        XCTAssertFalse(UpdateChecker.isValidRepo("owner/"))
        XCTAssertFalse(UpdateChecker.isValidRepo("../etc/passwd"))
        XCTAssertNil(UpdateChecker(repo: "../etc/passwd").latestReleaseURL)
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: UpdateError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as UpdateError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
