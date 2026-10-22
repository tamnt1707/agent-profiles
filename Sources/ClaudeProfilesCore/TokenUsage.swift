import Foundation

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
    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
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
    case available(UsageSummary)
    case unavailable(UsageUnavailableReason)
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
    /// output tokens at the output price.
    public static func estimate(_ totals: TokenTotals, inputPerMillion: Double?, outputPerMillion: Double?) -> Double? {
        guard let inputPrice = inputPerMillion, let outputPrice = outputPerMillion,
              isValidPrice(inputPrice), isValidPrice(outputPrice)
        else {
            return nil
        }
        let inputTokens = Double(totals.input + totals.cacheRead + totals.cacheWrite)
        let outputTokens = Double(totals.output)
        return inputTokens * inputPrice / 1_000_000 + outputTokens * outputPrice / 1_000_000
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
        return scaled(Double(count) / 1_000_000, suffix: "M")
    }

    /// One decimal below 10, whole numbers above, and no trailing `.0`.
    private static func scaled(_ value: Double, suffix: String) -> String {
        let text = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
}
