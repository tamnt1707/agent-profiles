import XCTest
@testable import AgentProfilesCore

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
        (.cliNotFound, .problem),
        (.cliFailed, .problem),
        (.notLoggedIn, .attention),
        (.cliLogin, .attention),
    ]

    // MARK: - Every outcome, fresh test

    func testEveryOutcomeMapsToItsStateWhenFreshAndKeyed() {
        for (outcome, expected) in table {
            let status = ProfileHealth.evaluate(
                profile: profile(), key: .stored, lastTest: test(outcome), now: now
            )
            XCTAssertEqual(status.state, expected, "outcome \(outcome)")
        }
    }

    func testEveryOutcomeMapsToItsStateForAuthNoneWithoutKey() {
        for (outcome, expected) in table {
            let status = ProfileHealth.evaluate(
                profile: profile(auth: .none), key: .missing, lastTest: test(outcome), now: now
            )
            XCTAssertEqual(status.state, expected, "auth none, outcome \(outcome)")
        }
    }

    func testSuccessForAuthNoneIsReadyWithoutAnyKey() {
        let status = ProfileHealth.evaluate(
            profile: profile(auth: .none), key: .missing, lastTest: test(.ok(latencyMs: 1, model: nil)), now: now
        )
        XCTAssertEqual(status, HealthStatus(state: .ready, reason: .connected(minutesAgo: 0)))
    }

    func testReasonsCarryTheOutcomeOrTheAge() {
        XCTAssertEqual(
            ProfileHealth.evaluate(profile: profile(), key: .stored, lastTest: test(.rateLimited), now: now).reason,
            .testWarning(.rateLimited)
        )
        XCTAssertEqual(
            ProfileHealth.evaluate(profile: profile(), key: .stored, lastTest: test(.unauthorized), now: now).reason,
            .testFailed(.unauthorized)
        )
        XCTAssertEqual(
            ProfileHealth.evaluate(
                profile: profile(), key: .stored,
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
            let status = ProfileHealth.evaluate(profile: profile(), key: .missing, lastTest: record, now: now)
            XCTAssertEqual(status, HealthStatus(state: .problem, reason: .noKeyStored), "record \(String(describing: record))")
        }
    }

    func testNoTestAndNoKeyNeededIsUntested() {
        let status = ProfileHealth.evaluate(profile: profile(auth: .none), key: .missing, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .notTested))
    }

    func testNoTestAndKeyPresentIsUntested() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .stored, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .notTested))
    }

    // MARK: - The Keychain that could not be read

    func testAKeychainThatCouldNotBeReadIsUntestedAndSaysSo() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .unreadable, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .keychainUnreadable))
    }

    func testAKeychainThatCouldNotBeReadIsNotAMissingKey() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .unreadable, lastTest: nil, now: now)
        XCTAssertNotEqual(status.state, .problem, "a Keychain that cannot be read was shown as a problem")
        XCTAssertNotEqual(status.reason, .noKeyStored, "a Keychain that cannot be read was shown as a missing key")
    }

    func testAKeychainThatCouldNotBeReadIsNotASilentSuccess() {
        // The profile was tested before, but nobody could read the Keychain
        // since: the dot does not say that the key is there.
        let status = ProfileHealth.evaluate(
            profile: profile(), key: .unreadable, lastTest: test(.ok(latencyMs: 1, model: nil)), now: now
        )
        XCTAssertEqual(status.state, .untested)
        XCTAssertEqual(status.reason, .keychainUnreadable)
    }

    func testTheReasonOfAnUnreadableKeychainIsItsOwn() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .unreadable, lastTest: nil, now: now)
        XCTAssertNotEqual(status.reason, .notTested, "a Keychain that cannot be read looks like a profile that was never tested")
    }

    func testAProfileThatWasNeverReadIsPlainUntested() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .unknown, lastTest: nil, now: now)
        XCTAssertEqual(status, HealthStatus(state: .untested, reason: .notTested))
    }

    func testAProfileThatWasNeverReadIsNotAMissingKey() {
        let status = ProfileHealth.evaluate(profile: profile(), key: .unknown, lastTest: nil, now: now)
        XCTAssertNotEqual(status.reason, .noKeyStored, "a presence that was never read was shown as a missing key")
    }

    func testAProfileThatNeedsNoKeyIsNotAboutTheKeychain() {
        // The auth kind needs no key, so a Keychain that cannot be read says
        // nothing about this profile.
        let status = ProfileHealth.evaluate(
            profile: profile(auth: .none), key: .unreadable,
            lastTest: test(.ok(latencyMs: 1, model: nil)), now: now
        )
        XCTAssertEqual(status, HealthStatus(state: .ready, reason: .connected(minutesAgo: 0)))
    }

    // MARK: - A kept result has no expiry

    func testAResultOfAnyAgeKeepsItsState() {
        for (outcome, expected) in table {
            for age in [5 * 60, 31 * 60, 3 * 3600, 40 * 24 * 3600] {
                let status = ProfileHealth.evaluate(
                    profile: profile(), key: .stored, lastTest: test(outcome, secondsAgo: TimeInterval(age)), now: now
                )
                XCTAssertEqual(status.state, expected, "\(outcome) after \(age) s")
            }
        }
    }

    func testTheAgeIsInTheReasonOfASuccess() {
        let status = ProfileHealth.evaluate(
            profile: profile(), key: .stored,
            lastTest: test(.ok(latencyMs: 1, model: nil), secondsAgo: 3 * 3600), now: now
        )
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.reason, .connected(minutesAgo: 180))
    }

    func testTestFromTheFutureCountsAsJustNow() {
        let future = TestRecord(outcome: .ok(latencyMs: 1, model: nil), testedAt: now.addingTimeInterval(60))
        let status = ProfileHealth.evaluate(profile: profile(), key: .stored, lastTest: future, now: now)
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.reason, .connected(minutesAgo: 0))
    }

    // MARK: - The key and the message never appear in a reason

    func testStatusTextNeverContainsTheKey() {
        let secret = "sk-SECRET-123"
        for (outcome, _) in table {
            let status = ProfileHealth.evaluate(profile: profile(), key: .stored, lastTest: test(outcome), now: now)
            XCTAssertFalse(String(describing: status).contains(secret))
        }
    }

    // MARK: - HealthBook: what a result belongs to

    func testRecordedResultIsReturnedForTheSameProfile() {
        var book = HealthBook()
        let profile = profile()
        record(.ok(latencyMs: 5, model: nil), in: &book, for: profile)
        XCTAssertEqual(book.lastTest(for: profile), TestRecord(outcome: .ok(latencyMs: 5, model: nil), testedAt: now))
    }

    func testChangedBaseURLClearsTheResult() {
        var book = HealthBook()
        record(.ok(latencyMs: 5, model: nil), in: &book, for: profile(baseURL: "https://a.example.com"))
        XCTAssertNil(book.lastTest(for: profile(baseURL: "https://b.example.com")))
    }

    func testChangedAuthKindClearsTheResult() {
        var book = HealthBook()
        record(.ok(latencyMs: 5, model: nil), in: &book, for: profile(auth: .bearer))
        XCTAssertNil(book.lastTest(for: profile(auth: .apiKey)))
    }

    func testForgetClearsOnlyThatProfile() {
        var book = HealthBook()
        let first = Profile(name: "A", slug: "a", baseURL: "https://x.example.com", auth: .bearer)
        let second = Profile(name: "B", slug: "b", baseURL: "https://x.example.com", auth: .bearer)
        record(.ok(latencyMs: 5, model: nil), in: &book, for: first)
        record(.ok(latencyMs: 5, model: nil), in: &book, for: second)
        book.forget(slug: "a")
        XCTAssertNil(book.lastTest(for: first))
        XCTAssertNotNil(book.lastTest(for: second))
    }

    func testRecordingAgainReplacesTheResult() {
        var book = HealthBook()
        let profile = profile()
        record(.unauthorized, in: &book, for: profile)
        record(.ok(latencyMs: 5, model: nil), in: &book, for: profile, at: now.addingTimeInterval(1))
        XCTAssertEqual(book.lastTest(for: profile)?.outcome, .ok(latencyMs: 5, model: nil))
    }

    /// Records a result for the generation the profile has right now.
    private func record(
        _ outcome: ProbeOutcome,
        in book: inout HealthBook,
        for profile: Profile,
        at date: Date? = nil
    ) {
        book.record(outcome, at: date ?? now, for: profile, generation: book.generation(for: profile.slug))
    }
}
