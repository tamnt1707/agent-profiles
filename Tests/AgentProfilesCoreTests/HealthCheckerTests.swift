import XCTest
@testable import AgentProfilesCore

/// The sequential runner: one request at a time, stored keys read at request
/// time, cancellation, skipping, and the outcome of every answer kind.
final class HealthCheckerTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = "sk-SECRET-123"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
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

    // MARK: - Real probe, stubbed transport: every answer kind

    /// Runs one profile through the real `ConnectionProbe` against the stub and
    /// returns the state its answer gives. `answer` nil means the stub is not asked.
    @MainActor
    private func state(for profile: Profile, answer: StubURLProtocol.Answer?) async -> (HealthStatus, Int) {
        StubURLProtocol.reset()
        if let answer {
            StubURLProtocol.answer(answer, for: "https://api.example.com/v1/messages")
        }
        let keys = try? keyStore([profile.slug: secret])
        let connection = ConnectionProbe(session: StubURLProtocol.session())
        let checker = HealthChecker(
            keys: keys ?? InMemoryKeyStore(),
            probe: { p, k in try await connection.testConnection(profile: p, key: k) },
            now: { self.fixedNow }
        )
        var steps: [HealthCheckStep] = []
        await runCheck(checker, profiles: [profile]) { steps.append($0) }
        let requests = StubURLProtocol.requests.count

        guard case .tested(_, let outcome, let at)? = steps.first else {
            return (HealthStatus(state: .problem, reason: .noKeyStored), requests)
        }
        let status = ProfileHealth.evaluate(
            profile: profile, key: .stored, lastTest: TestRecord(outcome: outcome, testedAt: at), now: fixedNow
        )
        return (status, requests)
    }

    @MainActor
    func testAnswerKindsMapToStates() async throws {
        let cases: [(String, StubURLProtocol.Answer, HealthState, HealthReason)] = [
            ("200", .json(#"{"model":"claude-haiku-4-5"}"#), .ready, .connected(minutesAgo: 0)),
            ("429", .json(#"{"error":{"message":"slow down"}}"#, statusCode: 429), .attention, .testWarning(.rateLimited)),
            ("401", .json(#"{"error":{"message":"no"}}"#, statusCode: 401), .problem, .testFailed(.unauthorized)),
            ("403", .json(#"{"error":{"message":"no"}}"#, statusCode: 403), .problem, .testFailed(.forbidden)),
            ("404", .json(#"{"error":{"message":"not here"}}"#, statusCode: 404), .problem, .testFailed(.notFound)),
            ("404 model", .json(#"{"error":{"message":"model: claude-x does not exist"}}"#, statusCode: 404), .problem, .testFailed(.modelNotFound)),
            ("400 model", .json(#"{"error":{"message":"Invalid model name passed in"}}"#, statusCode: 400), .problem, .testFailed(.modelNotFound)),
            ("500", .json(#"{"error":{"message":"oops"}}"#, statusCode: 500), .problem, .testFailed(.serverError(500))),
            ("timeout", .failure(URLError(.timedOut)), .problem, .testFailed(.timeout)),
            ("dns", .failure(URLError(.cannotFindHost)), .problem, .testFailed(.network(.dns))),
            ("offline", .failure(URLError(.notConnectedToInternet)), .problem, .testFailed(.network(.offline))),
            ("tls", .failure(URLError(.serverCertificateUntrusted)), .problem, .testFailed(.network(.tls))),
        ]
        for (name, answer, expectedState, expectedReason) in cases {
            let (status, requests) = await state(for: profile("a"), answer: answer)
            XCTAssertEqual(requests, 1, name)
            XCTAssertEqual(status.state, expectedState, name)
            XCTAssertEqual(status.reason, expectedReason, name)
        }
    }

    @MainActor
    func testRedirectToAnotherHostIsAProblem() async throws {
        let (status, _) = await state(
            for: profile("a"),
            answer: .redirect(to: "https://evil.example.net/v1/messages")
        )
        XCTAssertEqual(status.state, .problem)
        XCTAssertEqual(status.reason, .testFailed(.crossHostRedirect))
    }

    @MainActor
    func testRemotePlainHTTPIsAProblemAndNothingIsSent() async throws {
        var insecure = profile("a")
        insecure.baseURL = "http://api.example.com"
        let (status, requests) = await state(for: insecure, answer: nil)
        XCTAssertEqual(requests, 0, "a request left over plain http")
        XCTAssertEqual(status.state, .problem)
        XCTAssertEqual(status.reason, .testFailed(.insecureURL))
    }

    @MainActor
    func testInvalidBaseURLIsAProblemAndNothingIsSent() async throws {
        var invalid = profile("a")
        invalid.baseURL = "not a url"
        let (status, requests) = await state(for: invalid, answer: nil)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(status.reason, .testFailed(.invalidURL))
    }
}

private extension HealthCheckStep {
    var slugValue: String {
        switch self {
        case .tested(let slug, _, _), .skipped(let slug): return slug
        }
    }
}
