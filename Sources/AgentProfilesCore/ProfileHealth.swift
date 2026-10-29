import CryptoKit
import Foundation

/// The four states of the health dot in the sidebar.
public enum HealthState: String, Equatable, Sendable, CaseIterable {
    /// Green: the key is stored when one is needed, and the last test succeeded.
    case ready
    /// Grey: no problem is known, but the profile was never tested.
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
    /// The Keychain could not be read. Nothing is known about the key.
    case keychainUnreadable
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
    /// - Parameters:
    ///   - key: what is known about the stored key of the profile.
    ///   - lastTest: the last test kept for this profile, if any.
    ///   - now: the current moment.
    public static func evaluate(profile: Profile, key: KeyState, lastTest: TestRecord?, now: Date) -> HealthStatus {
        // The Keychain could not be read: nothing is known about the key.
        // That is not a missing key, and it is not a stored one either, so
        // the dot says that the Keychain could not be read.
        if profile.auth != .none, key == .unreadable {
            return HealthStatus(state: .untested, reason: .keychainUnreadable)
        }
        // A key that is needed and not stored is a problem. A presence that
        // was never read says nothing at all: it is not a missing key.
        if profile.auth != .none, key == .missing {
            return HealthStatus(state: .problem, reason: .noKeyStored)
        }
        guard let lastTest else {
            return HealthStatus(state: .untested, reason: .notTested)
        }
        // The last result stays until the settings change or the profile is tested
        // again: it is kept on disk, and an old result is still the last thing known.
        // A clock that went back makes an age below zero: it counts as just now.
        let minutes = max(0, Int(now.timeIntervalSince(lastTest.testedAt) / 60))
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
///
/// The settings of every profile are remembered, also the ones of a profile
/// that was never tested: a profile whose settings changed while the list was
/// read again has to get a new generation, or an answer of a running check
/// would land in the dot of the new settings.
public struct HealthBook: Equatable, Sendable {
    private struct Entry: Equatable, Sendable {
        /// The settings the test was made with: see `fingerprint(of:)`.
        var fingerprint: String
        var test: TestRecord
    }

    /// The settings a slug was last seen with.
    ///
    /// They are kept for every profile, also for one that was never tested:
    /// the generation of a profile that changed has to rise, so an answer of
    /// a running check cannot land in the dot of the new settings.
    private var entries: [String: Entry] = [:]
    private var settings: [String: String] = [:]
    private var generations: [String: Int] = [:]

    public init() {}

    /// What a test depends on, as one string: the address, the way of signing in,
    /// the model names, the extra environment and the config folder. A test is
    /// only good for the profile that has the same fingerprint.
    ///
    /// It is a hash, so the extra environment (which can hold a token) is never
    /// written to the cache file as it is.
    public static func fingerprint(of profile: Profile) -> String {
        let fields = [
            profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            profile.auth.rawValue,
            profile.model, profile.opusModel, profile.sonnetModel, profile.haikuModel,
            profile.extraEnv,
            profile.isolate ? "isolated" : "shared",
            profile.agent.rawValue,
        ]
        let joined = fields.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

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
            fingerprint: Self.fingerprint(of: profile),
            test: TestRecord(outcome: outcome, testedAt: date)
        )
        return true
    }

    /// The tests that are kept, for the cache file.
    public var storedTests: [String: StoredTest] {
        entries.mapValues {
            StoredTest(fingerprint: $0.fingerprint, outcome: StoredOutcome($0.test.outcome), testedAt: $0.test.testedAt)
        }
    }

    /// The tests of a cache file, kept for the profiles they still describe.
    ///
    /// A test is taken only when the profile exists and has the settings it was
    /// made with. The settings of every profile are remembered, as for a list that was read.
    public mutating func restore(_ tests: [String: StoredTest], profiles: [Profile]) {
        for profile in profiles {
            let current = Self.fingerprint(of: profile)
            settings[profile.slug] = current
            if let stored = tests[profile.slug], stored.fingerprint == current,
               let outcome = stored.outcome.outcome {
                entries[profile.slug] = Entry(
                    fingerprint: current,
                    test: TestRecord(outcome: outcome, testedAt: stored.testedAt)
                )
            }
        }
    }

    /// The last test of `profile`, or `nil` when none was kept or its Base URL or auth kind changed since.
    public func lastTest(for profile: Profile) -> TestRecord? {
        guard let entry = entries[profile.slug],
              entry.fingerprint == Self.fingerprint(of: profile)
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
            settings[old.slug] = nil
        }
        if HealthInvalidation.shouldForget(old: old, new: new, typedKey: typedKey) {
            forget(slug: new.slug)
            bump(slug: new.slug)
        }
        settings[new.slug] = Self.fingerprint(of: new)
    }

    /// The profile is gone.
    ///
    /// The result is dropped and the generation rises, so an answer of a
    /// running check cannot come back for it, not even for a profile that is
    /// added again with the same name.
    public mutating func profileDeleted(slug: String) {
        forget(slug: slug)
        bump(slug: slug)
        settings[slug] = nil
    }

    /// The list of the profiles was read again.
    ///
    /// A result that does not describe the profile of the list any more is
    /// dropped: a profile that is gone keeps nothing, and a profile whose Base
    /// URL or auth kind changed keeps no result either. The generation of
    /// every profile that changed rises, so an answer of a running check
    /// cannot land in the dot of the new settings.
    ///
    /// A profile that was never tested has no result, but its settings are
    /// known: they are compared too, so the generation of a profile that
    /// changed while it was never tested rises as well.
    public mutating func profilesLoaded(_ profiles: [Profile]) {
        let loaded = Dictionary(profiles.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        // A profile that is gone: its result is dropped and its generation
        // rises, so an answer of a running check cannot come back for it.
        for slug in Array(settings.keys) where loaded[slug] == nil {
            forget(slug: slug)
            bump(slug: slug)
            settings[slug] = nil
        }
        // A profile that is still there but changed: the result describes
        // another provider or another account. A profile that was never tested
        // has no result, but its generation rises too: an answer of a running
        // check is about the old settings.
        for profile in profiles {
            let current = Self.fingerprint(of: profile)
            if let known = settings[profile.slug], known != current {
                forget(slug: profile.slug)
                bump(slug: profile.slug)
            }
            settings[profile.slug] = current
        }
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
        return fingerprint(of: draft) == fingerprint(of: saved)
    }
}
