import Foundation

/// The rule of a value that the window writes through a binding.
///
/// SwiftUI can write a binding back with the value it already has. A setter
/// that takes such a value has to do nothing: writing it again changes the
/// model, the change invalidates the window, and the window writes the value
/// back again. The app then saves `profiles.json` over and over without the
/// user doing anything.
public enum SettingsChange {
    /// `true` when the value that comes from the window is not the value that
    /// is already stored.
    public static func isDifferent<T: Equatable>(_ stored: T, _ incoming: T) -> Bool {
        stored != incoming
    }

    /// `true` when the value that comes from the window is not the value that
    /// is already stored.
    ///
    /// A value that is not stored at all is different from every value that
    /// comes in, so the first write is never skipped.
    public static func isDifferent<T: Equatable>(_ stored: T?, _ incoming: T) -> Bool {
        stored != incoming
    }
}
