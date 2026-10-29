import XCTest
@testable import AgentProfilesCore

/// The sequential runner: one request at a time, stored keys read at request
/// time, cancellation, skipping, and the outcome of every answer kind.
final class HealthCheckerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = "sk-SECRET-123"

    override func setUp() {
        super.setUp()
    }

    override func tearDown() {
        super.tearDown()
    }

    private func profile(_ slug: String, auth: AuthKind = .bearer) -> Profile {
        Profile(name: slug, slug: slug, baseURL: "https://api.example.com", auth: auth)
    }

    /// Records every request: the profile, the key it got, and how many were in flight.
    private final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(slug: String, key: String)] = []
        private var active = 0
        private(set) var maximumActive = 0

        func begin(_ profile: Profile, key: String) {
            lock.withLock {
                calls.append((profile.slug, key))
                active += 1
                maximumActive = max(maximumActive, active)
            }
        }

        func end() {
            lock.withLock { active -= 1 }
        }
    }

    /// Collects the steps of a run that is itself inside a Task.
    private final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [HealthCheckStep] = []

        func append(_ step: HealthCheckStep) {
            lock.withLock { values.append(step) }
        }

        var all: [HealthCheckStep] { lock.withLock { values } }
    }

    /// Holds the task of a run, so the probe can cancel it.
    private final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    /// A probe that takes a moment and answers `outcome`.
    private func slowProbe(_ probes: Probes, outcome: ProbeOutcome = .ok(latencyMs: 1, model: nil)) -> HealthChecker.Probe {
        { profile, key in
            probes.begin(profile, key: key)
            defer { probes.end() }
            try await Task.sleep(nanoseconds: 5_000_000)
            return ProbeReport(outcome: outcome)
        }
    }

    private func keyStore(_ pairs: [String: String]) throws -> InMemoryKeyStore {
        let keys = InMemoryKeyStore()
        for (slug, key) in pairs {
            try keys.set(slug, key: key)
        }
        return keys
    }

    /// Runs a check over profiles that do not change while it runs: the
    /// profile of a slug is the one of the list and no generation ever moves.
    @MainActor
    private func runCheck(
        _ checker: HealthChecker,
        profiles: [Profile],
        onStep: (HealthCheckStep) -> Void
    ) async {
        await checker.run(
            profiles: profiles,
            currentProfile: { slug in profiles.first { $0.slug == slug } },
            generation: { _ in 0 }
        ) { onStep($0) }
    }

    // MARK: - Sequential

    @MainActor
    func testProbesRunOneAtATimeInOrder() async throws {
        let keys = try keyStore(["a": "sk-a", "b": "sk-b", "c": "sk-c"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: slowProbe(probes), now: { self.fixedNow })
        var steps: [HealthCheckStep] = []

        await runCheck(checker, profiles: [profile("a"), profile("b"), profile("c")]) { steps.append($0) }

        XCTAssertEqual(probes.maximumActive, 1, "two requests were in flight at once")
        XCTAssertEqual(probes.calls.map { $0.slug }, ["a", "b", "c"])
        XCTAssertEqual(steps, [
            .tested(slug: "a", outcome: .ok(latencyMs: 1, model: nil), at: fixedNow),
            .tested(slug: "b", outcome: .ok(latencyMs: 1, model: nil), at: fixedNow),
            .tested(slug: "c", outcome: .ok(latencyMs: 1, model: nil), at: fixedNow),
        ])
    }

    // MARK: - Skipping and keys

    @MainActor
    func testProfileWithoutStoredKeyIsNeverProbed() async throws {
        let keys = try keyStore(["a": "sk-a"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: slowProbe(probes), now: { self.fixedNow })
        var steps: [HealthCheckStep] = []

        await runCheck(checker, profiles: [profile("a"), profile("b"), profile("c", auth: .none)]) { steps.append($0) }

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a", "c"], "the profile without a key was probed")
        XCTAssertEqual(steps.map(\.slugValue), ["a", "b", "c"])
        XCTAssertEqual(steps[1], .skipped(slug: "b"))
    }

    @MainActor
    func testStoredKeyIsReadAtRequestTimeAndAuthNoneGetsNoKey() async throws {
        let keys = try keyStore(["a": "sk-a"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: slowProbe(probes), now: { self.fixedNow })

        await runCheck(checker, profiles: [profile("a"), profile("c", auth: .none)]) { _ in }

        XCTAssertEqual(probes.calls.count, 2)
        XCTAssertEqual(probes.calls[0].key, "sk-a")
        XCTAssertEqual(probes.calls[1].key, "")
    }

    @MainActor
    func testKeyIsNeverInTheSteps() async throws {
        let keys = try keyStore(["a": secret])
        let checker = HealthChecker(
            keys: keys,
            probe: { _, _ in ProbeReport(outcome: .unauthorized, providerMessage: "bad key \(self.secret)") },
            now: { self.fixedNow }
        )
        var steps: [HealthCheckStep] = []

        await runCheck(checker, profiles: [profile("a")]) { steps.append($0) }

        XCTAssertFalse(String(describing: steps).contains(secret))
        XCTAssertEqual(steps, [.tested(slug: "a", outcome: .unauthorized, at: fixedNow)])
    }

    @MainActor
    func testRequestThatThrowsBecomesAnOtherNetworkProblem() async throws {
        struct Boom: Error {}
        let checker = HealthChecker(
            keys: InMemoryKeyStore(),
            probe: { _, _ in throw Boom() },
            now: { self.fixedNow }
        )
        var steps: [HealthCheckStep] = []

        await runCheck(checker, profiles: [profile("a", auth: .none)]) { steps.append($0) }

        XCTAssertEqual(steps, [.tested(slug: "a", outcome: .network(.other), at: fixedNow)])
    }

    @MainActor
    func testTheTextOfAThrownErrorNeverReachesAStep() async throws {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "the key is sk-SECRET-123 and the host is api.example.com" }
        }
        let checker = HealthChecker(
            keys: InMemoryKeyStore(),
            probe: { _, _ in throw Boom() },
            now: { self.fixedNow }
        )
        var steps: [HealthCheckStep] = []

        await runCheck(checker, profiles: [profile("a", auth: .none)]) { steps.append($0) }

        let text = String(describing: steps)
        XCTAssertFalse(text.contains("sk-SECRET-123"), "the key leaked into a step: \(text)")
        XCTAssertFalse(text.contains("api.example.com"), "the text of the error leaked into a step: \(text)")
        XCTAssertFalse(text.contains("Boom"), "the name of the error leaked into a step: \(text)")
        XCTAssertEqual(steps, [.tested(slug: "a", outcome: .network(.other), at: fixedNow)])
    }

    // MARK: - Cancellation

    @MainActor
    func testCancelStopsFurtherRequests() async throws {
        let keys = try keyStore(["a": "sk-a", "b": "sk-b", "c": "sk-c"])
        let probes = Probes()
        let box = TaskBox()
        let checker = HealthChecker(keys: keys, probe: { profile, key in
            probes.begin(profile, key: key)
            defer { probes.end() }
            box.task?.cancel()
            try Task.checkCancellation()
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })
        let steps = Steps()

        let task = Task { await self.runCheck(checker, profiles: [self.profile("a"), self.profile("b"), self.profile("c")]) { steps.append($0) } }
        box.task = task
        await task.value

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "requests went on after the cancel")
        XCTAssertEqual(steps.all, [], "an answer came in after the cancel")
    }

    @MainActor
    func testCancelBeforeStartSendsNothing() async throws {
        let keys = try keyStore(["a": "sk-a"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: slowProbe(probes), now: { self.fixedNow })
        let task = Task { await self.runCheck(checker, profiles: [self.profile("a")]) { _ in } }
        task.cancel()
        await task.value
        XCTAssertEqual(probes.calls.count, 0)
    }

    // MARK: - The CLI probe, with a stubbed CLI: what each answer gives

    /// Runs one profile through the real `HeadlessProbe` with a stubbed CLI and
    /// returns the state its answer gives, with how many times the CLI was run.
    @MainActor
    private func state(for profile: Profile, output: String?) async -> (HealthStatus, Int) {
        let runner = StubHeadlessRunner(result: HeadlessResult(status: 0, output: output ?? ""))
        let headless = HeadlessProbe(runner: runner, executable: { "/bin/claude" }, baseEnvironment: { _ in [:] })
        let keys = try? keyStore([profile.slug: secret])
        let checker = HealthChecker(
            keys: keys ?? InMemoryKeyStore(),
            probe: { p, k in try await headless.testConnection(profile: p, key: k, paths: Paths()) },
            now: { self.fixedNow }
        )
        var steps: [HealthCheckStep] = []
        await runCheck(checker, profiles: [profile]) { steps.append($0) }
        let runs = runner.requests.count

        guard case .tested(_, let outcome, let at)? = steps.first else {
            return (HealthStatus(state: .problem, reason: .noKeyStored), runs)
        }
        let status = ProfileHealth.evaluate(
            profile: profile, key: .stored, lastTest: TestRecord(outcome: outcome, testedAt: at), now: fixedNow
        )
        return (status, runs)
    }

    @MainActor
    func testAnswerKindsMapToStates() async throws {
        let cases: [(String, String, HealthState)] = [
            ("ok", #"{"is_error":false,"result":"OK","duration_ms":900,"modelUsage":{"m":{}}}"#, .ready),
            ("429", #"{"is_error":true,"api_error_status":429,"result":"slow down"}"#, .attention),
            ("401", #"{"is_error":true,"api_error_status":401,"result":"Invalid API key"}"#, .problem),
            ("not logged in", #"{"is_error":true,"api_error_status":null,"result":"Not logged in · Please run /login"}"#, .attention),
            ("500", #"{"is_error":true,"api_error_status":500,"result":"oops"}"#, .problem),
            ("refused", #"{"is_error":true,"api_error_status":null,"result":"API Error: (ECONNREFUSED)"}"#, .problem),
            ("no json", "something odd", .problem),
        ]
        for (name, output, expected) in cases {
            let (status, runs) = await state(for: profile("a"), output: output)
            XCTAssertEqual(runs, 1, name)
            XCTAssertEqual(status.state, expected, name)
        }
    }

    @MainActor
    func testRemotePlainHTTPIsAProblemAndNothingIsRun() async throws {
        var insecure = profile("a")
        insecure.baseURL = "http://api.example.com"
        let (status, runs) = await state(for: insecure, output: nil)
        XCTAssertEqual(runs, 0, "the CLI ran over plain http")
        XCTAssertEqual(status.state, .problem)
        XCTAssertEqual(status.reason, .testFailed(.insecureURL))
    }

    @MainActor
    func testInvalidBaseURLIsAProblemAndNothingIsRun() async throws {
        var invalid = profile("a")
        invalid.baseURL = "not a url"
        let (status, runs) = await state(for: invalid, output: nil)
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(status.reason, .testFailed(.invalidURL))
    }
}

/// A CLI that answers with a fixed result and remembers what it was asked.
final class StubHeadlessRunner: HeadlessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HeadlessRequest] = []
    var result: HeadlessResult

    init(result: HeadlessResult) {
        self.result = result
    }

    var requests: [HeadlessRequest] { lock.withLock { recorded } }

    func run(_ request: HeadlessRequest) async throws -> HeadlessResult {
        lock.withLock { recorded.append(request) }
        return result
    }
}

private extension HealthCheckStep {
    var slugValue: String {
        switch self {
        case .tested(let slug, _, _), .skipped(let slug): return slug
        }
    }
}
