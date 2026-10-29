import XCTest
@testable import AgentProfilesCore

final class AccountInfoTests: XCTestCase {
    private let signedIn = """
    Restored session: Thu Oct 29 14:21:00 +07 2026
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "email": "me@example.com",
      "orgName": "Example Org",
      "subscriptionType": "max"
    }
    Saving session...completed.
    """

    func testASignedInAccountIsRead() throws {
        let info = try XCTUnwrap(AccountInfo(output: signedIn))
        XCTAssertEqual(info, AccountInfo(
            loggedIn: true, authMethod: "claude.ai", email: "me@example.com",
            organization: "Example Org", subscription: "max"
        ))
    }

    func testNotSignedInHasNoAccount() throws {
        let info = try XCTUnwrap(AccountInfo(output: #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#))
        XCTAssertFalse(info.loggedIn)
        XCTAssertNil(info.authMethod)
        XCTAssertNil(info.email)
    }

    func testOutputWithoutAnObjectIsNotAnAccount() {
        XCTAssertNil(AccountInfo(output: ""))
        XCTAssertNil(AccountInfo(output: "command not found"))
        XCTAssertNil(AccountInfo(output: #"{"nothing": 1}"#))
    }

    // MARK: - The probe

    private func probe(_ result: HeadlessResult, path: String? = "/bin/claude") -> (AccountProbe, StubHeadlessRunner) {
        let runner = StubHeadlessRunner(result: result)
        return (AccountProbe(runner: runner, executable: { path }, baseEnvironment: { _ in ["HOME": "/h"] }), runner)
    }

    func testAProfileAsksTheCliWithItsOwnFolder() async throws {
        let (probe, runner) = probe(HeadlessResult(status: 0, output: signedIn))
        let paths = Paths(home: URL(fileURLWithPath: "/h"))
        let info = await probe.fetch(profile: Profile(name: "a", slug: "a", auth: .none, isolate: true), paths: paths)
        XCTAssertEqual(info?.email, "me@example.com")
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.executable, "/bin/claude")
        XCTAssertEqual(request.arguments, ["auth", "status"])
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], paths.home(for: "a").path)
    }

    func testTheDefaultSetupAsksPlainClaudeInTheLoginShell() async throws {
        let (probe, runner) = probe(HeadlessResult(status: 0, output: signedIn))
        _ = await probe.fetch(profile: .defaultClaude, paths: Paths(home: URL(fileURLWithPath: "/h")), inherited: ["HOME": "/h", "X": "1"])
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.executable, "/bin/zsh")
        XCTAssertEqual(request.arguments, ["-l", "-i", "-c", "claude auth status"])
        XCTAssertEqual(request.environment, ["HOME": "/h", "X": "1"])
    }

    func testNoCliATimeoutOrJunkGivesNothing() async {
        let paths = Paths(home: URL(fileURLWithPath: "/h"))
        let profile = Profile(name: "a", slug: "a", auth: .none, isolate: true)
        let missing = await probe(HeadlessResult(status: 0, output: signedIn), path: nil).0.fetch(profile: profile, paths: paths)
        XCTAssertNil(missing)
        let timedOut = await probe(HeadlessResult(status: 15, output: "", timedOut: true)).0.fetch(profile: profile, paths: paths)
        XCTAssertNil(timedOut)
        let junk = await probe(HeadlessResult(status: 1, output: "boom")).0.fetch(profile: profile, paths: paths)
        XCTAssertNil(junk)
    }
}
