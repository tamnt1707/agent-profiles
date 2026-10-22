import XCTest
@testable import ClaudeProfilesCore

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
}
