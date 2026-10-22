import XCTest
@testable import ClaudeProfilesCore

/// The rules that decide when a result may be shown, and when it must be
/// dropped: the editor's test, the result of a changed profile and the
/// presence of a key that could not be read.
final class HealthInvalidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(
        _ slug: String = "a",
        auth: AuthKind = .bearer,
        baseURL: String = "https://api.example.com"
    ) -> Profile {
        Profile(name: slug, slug: slug, baseURL: baseURL, auth: auth)
    }

    // MARK: - The editor's "Test connection"

    func testTheEditorTestIsKeptWhenItWasMadeWithTheSavedSettings() {
        let saved = profile()
        XCTAssertTrue(HealthBook.canRecordEditorTest(draft: saved, saved: saved, typedKey: ""))
    }

    func testTheEditorTestIsDroppedWhenAKeyWasTyped() {
        let saved = profile()
        XCTAssertFalse(HealthBook.canRecordEditorTest(draft: saved, saved: saved, typedKey: "sk-typed"))
    }

    func testTheEditorTestIsDroppedWhenTheBaseURLChanged() {
        let saved = profile()
        let draft = profile(baseURL: "https://other.example.com")
        XCTAssertFalse(HealthBook.canRecordEditorTest(draft: draft, saved: saved, typedKey: ""))
    }

    func testTheEditorTestIsDroppedWhenTheAuthKindChanged() {
        let saved = profile(auth: .bearer)
        let draft = profile(auth: .apiKey)
        XCTAssertFalse(HealthBook.canRecordEditorTest(draft: draft, saved: saved, typedKey: ""))
    }

    func testTheEditorTestOfANewProfileIsDropped() {
        let draft = profile()
        XCTAssertFalse(HealthBook.canRecordEditorTest(draft: draft, saved: nil, typedKey: ""))
    }

    func testWhitespaceIsNoTypedKey() {
        let saved = profile()
        XCTAssertTrue(HealthBook.canRecordEditorTest(draft: saved, saved: saved, typedKey: "   "))
    }

    // MARK: - When a result stops describing a profile

    func testATypedKeyDropsTheResult() {
        XCTAssertTrue(HealthInvalidation.shouldForget(old: profile(), new: profile(), typedKey: "sk-typed"))
    }

    func testANewBaseURLDropsTheResult() {
        let old = profile(baseURL: "https://old.example.com")
        let new = profile(baseURL: "https://new.example.com")
        XCTAssertTrue(HealthInvalidation.shouldForget(old: old, new: new, typedKey: ""))
    }

    func testANewAuthKindDropsTheResult() {
        XCTAssertTrue(HealthInvalidation.shouldForget(old: profile(auth: .bearer), new: profile(auth: .apiKey), typedKey: ""))
    }

    func testANewNameDropsTheResult() {
        XCTAssertTrue(HealthInvalidation.shouldForget(old: profile("a"), new: profile("b"), typedKey: ""))
    }

    func testNothingRelevantChangedKeepsTheResult() {
        XCTAssertFalse(HealthInvalidation.shouldForget(old: profile(), new: profile(), typedKey: ""))
    }

    func testOnlyTheNameOfTheProfileChangedKeepsTheResult() {
        var old = profile("a")
        old.name = "Work"
        var new = profile("a")
        new.name = "Personal"
        XCTAssertFalse(HealthInvalidation.shouldForget(old: old, new: new, typedKey: ""),
                       "only the name of the profile changed, the test still describes it")
    }

    func testAProfileThatWasNeverSavedHasNoResultToKeep() {
        XCTAssertTrue(HealthInvalidation.shouldForget(old: nil, new: profile(), typedKey: ""))
    }

    // MARK: - The presence of a key that could not be read

    func testAReadKeyIsTaken() {
        let merged = KeyPresence.merge(slugs: ["a"], previous: [:], read: ["a": .read(true)])
        XCTAssertEqual(merged, ["a": true])
    }

    func testAFailedReadKeepsTheValueThatWasKnown() {
        let merged = KeyPresence.merge(slugs: ["a"], previous: ["a": true], read: ["a": .failed])
        XCTAssertEqual(merged, ["a": true], "a Keychain that cannot be read said that the key is gone")
    }

    func testAFailedReadKeepsAKeyThatWasNotThere() {
        let merged = KeyPresence.merge(slugs: ["a"], previous: ["a": false], read: ["a": .failed])
        XCTAssertEqual(merged, ["a": false])
    }

    func testAProfileWhosePresenceIsUnknownStaysUnknown() {
        let merged = KeyPresence.merge(slugs: ["a"], previous: [:], read: ["a": .failed])
        XCTAssertTrue(merged.isEmpty, "an unknown presence was written as a missing key")
    }

    func testAProfileThatIsGoneIsNotInTheMap() {
        let merged = KeyPresence.merge(slugs: [], previous: ["a": true], read: ["a": .read(true)])
        XCTAssertTrue(merged.isEmpty, "the presence of a deleted profile is still known")
    }

    func testTheNewValueWinsOverTheOldOne() {
        let merged = KeyPresence.merge(slugs: ["a"], previous: ["a": true], read: ["a": .read(false)])
        XCTAssertEqual(merged, ["a": false])
    }
}
