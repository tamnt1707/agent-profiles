import XCTest
@testable import ClaudeProfilesCore

/// The rule of the `show_menu_bar` field: it is written only when the menu bar
/// is turned off.
final class MenuBarSettingTests: XCTestCase {
    /// The launcher is shown when the file says nothing about it.
    func testTheDefaultIsShown() {
        XCTAssertTrue(MenuBarSetting.isShownByDefault)
        XCTAssertTrue(MenuBarSetting.value(stored: nil))
    }

    /// What the file says wins over the default.
    func testTheStoredValueWins() {
        XCTAssertFalse(MenuBarSetting.value(stored: false))
        XCTAssertTrue(MenuBarSetting.value(stored: true))
    }

    /// The default is not written: a file that never changed the setting stays
    /// as it was.
    func testTheDefaultIsNotWritten() {
        XCTAssertFalse(MenuBarSetting.isWritten(true))
        XCTAssertEqual(MenuBarSetting.json(true), "")
    }

    /// Turning the menu bar off is written.
    func testTurningItOffIsWritten() {
        XCTAssertTrue(MenuBarSetting.isWritten(false))
        XCTAssertEqual(MenuBarSetting.json(false), ",\n  \"show_menu_bar\": false")
    }

    /// The text of the field is the same as the one the store writes.
    func testTheTextIsTheSameAsTheOneOfTheStore() throws {
        let temp = try TempDirectory()
        let store = Store(paths: temp.paths(), keys: InMemoryKeyStore())
        try store.save(AppData(showMenuBar: false))
        let text = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertTrue(text.contains(MenuBarSetting.json(false)), text)
    }
}
