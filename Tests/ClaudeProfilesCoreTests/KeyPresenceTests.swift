import XCTest
@testable import ClaudeProfilesCore

/// The presence of the keys: a Keychain that cannot be read is not a profile
/// without a key.
final class KeyPresenceTests: XCTestCase {
    /// A profile with a key is present.
    func testAProfileWithAKeyIsPresent() {
        let result = KeyPresenceReader.read(slugs: ["work"], hasKey: { _ in true })
        XCTAssertEqual(result, ["work": .present])
    }

    /// A profile without a key is absent.
    func testAProfileWithoutAKeyIsAbsent() {
        let result = KeyPresenceReader.read(slugs: ["work"], hasKey: { _ in false })
        XCTAssertEqual(result, ["work": .absent])
    }

    /// Every profile is asked on its own.
    func testEveryProfileIsAskedOnItsOwn() {
        let result = KeyPresenceReader.read(slugs: ["a", "b"], hasKey: { $0 == "a" })
        XCTAssertEqual(result, ["a": .present, "b": .absent])
    }

    /// A Keychain that cannot be read is not "no key": the value that was known
    /// before is kept.
    func testAReadErrorKeepsTheValueThatWasKnownBefore() {
        let result = KeyPresenceReader.read(
            slugs: ["work"],
            hasKey: { _ in throw ProfileError.keychainReadFailed },
            previous: ["work": .present]
        )
        XCTAssertEqual(result, ["work": .present])
    }

    /// A profile that was never read and cannot be read now is unknown.
    func testAReadErrorWithoutAKnownValueIsUnknown() {
        let result = KeyPresenceReader.read(
            slugs: ["work"],
            hasKey: { _ in throw ProfileError.keychainReadFailed }
        )
        XCTAssertEqual(result, ["work": .unknown])
    }

    /// An unknown value is not "no key": the profile stays enabled.
    func testAnUnknownValueIsNotTheSameAsNoKey() {
        XCTAssertNotEqual(KeyPresence.unknown, KeyPresence.absent)
    }

    /// One profile that fails does not stop the others.
    func testOneFailingProfileDoesNotStopTheOthers() {
        let result = KeyPresenceReader.read(slugs: ["a", "b", "c"], hasKey: { slug in
            if slug == "b" { throw ProfileError.keychainReadFailed }
            return slug == "a"
        })
        XCTAssertEqual(result, ["a": .present, "b": .unknown, "c": .absent])
    }

    /// A profile without a credential is never asked for.
    func testOnlyTheGivenProfilesAreAsked() {
        var asked: [String] = []
        _ = KeyPresenceReader.read(slugs: ["a"], hasKey: { slug in
            asked.append(slug)
            return true
        })
        XCTAssertEqual(asked, ["a"])
    }
}
