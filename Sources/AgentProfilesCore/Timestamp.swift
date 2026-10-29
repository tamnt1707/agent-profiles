import Foundation

/// The format of the timestamps in `profiles.json`.
///
/// The file is read by people as well, so the time is written in the usual
/// internet format: `2026-10-21T07:15:00Z`.
public enum Timestamp {
    /// A formatter for the internet date and time format.
    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// The text of a moment in time.
    public static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    /// The moment in time of a text, when it is one.
    public static func date(from text: String) -> Date? {
        formatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
