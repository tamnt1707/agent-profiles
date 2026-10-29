import Foundation

/// Adds two numbers without trapping.
///
/// A sum that does not fit becomes the largest (or the smallest) possible
/// number instead of crashing the app.
func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard overflow else { return result }
    return rhs >= 0 ? Int.max : Int.min
}

/// Token counts of one or more replies, as the provider reports them.
public struct TokenTotals: Equatable, Sendable, Codable {
    /// `input_tokens`
    public var input: Int
    /// `output_tokens`
    public var output: Int
    /// `cache_read_input_tokens`
    public var cacheRead: Int
    /// `cache_creation_input_tokens`
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// Every token of the four kinds.
    ///
    /// The sum never traps: a sum that does not fit becomes the largest
    /// possible number.
    public var total: Int {
        saturatedAdd(saturatedAdd(saturatedAdd(input, output), cacheRead), cacheWrite)
    }

    /// The larger of the two totals, counter by counter.
    ///
    /// A reply that is written several times to the same file can be counted
    /// once, with the largest numbers of all its lines: a line that was
    /// written completely later wins over a partial one.
    public func merged(with other: TokenTotals) -> TokenTotals {
        TokenTotals(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite)
        )
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs.input = saturatedAdd(lhs.input, rhs.input)
        lhs.output = saturatedAdd(lhs.output, rhs.output)
        lhs.cacheRead = saturatedAdd(lhs.cacheRead, rhs.cacheRead)
        lhs.cacheWrite = saturatedAdd(lhs.cacheWrite, rhs.cacheWrite)
    }
}

/// The usage of one profile in the three windows the editor shows.
public struct UsageSummary: Equatable, Sendable {
    /// The local calendar day of `now`.
    public var today: TokenTotals
    /// The local calendar day of `now` and the six days before it.
    public var last7Days: TokenTotals
    /// Every reply that was read, including the ones without a timestamp.
    public var allTime: TokenTotals

    public init(today: TokenTotals = TokenTotals(), last7Days: TokenTotals = TokenTotals(), allTime: TokenTotals = TokenTotals()) {
        self.today = today
        self.last7Days = last7Days
        self.allTime = allTime
    }
}

/// Why a profile has no usage to show.
public enum UsageUnavailableReason: Equatable, Sendable {
    /// The profile shares `~/.claude`, so its sessions are not kept apart.
    case notIsolated
    /// The configuration folder of the profile does not exist.
    case folderMissing
}

/// The outcome of counting the usage of one profile.
public enum UsageResult: Equatable, Sendable {
    /// The usage, and the number of files that could not be read.
    case available(UsageSummary, skippedFiles: Int)
    case unavailable(UsageUnavailableReason)
}

/// The state of the counts of the usage, one for every profile.
///
/// A count can be started, stopped and started again. The numbers of the last
/// count that finished stay visible when a count is stopped: the count shows
/// what it had, and a note that it was stopped.
public struct UsageScanStates: Equatable, Sendable {
    /// The profiles whose usage is being counted right now.
    private var running: Set<String> = []
    /// The profiles whose count was stopped. Their numbers stay.
    private var stopped: Set<String> = []

    public init() {}

    /// `true` while the usage of the profile is being counted.
    public func isRunning(_ slug: String) -> Bool {
        running.contains(slug)
    }

    /// `true` when the last count of the profile was stopped.
    public func isStopped(_ slug: String) -> Bool {
        stopped.contains(slug)
    }

    /// A count of the profile starts. The note of a stopped count is gone.
    public mutating func start(_ slug: String) {
        running.insert(slug)
        stopped.remove(slug)
    }

    /// The count of the profile is done: there is no count and no note.
    public mutating func finish(_ slug: String) {
        running.remove(slug)
        stopped.remove(slug)
    }

    /// The count of the profile was stopped. The numbers stay, and the note of
    /// a stopped count is there.
    public mutating func stop(_ slug: String) {
        running.remove(slug)
        stopped.insert(slug)
    }

    /// The profile is gone, or its numbers do not hold any more.
    public mutating func forget(_ slug: String) {
        running.remove(slug)
        stopped.remove(slug)
    }
}

/// Estimated cost from the optional prices of a profile.
public enum UsageCost {
    /// A price is valid when it is not set, or finite and zero or more.
    public static func isValidPrice(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0
    }

    /// The estimated cost in USD, or `nil` unless both prices are set and valid.
    ///
    /// Input and cache tokens (reads and writes) are priced at the input price;
    /// output tokens at the output price. The result is always a finite
    /// number: a cost that does not fit becomes the largest one there is.
    public static func estimate(_ totals: TokenTotals, inputPerMillion: Double?, outputPerMillion: Double?) -> Double? {
        guard let inputPrice = inputPerMillion, let outputPrice = outputPerMillion,
              isValidPrice(inputPrice), isValidPrice(outputPrice)
        else {
            return nil
        }
        // The tokens are turned into doubles one by one: the sum of the counts
        // would trap when the counts are huge.
        let inputTokens = Double(totals.input) + Double(totals.cacheRead) + Double(totals.cacheWrite)
        let outputTokens = Double(totals.output)
        let cost = inputTokens * inputPrice / 1_000_000 + outputTokens * outputPrice / 1_000_000
        guard cost.isFinite else {
            return cost.isNaN ? 0 : Double.greatestFiniteMagnitude
        }
        return cost
    }

    /// The biggest cost that is written as money.
    ///
    /// A cost that is bigger is only a bound: a price of 1e300 would print
    /// three hundred digits and the line of the cost would not fit anywhere.
    public static let maximumWrittenCost: Double = 1_000_000_000

    /// The text that stands for a cost that is too big to be written.
    public static let tooLargeText = "—"

    /// The cost as money in US dollars, written the way the language of the
    /// user writes it: `$1,234.56` in English, `1.234,56 US$` in Vietnamese.
    ///
    /// A cost that is bigger than `maximumWrittenCost`, or a cost that is not a
    /// number, is written as a dash: the line stays short.
    public static func format(_ cost: Double, locale: Locale = .current) -> String {
        guard cost.isFinite, cost <= maximumWrittenCost else { return tooLargeText }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: cost)) ?? tooLargeText
    }
}

/// Short text for token counts: `850`, `12K`, `1.2M`.
public enum TokenFormat {
    public static func compact(_ count: Int) -> String {
        if count < 1_000 {
            return "\(count)"
        }
        // From 999 500 on, "%.0f" of the thousands would read "1000K", so those read as millions.
        if count < 999_500 {
            return scaled(Double(count) / 1_000, suffix: "K")
        }
        // From 999 500 000 on, the millions would read "1000M", so those read as billions.
        if count < 999_500_000 {
            return scaled(Double(count) / 1_000_000, suffix: "M")
        }
        return scaled(Double(count) / 1_000_000_000, suffix: "B")
    }

    /// The whole number, written the way the language of the user writes it:
    /// `1,234,567` in English, `1.234.567` in Vietnamese.
    public static func number(_ count: Int, locale: Locale = .current) -> String {
        count.formatted(.number.locale(locale))
    }

    /// One decimal below 10, whole numbers above, and no trailing `.0`.
    private static func scaled(_ value: Double, suffix: String) -> String {
        let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
}
