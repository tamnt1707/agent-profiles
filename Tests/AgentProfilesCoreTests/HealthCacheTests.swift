import XCTest
@testable import AgentProfilesCore

/// The last tests are kept on disk, and are only good for the settings they were made with.
final class HealthCacheTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ slug: String = "a", baseURL: String = "https://api.example.com") -> Profile {
        Profile(name: slug, slug: slug, baseURL: baseURL, auth: .bearer, model: "m", isolate: true)
    }

    // MARK: - Fingerprint

    func testTheFingerprintFollowsWhatATestDependsOn() {
        let base = profile()
        let print = HealthBook.fingerprint(of: base)
        XCTAssertEqual(print, HealthBook.fingerprint(of: base))
        XCTAssertEqual(print.count, 64)

        var changed = base; changed.baseURL = "https://other.example.com"
        XCTAssertNotEqual(print, HealthBook.fingerprint(of: changed))
        changed = base; changed.auth = .apiKey
        XCTAssertNotEqual(print, HealthBook.fingerprint(of: changed))
        changed = base; changed.model = "other[1m]"
        XCTAssertNotEqual(print, HealthBook.fingerprint(of: changed))
        changed = base; changed.extraEnv = "A=1"
        XCTAssertNotEqual(print, HealthBook.fingerprint(of: changed))
        changed = base; changed.isolate = false
        XCTAssertNotEqual(print, HealthBook.fingerprint(of: changed))
        // What a test does not depend on does not change it.
        changed = base; changed.name = "Renamed"; changed.workdir = "/x"; changed.recentDirs = ["/y"]
        XCTAssertEqual(print, HealthBook.fingerprint(of: changed))
    }

    func testTheFingerprintHidesTheExtraEnvironment() {
        var p = profile()
        p.extraEnv = "TOKEN=super-secret-token"
        XCTAssertFalse(HealthBook.fingerprint(of: p).contains("secret"))
    }

    // MARK: - Book

    func testAChangedModelDropsTheResult() {
        var book = HealthBook()
        let before = profile()
        book.record(.ok(latencyMs: 1, model: nil), at: when, for: before, generation: 0)
        XCTAssertNotNil(book.lastTest(for: before))
        var after = before; after.model = "another"
        XCTAssertNil(book.lastTest(for: after))
        XCTAssertTrue(HealthInvalidation.shouldForget(old: before, new: after, typedKey: ""))
    }

    func testARenameAloneKeepsTheResult() {
        let before = profile()
        var after = before; after.name = "New name"
        XCTAssertFalse(HealthInvalidation.shouldForget(old: before, new: after, typedKey: ""))
    }

    // MARK: - Round trip

    func testRestoreGivesBackWhatWasStored() {
        var book = HealthBook()
        let a = profile("a"), b = profile("b")
        book.record(.ok(latencyMs: 42, model: "m1"), at: when, for: a, generation: 0)
        book.record(.network(.dns), at: when, for: b, generation: 0)

        var restored = HealthBook()
        restored.restore(book.storedTests, profiles: [a, b])
        XCTAssertEqual(restored.lastTest(for: a), TestRecord(outcome: .ok(latencyMs: 42, model: "m1"), testedAt: when))
        XCTAssertEqual(restored.lastTest(for: b)?.outcome, .network(.dns))
    }

    func testRestoreKeepsOnlyWhatStillDescribesAProfile() {
        var book = HealthBook()
        let a = profile("a"), gone = profile("gone")
        book.record(.ok(latencyMs: 1, model: nil), at: when, for: a, generation: 0)
        book.record(.ok(latencyMs: 1, model: nil), at: when, for: gone, generation: 0)

        var changedA = a; changedA.baseURL = "https://moved.example.com"
        var restored = HealthBook()
        restored.restore(book.storedTests, profiles: [changedA])
        XCTAssertNil(restored.lastTest(for: changedA), "the settings changed since")
        XCTAssertNil(restored.lastTest(for: gone), "the profile is gone")
    }

    func testEveryOutcomeSurvivesTheFile() {
        let outcomes: [ProbeOutcome] = [
            .ok(latencyMs: 9, model: nil), .ok(latencyMs: 9, model: "x"), .unauthorized, .forbidden, .notFound,
            .modelNotFound, .rateLimited, .serverError(502), .unexpectedStatus(418), .timeout,
            .network(.dns), .network(.offline), .network(.tls), .network(.other), .invalidURL, .insecureURL,
            .missingKey, .crossHostRedirect, .unsupported, .cliLogin, .cliNotFound, .notLoggedIn, .cliFailed,
        ]
        for outcome in outcomes {
            XCTAssertEqual(StoredOutcome(outcome).outcome, outcome, "\(outcome)")
        }
    }

    func testAnUnknownKindIsDropped() {
        XCTAssertNil(StoredOutcome(kind: "fromTheFuture", code: nil, model: nil, problem: nil).outcome)
    }

    // MARK: - The file

    func testTheFileRoundTripsAndHoldsNoSecret() throws {
        let temp = try TempDirectory()
        let paths = temp.paths()
        let store = HealthCacheStore(paths: paths)
        XCTAssertEqual(store.load(), [:])

        var book = HealthBook()
        var p = profile()
        p.extraEnv = "TOKEN=super-secret-token"
        book.record(.ok(latencyMs: 5, model: "m"), at: when, for: p, generation: 0)
        store.save(book.storedTests)

        let text = try String(contentsOf: paths.root.appendingPathComponent(HealthCacheStore.fileName), encoding: .utf8)
        XCTAssertFalse(text.contains("super-secret"))
        XCTAssertEqual(store.load(), book.storedTests)
    }

    func testABrokenFileIsReadAsEmpty() throws {
        let temp = try TempDirectory()
        let paths = temp.paths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try "not json".write(to: paths.root.appendingPathComponent(HealthCacheStore.fileName), atomically: true, encoding: .utf8)
        XCTAssertEqual(HealthCacheStore(paths: paths).load(), [:])
    }
}
