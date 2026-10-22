import Foundation

/// The rule of the `show_menu_bar` field of `profiles.json`.
///
/// The launcher in the menu bar is shown by default, so the field is written
/// only when it is turned off: a file that never changed the setting stays
/// exactly as it was.
public enum MenuBarSetting {
    /// The launcher is shown when the file says nothing about it.
    public static let isShownByDefault = true

    /// `true` when the field has to be written to the file.
    public static func isWritten(_ show: Bool) -> Bool {
        !show
    }

    /// The value of the setting: what the file says, or the default.
    public static func value(stored: Bool?) -> Bool {
        stored ?? isShownByDefault
    }

    /// The text of the field for the file. Empty when it is not written.
    public static func json(_ show: Bool) -> String {
        isWritten(show) ? ",\n  \"show_menu_bar\": false" : ""
    }
}
