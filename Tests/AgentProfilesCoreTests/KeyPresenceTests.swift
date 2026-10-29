import XCTest
@testable import AgentProfilesCore

/// The presence of the stored keys: what the Keychain said, and the read that
/// says it. Two reads can be on their way at the same time, so the older one
/// must not overwrite the newer one.
final class KeyPresenceTests: XCTestCase {
    // MARK: - The state of a key

    func testAReadKeyIsTaken() {
        var book = KeyPresenceBook()
        let sequence = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .read(true)], sequence: sequence)
        XCTAssertEqual(book.state(for: "a"), .stored)
    }

    func testAReadThatSaysThereIsNoKeyIsMissing() {
        var book = KeyPresenceBook()
        let sequence = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .read(false)], sequence: sequence)
        XCTAssertEqual(book.state(for: "a"), .missing)
    }

    func testAFailedReadSaysThatTheKeychainCouldNotBeRead() {
        var book = KeyPresenceBook()
        let sequence = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .failed], sequence: sequence)
        XCTAssertEqual(book.state(for: "a"), .unreadable,
                       "a Keychain that cannot be read said that the key is gone")
    }

    func testAProfileWhosePresenceWasNeverReadIsUnknown() {
        let book = KeyPresenceBook()
        XCTAssertEqual(book.state(for: "a"), .unknown,
                       "a presence that was never read is not a missing key")
    }

    func testTheNewValueWinsOverTheOldOne() {
        var book = KeyPresenceBook()
        let first = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .read(true)], sequence: first)
        let second = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .read(false)], sequence: second)
        XCTAssertEqual(book.state(for: "a"), .missing)
    }

    // MARK: - The order of the reads

    func testAnOlderReadThatComesBackLateIsDropped() {
        var book = KeyPresenceBook()
        let older = book.nextSequence()
        let newer = book.nextSequence()
        XCTAssertTrue(book.merge(slugs: ["a"], read: ["a": .read(true)], sequence: newer))
        XCTAssertFalse(book.merge(slugs: ["a"], read: ["a": .read(false)], sequence: older),
                       "an older read overwrote the newer one")
        XCTAssertEqual(book.state(for: "a"), .stored)
    }

    func testEveryReadGetsANewerNumber() {
        var book = KeyPresenceBook()
        let first = book.nextSequence()
        let second = book.nextSequence()
        let third = book.nextSequence()
        XCTAssertTrue(second > first)
        XCTAssertTrue(third > second)
    }

    func testTheSameReadTwiceIsDropped() {
        var book = KeyPresenceBook()
        let sequence = book.nextSequence()
        XCTAssertTrue(book.merge(slugs: ["a"], read: ["a": .read(true)], sequence: sequence))
        XCTAssertFalse(book.merge(slugs: ["a"], read: ["a": .read(false)], sequence: sequence))
        XCTAssertEqual(book.state(for: "a"), .stored)
    }

    // MARK: - A profile that is gone

    func testAProfileThatIsGoneIsNotKept() {
        var book = KeyPresenceBook()
        let first = book.nextSequence()
        book.merge(slugs: ["a"], read: ["a": .read(true)], sequence: first)
        let second = book.nextSequence()
        book.merge(slugs: ["b"], read: ["b": .read(true)], sequence: second)
        XCTAssertEqual(book.state(for: "a"), .unknown, "the presence of a deleted profile is still known")
        XCTAssertEqual(book.state(for: "b"), .stored)
    }

    func testAReadOfAProfileThatIsGoneIsNotKept() {
        var book = KeyPresenceBook()
        let sequence = book.nextSequence()
        book.merge(slugs: ["a", "b"], read: ["a": .read(true), "b": .read(true)], sequence: sequence)
        XCTAssertEqual(book.state(for: "a"), .stored)
        XCTAssertEqual(book.state(for: "b"), .stored)
    }

    // MARK: - The read of the Keychain

    /// A profile with a key is stored.
    func testAProfileWithAKeyIsStored() async {
        let read = await KeyPresence.read(slugs: ["work"], hasKey: { _ in true })
        XCTAssertEqual(read, ["work": .read(true)])
    }

    /// A profile without a key is missing.
    func testAProfileWithoutAKeyIsMissing() async {
        let read = await KeyPresence.read(slugs: ["work"], hasKey: { _ in false })
        XCTAssertEqual(read, ["work": .read(false)])
    }

    /// Every profile is asked on its own.
    func testEveryProfileIsAskedOnItsOwn() async {
        let read = await KeyPresence.read(slugs: ["a", "b"], hasKey: { $0 == "a" })
        XCTAssertEqual(read, ["a": .read(true), "b": .read(false)])
    }

    /// A Keychain that cannot be read is not "no key": the state says that the
    /// Keychain could not be read, and the profile is never shown as one
    /// without a key.
    func testAReadErrorIsNotAMissingKey() async {
        let read = await KeyPresence.read(
            slugs: ["work"],
            hasKey: { _ in throw ProfileError.keychainReadFailed }
        )
        var book = KeyPresenceBook()
        book.merge(slugs: ["work"], read: read, sequence: book.nextSequence())
        XCTAssertEqual(book.state(for: "work"), .unreadable)
        XCTAssertNotEqual(book.state(for: "work"), .missing,
                          "a Keychain that cannot be read said that the key is gone")
    }

    /// A value that is not known is not "no key": the profile stays enabled.
    func testAnUnknownValueIsNotTheSameAsNoKey() {
        XCTAssertNotEqual(KeyState.unknown, KeyState.missing)
        XCTAssertNotEqual(KeyState.unreadable, KeyState.missing)
    }

    /// One profile that fails does not stop the others.
    func testOneFailingProfileDoesNotStopTheOthers() async {
        let read = await KeyPresence.read(slugs: ["a", "b", "c"], hasKey: { slug in
            if slug == "b" { throw ProfileError.keychainReadFailed }
            return slug == "a"
        })
        var book = KeyPresenceBook()
        book.merge(slugs: ["a", "b", "c"], read: read, sequence: book.nextSequence())
        XCTAssertEqual(book.state(for: "a"), .stored)
        XCTAssertEqual(book.state(for: "b"), .unreadable)
        XCTAssertEqual(book.state(for: "c"), .missing)
    }

    /// A profile without a credential is never asked for.
    func testOnlyTheGivenProfilesAreAsked() async {
        let asked = AskedSlugs()
        _ = await KeyPresence.read(slugs: ["a"], hasKey: { slug in
            asked.record(slug)
            return true
        })
        XCTAssertEqual(asked.all, ["a"])
    }
}

/// Remembers which slugs were asked, from another thread.
private final class AskedSlugs: @unchecked Sendable {
    private let lock = NSLock()
    private var slugs: [String] = []

    func record(_ slug: String) {
        lock.lock()
        defer { lock.unlock() }
        slugs.append(slug)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return slugs
    }
}
