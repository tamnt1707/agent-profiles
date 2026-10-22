import Foundation

/// What one step of a health check found.
public enum HealthCheckStep: Equatable, Sendable {
    /// The provider was asked. `at` is the moment the answer came.
    case tested(slug: String, outcome: ProbeOutcome, at: Date)
    /// The profile needs a key and none is stored. Nothing was sent.
    case skipped(slug: String)
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

    private let keys: KeyStore
    private let probe: Probe
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - probe: the request. Defaults to `ConnectionProbe.testConnection`.
    ///   - now: the clock that stamps each answer.
    public init(keys: KeyStore, probe: Probe? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        let connection = ConnectionProbe()
        self.keys = keys
        self.probe = probe ?? { try await connection.testConnection(profile: $0, key: $1) }
        self.now = now
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

            // The profile of this turn is read again: the one of the list may
            // be gone, or may describe other settings by now.
            guard let fresh = currentProfile(profile.slug) else {
                onStep(.skipped(slug: profile.slug))
                continue
            }
            guard generation(fresh.slug) == captured[profile.slug] else {
                // The settings changed while the run was going: nothing is sent.
                onStep(.skipped(slug: profile.slug))
                continue
            }

            // The key and the URL come from the same, fresh profile: a request
            // never carries the key of one provider to the URL of another.
            let key = (try? ConnectionProbe.key(
                typed: "", auth: fresh.auth, account: fresh.slug, keys: keys
            )) ?? ""
            if fresh.auth != .none && key.isEmpty {
                onStep(.skipped(slug: profile.slug))
                continue
            }

            do {
                let report = try await probe(fresh, key)
                guard !Task.isCancelled else { return }
                onStep(.tested(slug: fresh.slug, outcome: report.outcome, at: now()))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                // Every other error is a network problem. The text of the error
                // is not kept: it could hold the key or something of the
                // provider, and the dot only shows the kind of the problem.
                onStep(.tested(slug: fresh.slug, outcome: .network(.other), at: now()))
            }
        }
    }
}
