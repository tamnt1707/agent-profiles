import XCTest
@testable import ClaudeProfilesCore

/// The health state of a profile from every input: the key, the last test and its age.
final class ProfileHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(auth: AuthKind = .bearer, baseURL: String = "https://api.example.com") -> Profile {
        Profile(name: "Test", slug: "test", baseURL: baseURL, auth: auth)
    }

    private func test(_ outcome: ProbeOutcome, secondsAgo: TimeInterval = 0) -> TestRecord {
        TestRecord(outcome: outcome, testedAt: now.addingTimeInterval(-secondsAgo))
    }

    /// Every outcome kind of the probe, with the state a fresh test of it gives.
    private let table: [(ProbeOutcome, HealthState)] = [
        (.ok(latencyMs: 10, model: nil), .ready),
        (.ok(latencyMs: 10, model: "claude-haiku-4-5"), .ready),
        (.rateLimited, .attention),
        (.unsupported, .attention),
        (.unauthorized, .problem),
        (.forbidden, .problem),
        (.notFound, .problem),
        (.modelNotFound, .problem),
        (.serverError(503), .problem),
        (.unexpectedStatus(418), .problem),
        (.timeout, .problem),
        (.network(.dns), .problem),
        (.network(.offline), .problem),
        (.network(.tls), .problem),
        (.network(.other), .problem),
        (.invalidURL, .problem),
        (.insecureURL, .problem),
        (.missingKey, .problem),
        (.crossHostRedirect, .problem),
    ]

    // MARK: - Every outcome, fresh test

    func testEveryOutcomeMapsToItsStateWhenFreshAndKeyed() {
        for (outcome, expected) in table {
            let status = ProfileHealth.evaluate(
                profile: profile(), hasKey: true, lastTest: test(outcome), now: now
            )
            XCTAssertEqual(status.state, expected, "outcome \(outcome)")
        }
    }

    func testEveryOutcomeMapsToItsStateForAuthNoneWithoutKey() {
        for (outcome, expected) in table {
            let status = ProfileHealth.evaluate(
                profile: profile(auth: .none), hasKey: false, lastTest: test(outcome), now: now
            )
            XCTAssertEqual(status.state, expected, "auth none, outcome \(outcome)")
        }
    }

    func testSuccessForAuthNoneIsReadyWithoutAnyKey() {
        let status = ProfileHealth.evaluate(
            profile: profile(auth: .none), hasKey: false, lastTest: test(.ok(latencyMs: 1, model: nil)), now: now
        )
        XCTAssertEqual(status, HealthStatus(state: .ready, reason: .connected(minutesAgo: 0)))
    }

    func testReasonsCarryTheOutcomeOrTheAge() {
        XCTAssertEqual(
            ProfileHealth.evaluate(profile: profile(), hasKey: true, lastTest: test(.rateLimited), now: now).reason,
            .testWarning(.rateLimited)
        )
        XCTAssertEqual(
            ProfileHealth.evaluate(profile: profile(), hasKey: true, lastTest: test(.unauthorized), now: now).reason,
            .testFailed(.unauthorized)
        )
        XCTAssertEqual(
            ProfileHealth.evaluate(
                profile: profile(), hasKey: true,
                lastTest: test(.ok(latencyMs: 1, model: nil), secondsAgo: 10 * 60), now: now
            ).reason,
            .connected(minutesAgo: 10)
        )
    }

    // MARK: - Key rules

    func testNeededKeyMissingIsAProblemWhateverTheTestSaid() {
        let records: [TestRecord?] = [
            nil,
            test(.ok(latencyMs: 1, model: nil)),
            test(.rateLimited),
            test(.unauthorized),
        ]
        for record in records {
            let status = ProfileHealth.evaluate(profile: profile(), hasKey: false, lastTest: record, now: now)
            XCTAssertEqual(status, HealthStatus(state: .problem, reason: .noKeyStored), "record \(String(describing: record))")
        }
    }

    func testNoTestAndNoKeyNeededIsUntested() {
        let status = ProfileHealth.evaluate(profile: profile(auth: .none), hasKey: false, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .notTested))
    }

    func testNoTestAndKeyPresentIsUntested() {
        let status = ProfileHealth.evaluate(profile: profile(), hasKey: true, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .notTested))
    }

    // MARK: - Freshness

    func testEveryOutcomeIsUntestedWhenStale() {
        for (outcome, _) in table {
            let status = ProfileHealth.evaluate(
                profile: profile(), hasKey: true, lastTest: test(outcome, secondsAgo: 31 * 60), now: now
            )
            XCTAssertEqual(status.state, .untested, "stale outcome \(outcome)")
            XCTAssertEqual(status.reason, .staleTest(minutesAgo: 31), "stale outcome \(outcome)")
        }
    }

    func testExactlyThirtyMinutesIsStillFresh() {
        let status = ProfileHealth.evaluate(
            profile: profile(), hasKey: true,
            lastTest: test(.ok(latencyMs: 1, model: nil), secondsAgo: ProfileHealth.freshWindow), now: now
        )
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.reason, .connected(minutesAgo: 30))
    }

    func testOneSecondPastThirtyMinutesIsStale() {
        let status = ProfileHealth.evaluate(
            profile: profile(), hasKey: true,
            lastTest: test(.ok(latencyMs: 1, model: nil), secondsAgo: ProfileHealth.freshWindow + 1), now: now
        )
        XCTAssertEqual(status.state, .untested)
    }

    func testFreshWindowIsThirtyMinutes() {
        XCTAssertEqual(ProfileHealth.freshWindow, 30 * 60)
    }

    func testTestFromTheFutureIsNotTrusted() {
        let future = TestRecord(outcome: .ok(latencyMs: 1, model: nil), testedAt: now.addingTimeInterval(60))
        let status = ProfileHealth.evaluate(profile: profile(), hasKey: true, lastTest: future, now: now)
        XCTAssertEqual(status.state, .untested)
    }

    // MARK: - The key and the message never appear in a reason

    func testStatusTextNeverContainsTheKey() {
        let secret = "sk-SECRET-123"
        for (outcome, _) in table {
            let status = ProfileHealth.evaluate(profile: profile(), hasKey: true, lastTest: test(outcome), now: now)
            XCTAssertFalse(String(describing: status).contains(secret))
        }
    }

    // MARK: - HealthBook: what a result belongs to

    func testRecordedResultIsReturnedForTheSameProfile() {
        var book = HealthBook()
        let profile = profile()
        book.record(.ok(latencyMs: 5, model: nil), at: now, for: profile)
        XCTAssertEqual(book.lastTest(for: profile), TestRecord(outcome: .ok(latencyMs: 5, model: nil), testedAt: now))
    }

    func testChangedBaseURLClearsTheResult() {
        var book = HealthBook()
        book.record(.ok(latencyMs: 5, model: nil), at: now, for: profile(baseURL: "https://a.example.com"))
        XCTAssertNil(book.lastTest(for: profile(baseURL: "https://b.example.com")))
    }

    func testChangedAuthKindClearsTheResult() {
        var book = HealthBook()
        book.record(.ok(latencyMs: 5, model: nil), at: now, for: profile(auth: .bearer))
        XCTAssertNil(book.lastTest(for: profile(auth: .apiKey)))
    }

    func testForgetClearsOnlyThatProfile() {
        var book = HealthBook()
        let first = Profile(name: "A", slug: "a", baseURL: "https://x.example.com", auth: .bearer)
        let second = Profile(name: "B", slug: "b", baseURL: "https://x.example.com", auth: .bearer)
        book.record(.ok(latencyMs: 5, model: nil), at: now, for: first)
        book.record(.ok(latencyMs: 5, model: nil), at: now, for: second)
        book.forget(slug: "a")
        XCTAssertNil(book.lastTest(for: first))
        XCTAssertNotNil(book.lastTest(for: second))
    }

    func testRecordingAgainReplacesTheResult() {
        var book = HealthBook()
        let profile = profile()
        book.record(.unauthorized, at: now, for: profile)
        book.record(.ok(latencyMs: 5, model: nil), at: now.addingTimeInterval(1), for: profile)
        XCTAssertEqual(book.lastTest(for: profile)?.outcome, .ok(latencyMs: 5, model: nil))
    }
}
