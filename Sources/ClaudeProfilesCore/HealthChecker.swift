import Foundation

/// What one step of a health check found.
public enum HealthCheckStep: Equatable, Sendable {
    /// The provider was asked. `at` is the moment the answer came.
    case tested(slug: String, outcome: ProbeOutcome, at: Date)
    /// The profile needs a key and none is stored. Nothing was sent.
    case skipped(slug: String)
}

/// The profile of one request and the key that belongs to it.
///
/// They belong together: the key is the one of the profile, read at the same
/// moment. A request never carries the key of one provider to the URL of
/// another.
public struct HealthRequestInput: Equatable, Sendable {
    /// The profile as it is right now.
    public let profile: Profile
    /// The key of that profile. Empty when the auth kind needs no key.
    public let key: String

    public init(profile: Profile, key: String) {
        self.profile = profile
        self.key = key
    }
}

/// Tests the profiles of the sidebar, one request at a time.
///
/// The stored key is read only at the moment of each request, through the same
/// rules as "Test connection" (`ConnectionProbe.key`), and is never kept.
/// The probe and the clock are injectable for the tests.
@MainActor
public final class HealthChecker {
    /// Makes one request for a profile with a key (empty for auth kind none).
    public typealias Probe = @Sendable (Profile, String) async throws -> ProbeReport
    /// Reads the key of a profile. The text is empty when there is none.
    public typealias KeyReader = @Sendable (Profile) -> String

    private let probe: Probe
    private let now: @Sendable () -> Date
    private let readKey: KeyReader

    /// - Parameters:
    ///   - keys: where the stored keys are. Read only when a key is needed.
    ///   - probe: the request. Defaults to `ConnectionProbe.testConnection`.
    ///   - now: the clock that stamps each answer.
    ///   - readKey: reads the key of a profile. Defaults to the Keychain.
    public init(
        keys: KeyStore,
        probe: Probe? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        readKey: KeyReader? = nil
    ) {
        let connection = ConnectionProbe()
        self.probe = probe ?? { try await connection.testConnection(profile: $0, key: $1) }
        self.now = now
        self.readKey = readKey ?? { profile in
            (try? ConnectionProbe.key(
                typed: "", auth: profile.auth, account: profile.slug, keys: keys
            )) ?? ""
        }
    }

    /// Reads the profile of a request and the key that belongs to it, in one step.
    ///
    /// This function must stay synchronous: the profile, its generation and
    /// its key are read one after the other, without a suspension point in
    /// between, so no save can slip in between them. A key must never be
    /// read apart from the profile it belongs to: a request that carried the
    /// key of one provider to the URL of another would leak it.
    ///
    /// - Parameters:
    ///   - slug: the slug of the profile to test.
    ///   - capturedGeneration: the generation the profile had when the run began.
    ///   - currentProfile: the profile of a slug right now, `nil` when it is gone.
    ///   - generation: the generation of a slug right now.
    ///   - readKey: reads the key of a profile.
    /// - Returns: the profile and its key, or `nil` when the profile is gone,
    ///   when its settings changed since the run began, or when a key is
    ///   needed and none is stored.
    public func requestInput(
        slug: String,
        capturedGeneration: Int,
        currentProfile: (String) -> Profile?,
        generation: (String) -> Int,
        readKey: (Profile) -> String
    ) -> HealthRequestInput? {
        // The profile of this turn is read again: the one of the list may
        // be gone, or may describe other settings by now.
        guard let fresh = currentProfile(slug) else { return nil }
        guard generation(fresh.slug) == capturedGeneration else {
            // The settings changed while the run was going: nothing is sent.
            return nil
        }
        // The key and the URL come from the same, fresh profile: a request
        // never carries the key of one provider to the URL of another.
        let key = readKey(fresh)
        if fresh.auth != .none && key.isEmpty { return nil }
        return HealthRequestInput(profile: fresh, key: key)
    }

    /// Tests the profiles in order. `onStep` is called as each one finishes.
    ///
    /// A profile that needs a key with none stored is skipped without any
    /// request. So is a profile whose settings changed while the run was
    /// going: the answer of the old settings must not reach the new ones, and
    /// a key must never travel to the URL of another provider.
    /// The run stops before the next profile once the task is cancelled, and a
    /// request in flight is cancelled with it.
    ///
    /// Only the probe is awaited: the profile, its generation and its key are
    /// read in one synchronous step, so a save cannot slip in between them.
    ///
    /// - Parameters:
    ///   - profiles: the profiles to test, in order.
    ///   - currentProfile: the profile of a slug right now, `nil` when it is gone.
    ///   - generation: the generation of a slug right now.
    ///   - onStep: called as each profile finishes.
    public func run(
        profiles: [Profile],
        currentProfile: (String) -> Profile?,
        generation: (String) -> Int,
        onStep: (HealthCheckStep) -> Void
    ) async {
        // The generations of the whole run are taken at its start: a change
        // during the run has to be seen, not only a change before the turn of
        // a profile.
        var captured: [String: Int] = [:]
        for profile in profiles {
            captured[profile.slug] = generation(profile.slug)
        }

        for profile in profiles {
            guard !Task.isCancelled else { return }

            // The profile, its generation and its key are read in one
            // synchronous step: a save cannot slip in between them, so the
            // request always carries the key of the profile it is made for.
            guard let input = requestInput(
                slug: profile.slug,
                capturedGeneration: captured[profile.slug] ?? 0,
                currentProfile: currentProfile,
                generation: generation,
                readKey: { [readKey] profile in readKey(profile) }
            ) else {
                onStep(.skipped(slug: profile.slug))
                continue
            }

            do {
                let report = try await probe(input.profile, input.key)
                guard !Task.isCancelled else { return }
                onStep(.tested(slug: input.profile.slug, outcome: report.outcome, at: now()))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                // Every other error is a network problem. The text of the error
                // is not kept: it could hold the key or something of the
                // provider, and the dot only shows the kind of the problem.
                onStep(.tested(slug: input.profile.slug, outcome: .network(.other), at: now()))
            }
        }
    }
}
