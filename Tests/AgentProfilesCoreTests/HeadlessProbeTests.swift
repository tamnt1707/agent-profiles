import XCTest
@testable import AgentProfilesCore

/// The connection test through the CLI: what it runs and what it makes of the answer.
final class HeadlessProbeTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    private func profile(
        baseURL: String = "https://api.example.com/anthropic",
        auth: AuthKind = .bearer,
        isolate: Bool = true
    ) -> Profile {
        Profile(
            name: "T", slug: "t", baseURL: baseURL, auth: auth,
            model: "main-model[1m]", opusModel: "o", sonnetModel: "s", haikuModel: "h",
            extraEnv: "API_TIMEOUT_MS=1234\n# comment", isolate: isolate
        )
    }

    private func probe(_ output: String = #"{"is_error":false,"result":"OK","duration_ms":120}"#,
                       path: String? = "/bin/claude") -> (HeadlessProbe, StubHeadlessRunner) {
        let runner = StubHeadlessRunner(result: HeadlessResult(status: 0, output: output))
        let probe = HeadlessProbe(
            runner: runner,
            executable: { path },
            baseEnvironment: { _ in ["HOME": "/Users/x", "PATH": "/usr/bin"] }
        )
        return (probe, runner)
    }

    // MARK: - What is run

    func testTheCliRunsWithTheSettingsOfTheProfileAndTheModelAsDeclared() async throws {
        let (probe, runner) = probe()
        _ = try await probe.testConnection(profile: profile(), key: "sk-SECRET", paths: paths)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.executable, "/bin/claude")
        XCTAssertEqual(request.arguments.first, "-p")
        XCTAssertTrue(request.arguments.contains("--no-session-persistence"))
        XCTAssertEqual(request.timeout, HeadlessProbe.timeout)

        let env = request.environment
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://api.example.com/anthropic")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"], "sk-SECRET")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        // The name of the model is the one that is declared, `[1m]` included.
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "main-model[1m]")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_OPUS_MODEL"], "o")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_SONNET_MODEL"], "s")
        XCTAssertEqual(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "h")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], paths.home(for: "t").path)
        XCTAssertEqual(env["API_TIMEOUT_MS"], "1234")
        XCTAssertEqual(env["CLAUDE_CODE_MAX_RETRIES"], "0")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testTheKeyIsNeverOnTheCommandLine() async throws {
        let (probe, runner) = probe()
        _ = try await probe.testConnection(profile: profile(auth: .apiKey), key: "sk-SECRET", paths: paths)
        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.environment["ANTHROPIC_API_KEY"], "sk-SECRET")
        XCTAssertFalse(request.arguments.joined(separator: " ").contains("sk-SECRET"))
    }

    func testAProfileWithoutIsolationUsesTheDefaultConfigFolder() async throws {
        let (probe, runner) = probe()
        _ = try await probe.testConnection(profile: profile(isolate: false), key: "k", paths: paths)
        XCTAssertNil(runner.requests.first?.environment["CLAUDE_CONFIG_DIR"])
    }

    func testAnAccountProfileNeedsNeitherAddressNorKey() async throws {
        let (probe, runner) = probe()
        let report = try await probe.testConnection(profile: profile(baseURL: "", auth: .none), key: "", paths: paths)
        XCTAssertEqual(report.outcome, .ok(latencyMs: 120, model: nil))
        let env = try XCTUnwrap(runner.requests.first).environment
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
    }

    // MARK: - Nothing is run

    func testNothingIsRunWithoutAKey() async throws {
        let (probe, runner) = probe()
        let report = try await probe.testConnection(profile: profile(), key: "  ", paths: paths)
        XCTAssertEqual(report.outcome, .missingKey)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testNothingIsRunForAnInvalidOrInsecureAddress() async throws {
        let (probe, runner) = probe()
        var report = try await probe.testConnection(profile: profile(baseURL: "api.example.com"), key: "k", paths: paths)
        XCTAssertEqual(report.outcome, .invalidURL)
        report = try await probe.testConnection(profile: profile(baseURL: "http://api.example.com"), key: "k", paths: paths)
        XCTAssertEqual(report.outcome, .insecureURL)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testLocalhostOverPlainHTTPIsRun() async throws {
        let (probe, runner) = probe()
        let report = try await probe.testConnection(
            profile: profile(baseURL: "http://localhost:11434", auth: .none), key: "", paths: paths
        )
        XCTAssertEqual(runner.requests.count, 1)
        XCTAssertEqual(report.outcome.severity, .success)
    }

    func testNothingIsRunWhenTheCliIsNotInstalled() async throws {
        let (probe, runner) = probe(path: nil)
        let report = try await probe.testConnection(profile: profile(), key: "k", paths: paths)
        XCTAssertEqual(report.outcome, .cliNotFound)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testABadExtraEnvironmentIsAFailureNotACrash() async throws {
        var bad = profile()
        bad.extraEnv = "NOT A LINE"
        let (probe, runner) = probe()
        let report = try await probe.testConnection(profile: bad, key: "k", paths: paths)
        XCTAssertEqual(report.outcome, .cliFailed)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    // MARK: - The answer

    private func report(_ output: String, status: Int32 = 0, timedOut: Bool = false, key: String = "sk-SECRET") -> ProbeReport {
        HeadlessProbe.report(
            for: HeadlessResult(status: status, output: output, timedOut: timedOut), key: key, latencyMs: 50
        )
    }

    func testASuccessReportsTheTimeAndTheModel() {
        let result = report(#"{"is_error":false,"result":"OK","duration_ms":2978,"modelUsage":{"MiniMax-M3.1-Flash[1m]":{}}}"#)
        XCTAssertEqual(result.outcome, .ok(latencyMs: 2978, model: "MiniMax-M3.1-Flash[1m]"))
    }

    func testTheStatusOfTheProviderDecidesTheOutcome() {
        func outcome(_ status: Int, _ text: String = "x") -> ProbeOutcome {
            report(#"{"is_error":true,"api_error_status":\#(status),"result":"\#(text)"}"#).outcome
        }
        XCTAssertEqual(outcome(401, "Invalid API key"), .unauthorized)
        XCTAssertEqual(outcome(403), .forbidden)
        XCTAssertEqual(outcome(429), .rateLimited)
        XCTAssertEqual(outcome(503), .serverError(503))
        XCTAssertEqual(outcome(404, "model not found"), .modelNotFound)
        XCTAssertEqual(outcome(404, "nothing here"), .notFound)
        XCTAssertEqual(outcome(400, "unknown model m"), .modelNotFound)
        XCTAssertEqual(outcome(400, "bad"), .unexpectedStatus(400))
        XCTAssertEqual(outcome(418), .unexpectedStatus(418))
    }

    func testAnErrorWithoutAStatusIsReadFromItsWords() {
        func outcome(_ text: String) -> ProbeOutcome {
            report(#"{"is_error":true,"api_error_status":null,"result":"\#(text)"}"#).outcome
        }
        XCTAssertEqual(outcome("Not logged in · Please run /login"), .notLoggedIn)
        XCTAssertEqual(outcome("API Error: getaddrinfo ENOTFOUND host"), .network(.dns))
        XCTAssertEqual(outcome("API Error: Connection refused (ECONNREFUSED)"), .network(.other))
        XCTAssertEqual(outcome("request timed out"), .timeout)
        XCTAssertEqual(outcome("unable to verify the certificate"), .network(.tls))
        XCTAssertEqual(outcome("the network is unreachable ENETUNREACH"), .network(.offline))
        XCTAssertEqual(outcome("something nobody expected"), .cliFailed)
    }

    func testATimeoutAndAnOutputWithoutJSON() {
        XCTAssertEqual(report("", timedOut: true).outcome, .timeout)
        XCTAssertEqual(report("garbage", status: 1).outcome, .cliFailed)
        XCTAssertEqual(
            HeadlessProbe.report(for: HeadlessResult(status: -1, output: "", launchFailed: true), key: "", latencyMs: 0).outcome,
            .cliFailed
        )
    }

    func testTheJSONIsTheLastObjectOfTheOutput() {
        let result = report("warning line\n{\"is_error\":false,\"result\":\"OK\",\"duration_ms\":5}\n")
        XCTAssertEqual(result.outcome, .ok(latencyMs: 5, model: nil))
    }

    func testTheKeyNeverAppearsInTheMessage() {
        let result = report(#"{"is_error":true,"api_error_status":401,"result":"bad key sk-SECRET here"}"#)
        XCTAssertEqual(result.providerMessage, "bad key [redacted] here")
        let garbage = report("echo sk-SECRET", status: 1)
        XCTAssertFalse(garbage.providerMessage?.contains("sk-SECRET") ?? false)
    }

    // MARK: - A cancelled task

    func testACancelledTaskThrows() async {
        let (probe, _) = probe()
        let profile = profile()
        let paths = self.paths!
        let task = Task { () throws -> ProbeReport in
            while !Task.isCancelled { await Task.yield() }
            // The stub does not honor the cancel: the real runner does.
            try Task.checkCancellation()
            return try await probe.testConnection(profile: profile, key: "k", paths: paths)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled test must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// The HTTP classification, which the model list shares with nothing else now.
final class ClassifyTests: XCTestCase {
    func testStatusesMapToOutcomes() {
        func outcome(_ status: Int, _ body: String = "{}") -> ProbeOutcome {
            ConnectionProbe.classify(status: status, body: Data(body.utf8), key: "k", latencyMs: 1).outcome
        }
        XCTAssertEqual(outcome(200), .ok(latencyMs: 1, model: nil))
        XCTAssertEqual(outcome(401), .unauthorized)
        XCTAssertEqual(outcome(403), .forbidden)
        XCTAssertEqual(outcome(429), .rateLimited)
        XCTAssertEqual(outcome(500), .serverError(500))
        XCTAssertEqual(outcome(404), .notFound)
        XCTAssertEqual(outcome(404, #"{"error":{"message":"model: x does not exist"}}"#), .modelNotFound)
    }
}
