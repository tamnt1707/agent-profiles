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
    /// request. The run stops before the next profile once the task is
    /// cancelled, and a request in flight is cancelled with it.
    public func run(profiles: [Profile], onStep: (HealthCheckStep) -> Void) async {
        for profile in profiles {
            guard !Task.isCancelled else { return }

            let key = (try? ConnectionProbe.key(
                typed: "", auth: profile.auth, account: profile.slug, keys: keys
            )) ?? ""
            if profile.auth != .none && key.isEmpty {
                onStep(.skipped(slug: profile.slug))
                continue
            }

            do {
                let report = try await probe(profile, key)
                guard !Task.isCancelled else { return }
                onStep(.tested(slug: profile.slug, outcome: report.outcome, at: now()))
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                onStep(.tested(slug: profile.slug, outcome: .network(.other), at: now()))
            }
        }
    }
}
