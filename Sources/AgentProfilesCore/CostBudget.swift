import Foundation

/// How close the estimated cost of a window is to its limit.
public enum BudgetLevel: Int, Comparable, Codable, Sendable {
    /// Below 80% of the limit.
    case ok = 0
    /// 80% of the limit or more, but below the limit.
    case near = 1
    /// The limit or more.
    case over = 2

    public static func < (lhs: BudgetLevel, rhs: BudgetLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The two limits a profile can have.
public enum BudgetWindow: String, Codable, CaseIterable, Sendable {
    /// The local calendar day.
    case daily
    /// The local calendar month.
    case monthly
}

/// The estimated cost of one window against its limit.
public struct BudgetLimitStatus: Equatable, Sendable {
    /// The limit in USD.
    public var limit: Double
    /// The estimated cost of the window in USD. Always finite.
    public var spent: Double
    public var level: BudgetLevel

    /// The share of the limit that is spent, `1` being the whole limit. The
    /// number is finite and never negative; it can be above `1`.
    public var fraction: Double {
        let share = spent / limit
        guard share.isFinite else { return Double.greatestFiniteMagnitude }
        return max(0, share)
    }
}

/// The limits of one profile against its estimated cost.
public struct BudgetStatus: Equatable, Sendable {
    /// `nil` when the profile has no valid daily limit, or no way to price.
    public var day: BudgetLimitStatus?
    /// `nil` when the profile has no valid monthly limit, or no way to price.
    public var month: BudgetLimitStatus?

    public init(day: BudgetLimitStatus? = nil, month: BudgetLimitStatus? = nil) {
        self.day = day
        self.month = month
    }

    /// The worse of the two levels. `ok` when there is no limit.
    public var level: BudgetLevel {
        max(day?.level ?? .ok, month?.level ?? .ok)
    }

    /// The status of one window.
    public func status(of window: BudgetWindow) -> BudgetLimitStatus? {
        switch window {
        case .daily: return day
        case .monthly: return month
        }
    }
}

/// Cost limits per profile, from the estimated cost of the usage.
public enum CostBudget {
    /// The share of a limit from which the cost is "near" it.
    public static let nearFraction = 0.8

    /// A limit is valid when it is not set, or finite and above zero.
    public static func isValidBudget(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value > 0
    }

    /// The level of a cost against a limit. A limit that is not valid, or a
    /// cost that is not a finite number, is `ok`: nothing can be said.
    public static func level(spent: Double, limit: Double) -> BudgetLevel {
        guard limit.isFinite, limit > 0, spent.isFinite else { return .ok }
        if spent >= limit { return .over }
        if spent >= limit * nearFraction { return .near }
        return .ok
    }

    /// The status of a profile.
    ///
    /// The limits need both prices: without them there is no cost, so no
    /// limit is checked. A limit that is not valid is left out.
    public static func status(of profile: Profile, summary: UsageSummary) -> BudgetStatus {
        func window(_ totals: TokenTotals, limit: Double?) -> BudgetLimitStatus? {
            guard let limit, isValidBudget(limit),
                  let spent = UsageCost.estimate(
                      totals,
                      inputPerMillion: profile.priceInputPerMillion,
                      outputPerMillion: profile.priceOutputPerMillion
                  )
            else { return nil }
            return BudgetLimitStatus(limit: limit, spent: spent, level: level(spent: spent, limit: limit))
        }
        return BudgetStatus(
            day: window(summary.today, limit: profile.dailyBudgetUSD),
            month: window(summary.thisMonth, limit: profile.monthlyBudgetUSD)
        )
    }
}

/// A notification that is due: a profile crossed a line of a limit.
public struct BudgetNotice: Equatable, Sendable {
    public var slug: String
    public var window: BudgetWindow
    /// `near` or `over`, never `ok`.
    public var level: BudgetLevel
    /// The cost of the window in USD.
    public var spent: Double
    /// The limit in USD.
    public var limit: Double
}

/// What was already notified, so that a line of a limit is notified once.
///
/// For every profile and window the ledger remembers the day (or the month)
/// and the highest level that was notified in it. A new day or month starts
/// again. Going back below a line and crossing it again in the same period
/// does not notify a second time.
public struct BudgetNoticeLedger: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        /// `yyyy-MM-dd` for a day, `yyyy-MM` for a month.
        var period: String
        var level: BudgetLevel
    }

    /// The entries, by `slug|window`.
    private(set) var entries: [String: Entry] = [:]

    public init() {}

    private static func key(_ slug: String, _ window: BudgetWindow) -> String {
        "\(slug)|\(window.rawValue)"
    }

    /// The notifications that are due now, and remembers them.
    ///
    /// - Parameters:
    ///   - slug: the profile.
    ///   - status: its status.
    ///   - dayKey: `yyyy-MM-dd` of today in the local time zone.
    /// - Returns: at most one notice per window, for the highest line that
    ///   is crossed and was not notified in this period.
    public mutating func due(slug: String, status: BudgetStatus, dayKey: String) -> [BudgetNotice] {
        var notices: [BudgetNotice] = []
        for window in BudgetWindow.allCases {
            guard let limitStatus = status.status(of: window), limitStatus.level > .ok else { continue }
            let period = window == .daily ? dayKey : String(dayKey.prefix(7))
            let key = Self.key(slug, window)
            if let entry = entries[key], entry.period == period, entry.level >= limitStatus.level {
                continue
            }
            entries[key] = Entry(period: period, level: limitStatus.level)
            notices.append(BudgetNotice(
                slug: slug,
                window: window,
                level: limitStatus.level,
                spent: limitStatus.spent,
                limit: limitStatus.limit
            ))
        }
        return notices
    }

    /// Forgets what was notified for a profile.
    public mutating func forget(slug: String) {
        for window in BudgetWindow.allCases {
            entries[Self.key(slug, window)] = nil
        }
    }

    /// Keeps only the entries of the profiles that exist.
    public mutating func retain(slugs: Set<String>) {
        entries = entries.filter { key, _ in
            guard let separator = key.lastIndex(of: "|") else { return false }
            return slugs.contains(String(key[..<separator]))
        }
    }
}

/// The ledger on disk, next to the usage cache. The file holds profile slugs
/// and day keys, so only the owner may read it (mode 0600).
public struct BudgetNoticeStore: Sendable {
    /// The file name, under the data root.
    public static let fileName = "budget-notices.json"

    private let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    private var url: URL { paths.root.appendingPathComponent(Self.fileName) }

    /// The ledger of the file. A missing or damaged file gives an empty one.
    public func load() -> BudgetNoticeLedger {
        guard let bytes = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(BudgetNoticeLedger.self, from: bytes)
        else { return BudgetNoticeLedger() }
        return ledger
    }

    /// Writes the ledger atomically. A failure only means a notice can come twice.
    public func save(_ ledger: BudgetNoticeLedger) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(ledger) else { return }
        let manager = FileManager.default
        let temporary = paths.root.appendingPathComponent(
            "\(Self.fileName).\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        do {
            try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? manager.removeItem(at: temporary)
            try UsageScanner.writePrivate(bytes, to: temporary)
            guard rename(temporary.path, url.path) == 0 else {
                try? manager.removeItem(at: temporary)
                return
            }
        } catch {
            try? manager.removeItem(at: temporary)
        }
    }
}

extension BudgetNoticeLedger {
    /// The notifications that are due now, from the local clock.
    ///
    /// The day and the month are the ones of `calendar` at `now`.
    public mutating func due(
        slug: String,
        status: BudgetStatus,
        now: Date,
        calendar: Calendar = .current
    ) -> [BudgetNotice] {
        due(slug: slug, status: status, dayKey: UsageScanner.dayKey(now, calendar))
    }
}
