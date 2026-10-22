import XCTest
@testable import ClaudeProfilesCore

/// The rule of a value that the window writes through a binding.
///
/// SwiftUI can write a binding back with the value it already has. The
/// setters have to leave the model alone when that happens, or the window
/// asks for another pass and the app saves `profiles.json` over and over.
final class SettingsChangeTests: XCTestCase {
    /// The value that is already there is not a change.
    func testTheValueThatIsAlreadyThereIsNotAChange() {
        XCTAssertFalse(SettingsChange.isDifferent(true, true))
        XCTAssertFalse(SettingsChange.isDifferent(false, false))
        XCTAssertFalse(SettingsChange.isDifferent("en", "en"))
        XCTAssertFalse(SettingsChange.isDifferent(TerminalApp.terminal, .terminal))
        XCTAssertFalse(SettingsChange.isDifferent(AppLanguage.system, .system))
        XCTAssertFalse(SettingsChange.isDifferent(AppearanceMode.dark, .dark))
    }

    /// Another value is a change.
    func testAnotherValueIsAChange() {
        XCTAssertTrue(SettingsChange.isDifferent(true, false))
        XCTAssertTrue(SettingsChange.isDifferent(false, true))
        XCTAssertTrue(SettingsChange.isDifferent("en", "vi"))
        XCTAssertTrue(SettingsChange.isDifferent(TerminalApp.terminal, .iTerm))
        XCTAssertTrue(SettingsChange.isDifferent(AppLanguage.system, .en))
        XCTAssertTrue(SettingsChange.isDifferent(AppearanceMode.dark, .light))
    }

    /// A value that is not stored yet is a change: the first write is never
    /// skipped.
    func testAMissingValueIsAChange() {
        let missing: String? = nil
        XCTAssertTrue(SettingsChange.isDifferent(missing, "en"))
        XCTAssertTrue(SettingsChange.isDifferent(missing, ""))
    }

    /// A value that is stored is compared with the one that comes in.
    func testAStoredValueIsComparedWithTheOneThatComesIn() {
        let stored: String? = "en"
        XCTAssertFalse(SettingsChange.isDifferent(stored, "en"))
        XCTAssertTrue(SettingsChange.isDifferent(stored, "vi"))
    }

    /// A value that may be missing is compared with the one that comes in.
    func testAMissingNumberAndANumberAreCompared() {
        let missing: Double? = nil
        let price: Double? = 1.5
        XCTAssertTrue(SettingsChange.isDifferent(missing, price))
        XCTAssertFalse(SettingsChange.isDifferent(price, price))
        XCTAssertTrue(SettingsChange.isDifferent(price, 2.5))
        XCTAssertTrue(SettingsChange.isDifferent(missing, 1.5))
    }
}
