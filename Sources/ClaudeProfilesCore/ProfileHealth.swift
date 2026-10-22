import Foundation

/// The four states of the health dot in the sidebar.
public enum HealthState: String, Equatable, Sendable, CaseIterable {
    /// Green: the key is stored when one is needed, and the last test succeeded recently.
    case ready
    /// Grey: no problem is known, but no recent test succeeded.
    case untested
    /// Orange: the last test was rate limited, or answered with a warning.
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
/// `profileSaved(old:new:typedKey:)`, which the app calls on save.
///
/// Every slug also has a generation. It rises when the settings of the profile
/// change: a new key, a new Base URL, a new auth kind, a new name or a delete.
/// A check that started before the change must not write its answer into the
/// dot of the new settings, so an answer always says which generation it was
/// made for.
public struct HealthBook: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        var baseURL: String
        var auth: AuthKind
        var test: TestRecord
    }

    private var entries: [String: Entry] = [:]
    private var generations: [String: Int] = [:]

    public init() {}

    /// The generation of a slug. It is 0 for a profile that never changed.
    public func generation(for slug: String) -> Int {
        generations[slug] ?? 0
    }

    /// Marks the settings of the profile as changed. Every answer that was
    /// made for the old settings is refused from now on.
    public mutating func bump(slug: String) {
        generations[slug, default: 0] += 1
    }

    /// Keeps the outcome of a test of `profile`, made at `date`.
    ///
    /// The result is kept only when the profile still exists (`profile` is
    /// `nil` when it is gone) and when the generation of its slug is still the
    /// one the test was made for. A test of an older setting describes
    /// something else, so it is dropped and `false` is returned.
    @discardableResult
    public mutating func record(
        _ outcome: ProbeOutcome,
        at date: Date,
        for profile: Profile?,
        generation: Int
    ) -> Bool {
        guard let profile else { return false }
        guard self.generation(for: profile.slug) == generation else { return false }
        entries[profile.slug] = Entry(
            baseURL: profile.baseURL,
            auth: profile.auth,
            test: TestRecord(outcome: outcome, testedAt: date)
        )
        return true
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

    /// The profile was saved with these settings.
    ///
    /// The result of the old settings is dropped and the generation rises when
    /// the settings changed: a typed key, a new Base URL, a new auth kind or a
    /// new name. A rename moves the old name too.
    public mutating func profileSaved(old: Profile?, new: Profile, typedKey: String) {
        if let old, old.slug != new.slug {
            forget(slug: old.slug)
            bump(slug: old.slug)
        }
        if HealthInvalidation.shouldForget(old: old, new: new, typedKey: typedKey) {
            forget(slug: new.slug)
            bump(slug: new.slug)
        }
    }

    /// The profile is gone.
    ///
    /// The result is dropped and the generation rises, so an answer of a
    /// running check cannot come back for it, not even for a profile that is
    /// added again with the same name.
    public mutating func profileDeleted(slug: String) {
        forget(slug: slug)
        bump(slug: slug)
    }

    /// `true` when the result of the editor's "Test connection" may go into the dot.
    ///
    /// The test is about the saved profile only when no key was typed: a typed
    /// key is not stored yet, so the test says nothing about the saved key.
    /// The Base URL and the auth kind of the draft must be the ones of the
    /// saved profile too, otherwise the test was made against another
    /// provider. A profile that was never saved has no saved settings that
    /// the test could describe.
    public static func canRecordEditorTest(draft: Profile, saved: Profile?, typedKey: String) -> Bool {
        guard let saved else { return false }
        guard typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return draft.baseURL == saved.baseURL && draft.auth == saved.auth
    }
}
