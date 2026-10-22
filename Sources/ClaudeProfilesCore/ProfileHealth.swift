import Foundation

/// The four states of the health dot in the sidebar.
public enum HealthState: String, Equatable, Sendable, CaseIterable {
    /// Green: the key is stored when one is needed, and the last test succeeded recently.
    case ready
    /// Grey: no problem is known, but no recent test succeeded.
    case untested
    /// Yellow: the last test was rate limited, or answered with a warning.
    case attention
    /// Red: a key is needed and none is stored, or the last test failed.
    case problem
}

/// Why a profile has its state. The app turns it into a localized sentence.
/// Nothing here carries the key or the provider's own text.
public enum HealthReason: Equatable, Sendable {
    case noKeyStored
    case connected(minutesAgo: Int)
    case notTested
    /// A test exists but is older than `ProfileHealth.freshWindow`.
    case staleTest(minutesAgo: Int)
    case testWarning(ProbeOutcome)
    case testFailed(ProbeOutcome)
}

/// The state of one profile and the reason for it.
public struct HealthStatus: Equatable, Sendable {
    public var state: HealthState
    public var reason: HealthReason

    public init(state: HealthState, reason: HealthReason) {
        self.state = state
        self.reason = reason
    }
}

/// The outcome of one test and the moment it was made. The provider's own
/// message is not kept: only the outcome is.
public struct TestRecord: Equatable, Sendable {
    public var outcome: ProbeOutcome
    public var testedAt: Date

    public init(outcome: ProbeOutcome, testedAt: Date) {
        self.outcome = outcome
        self.testedAt = testedAt
    }
}

/// Turns the facts about a profile into its health. Pure: no network, no
/// Keychain, no clock except the `now` that is passed in.
public enum ProfileHealth {
    /// A test older than this counts as not tested. Exactly this age is still fresh.
    public static let freshWindow: TimeInterval = 30 * 60

    /// - Parameters:
    ///   - hasKey: whether a key is stored (existence only, the secret is never read here).
    ///   - lastTest: the last test kept for this profile, if any.
    ///   - now: the current moment.
    public static func evaluate(profile: Profile, hasKey: Bool, lastTest: TestRecord?, now: Date) -> HealthStatus {
        if profile.auth != .none && !hasKey {
            return HealthStatus(state: .problem, reason: .noKeyStored)
        }
        guard let lastTest else {
            return HealthStatus(state: .untested, reason: .notTested)
        }
        let age = now.timeIntervalSince(lastTest.testedAt)
        let minutes = max(0, Int(age / 60))
        // A test from the future (the clock went back) is not trusted either.
        guard age >= 0, age <= freshWindow else {
            return HealthStatus(state: .untested, reason: .staleTest(minutesAgo: minutes))
        }
        switch lastTest.outcome.severity {
        case .success:
            return HealthStatus(state: .ready, reason: .connected(minutesAgo: minutes))
        case .warning:
            return HealthStatus(state: .attention, reason: .testWarning(lastTest.outcome))
        case .error:
            return HealthStatus(state: .problem, reason: .testFailed(lastTest.outcome))
        }
    }
}

/// The last test of each profile, kept in memory for this session only.
///
/// A result belongs to the Base URL and the auth kind it was made with: when
/// either one changes, the result is not returned. A changed key is handled by
/// `forget(slug:)`, which the app calls on save.
public struct HealthBook: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var baseURL: String
        var auth: AuthKind
        var test: TestRecord
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// Keeps the outcome of a test of `profile`, made at `date`.
    public mutating func record(_ outcome: ProbeOutcome, at date: Date, for profile: Profile) {
        entries[profile.slug] = Entry(
            baseURL: profile.baseURL,
            auth: profile.auth,
            test: TestRecord(outcome: outcome, testedAt: date)
        )
    }

    /// The last test of `profile`, or `nil` when none was kept or its Base URL or auth kind changed since.
    public func lastTest(for profile: Profile) -> TestRecord? {
        guard let entry = entries[profile.slug],
              entry.baseURL == profile.baseURL,
              entry.auth == profile.auth
        else { return nil }
        return entry.test
    }

    /// Drops the result of the profile with this slug (after a key change, a rename or a delete).
    public mutating func forget(slug: String) {
        entries[slug] = nil
    }
}
