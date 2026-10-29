import Foundation

/// A time of day on the clock of the Mac, without a date.
public struct ClockTime: Equatable, Hashable, Comparable, Sendable {
    public let hour: Int
    public let minute: Int

    /// `nil` when the hour is not 0...23 or the minute is not 0...59.
    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Reads `HH:mm` (`5:00` is accepted too). `nil` for anything else.
    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count <= 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// `HH:mm`, the form that is stored.
    public var text: String { String(format: "%02d:%02d", hour, minute) }

    /// When the 5 hour window that starts at this time is over.
    public var windowEnd: ClockTime {
        ClockTime(hour: (hour + Heartbeat.windowHours) % 24, minute: minute) ?? self
    }

    public static func < (lhs: ClockTime, rhs: ClockTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

/// A schedule that sends one short request through the CLI of a profile, so
/// that the 5 hour window of the subscription starts at a time the user chose
/// and not at the first real message of the day.
public struct Heartbeat: Equatable, Sendable {
    /// Length of the usage window of a subscription, in hours.
    public static let windowHours = 5
    /// More times than this are not kept.
    public static let maxTimes = 8

    public var enabled: Bool
    /// Times of day, on the clock of the Mac, sorted and without duplicates.
    public var times: [ClockTime]
    /// Days of the week, 1 = Monday ... 7 = Sunday. Empty means every day.
    public var days: Set<Int>

    public init(enabled: Bool = false, times: [ClockTime] = [], days: Set<Int> = []) {
        self.enabled = enabled
        self.times = Self.normalized(times)
        self.days = days.filter { (1...7).contains($0) }
    }

    /// What a new profile has: off, with no time yet.
    public static let off = Heartbeat()

    /// Sorted, without duplicates, cut to `maxTimes`.
    static func normalized(_ times: [ClockTime]) -> [ClockTime] {
        Array(Set(times).sorted().prefix(maxTimes))
    }

    /// `true` when the schedule can fire: it is on and holds at least one time.
    public var isActive: Bool { enabled && !times.isEmpty }

    /// The times of the stored form. Entries that are not `HH:mm` are dropped.
    static func times(from texts: [String]) -> [ClockTime] {
        normalized(texts.compactMap { ClockTime(text: $0) })
    }

    // MARK: - The file

    /// The JSON of the schedule, in the style of the rest of the file.
    func jsonText(indent: Int, escape: (String) -> String) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        var fields = ["\"enabled\": \(enabled)"]
        fields.append("\"times\": [" + times.map { escape($0.text) }.joined(separator: ", ") + "]")
        if !days.isEmpty {
            fields.append("\"days\": [" + days.sorted().map(String.init).joined(separator: ", ") + "]")
        }
        return "{\n" + fields.map { inner + $0 }.joined(separator: ",\n") + "\n\(pad)}"
    }
}

extension Heartbeat: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, times, days }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
            times: Self.times(from: (try? c.decode([String].self, forKey: .times)) ?? []),
            days: Set((try? c.decode([Int].self, forKey: .days)) ?? [])
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(times.map(\.text), forKey: .times)
        if !days.isEmpty { try c.encode(days.sorted(), forKey: .days) }
    }
}
