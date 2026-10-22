import XCTest
@testable import ClaudeProfilesCore

/// The order of the reads of one request.
///
/// The profile, its generation and its key are read one after the other,
/// without a suspension point in between, so no save can slip in between
/// them. A key must never travel to the URL of another provider.
final class HealthRequestOrderTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// What was read, and for which slug.
    private enum Read: Equatable {
        case profile(String)
        case generation(String)
        case key(String)
        case probe(String)
    }

    /// Records every read of a run, in the order it happened.
    private final class Order: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Read] = []

        func append(_ read: Read) {
            lock.withLock { values.append(read) }
        }

        /// The reads before the first profile is read. The generations of the
        /// whole run are captured there.
        var capture: [Read] {
            var values: [Read] = []
            for read in all {
                guard case .profile = read else {
                    values.append(read)
                    continue
                }
                break
            }
            return values
        }

        /// The reads of every profile, in order. Each group starts with the
        /// read of the profile itself.
        var perProfile: [[Read]] {
            var groups: [[Read]] = []
            for read in all {
                if case .profile = read {
                    groups.append([read])
                } else if !groups.isEmpty {
                    groups[groups.count - 1].append(read)
                }
            }
            return groups
        }

        private var all: [Read] { lock.withLock { values } }
    }

    /// Records every request: the profile and the key it got.
    private final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(slug: String, baseURL: String, key: String)] = []

        func begin(_ profile: Profile, key: String) {
            lock.withLock { calls.append((profile.slug, profile.baseURL, key)) }
        }
    }

    /// The profiles of the world while a check runs. They change in the
    /// middle of the run, like they do when the user saves a profile.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var profiles: [Profile]
        private var generations: [String: Int] = [:]

        init(_ profiles: [Profile]) {
            self.profiles = profiles
        }

        /// The profile of a slug, as it is right now.
        func current(_ slug: String) -> Profile? {
            lock.withLock { profiles.first { $0.slug == slug } }
        }

        /// The generation of a slug, as it is right now.
        func generation(_ slug: String) -> Int {
            lock.withLock { generations[slug] ?? 0 }
        }

        /// The user saves the profile with another Base URL.
        func save(_ profile: Profile) {
            lock.withLock {
                if let index = profiles.firstIndex(where: { $0.slug == profile.slug }) {
                    profiles[index] = profile
                } else {
                    profiles.append(profile)
                }
                generations[profile.slug, default: 0] += 1
            }
        }
    }

    /// A key store whose read changes the world, like a save that slips in
    /// while the key is read.
    private final class InterleavingKeyStore: KeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String]
        private let onRead: (String) -> Void

        init(keys: [String: String], onRead: @escaping (String) -> Void) {
            self.storage = keys
            self.onRead = onRead
        }

        func get(_ account: String) throws -> String? {
            let value = lock.withLock { storage[account] }
            // The save happens in the middle of the read of the key.
            onRead(account)
            return value
        }

        func hasKey(_ account: String) throws -> Bool {
            lock.withLock { storage[account] != nil }
        }

        func set(_ account: String, key: String) throws {
            lock.withLock { storage[account] = key }
        }

        func delete(_ account: String) throws {
            lock.withLock { _ = storage.removeValue(forKey: account) }
        }
    }

    private func profile(
        _ slug: String,
        auth: AuthKind = .bearer,
        baseURL: String = "https://api.example.com"
    ) -> Profile {
        Profile(name: slug, slug: slug, baseURL: baseURL, auth: auth)
    }

    private func keyStore(_ pairs: [String: String]) throws -> InMemoryKeyStore {
        let keys = InMemoryKeyStore()
        for (slug, key) in pairs {
            try keys.set(slug, key: key)
        }
        return keys
    }

    // MARK: - The order of the reads

    @MainActor
    func testEveryProfileIsReadProfileGenerationKeyProbe() async throws {
        let order = Order()
        let keys = try keyStore(["a": "sk-a", "b": "sk-b"])
        let checker = HealthChecker(
            keys: keys,
            probe: { profile, _ in
                order.append(.probe(profile.slug))
                return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
            },
            now: { self.fixedNow },
            readKey: { profile in
                order.append(.key(profile.slug))
                return (try? keys.get(profile.slug)) ?? ""
            }
        )
        let profiles = [profile("a"), profile("b")]

        await checker.run(
            profiles: profiles,
            currentProfile: { slug in
                order.append(.profile(slug))
                return profiles.first { $0.slug == slug }
            },
            generation: { slug in
                order.append(.generation(slug))
                return 0
            }
        ) { _ in }

        XCTAssertEqual(order.capture, [.generation("a"), .generation("b")],
                       "the generations of the run are not captured first")
        XCTAssertEqual(order.perProfile, [
            [.profile("a"), .generation("a"), .key("a"), .probe("a")],
            [.profile("b"), .generation("b"), .key("b"), .probe("b")],
        ], "the reads of a request are not in the order profile, generation, key, probe")
    }

    @MainActor
    func testTheKeyOfAProfileIsReadAfterItsGeneration() async throws {
        let order = Order()
        let keys = try keyStore(["a": "sk-a"])
        let checker = HealthChecker(
            keys: keys,
            probe: { profile, _ in
                order.append(.probe(profile.slug))
                return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
            },
            now: { self.fixedNow },
            readKey: { profile in
                order.append(.key(profile.slug))
                return (try? keys.get(profile.slug)) ?? ""
            }
        )

        await checker.run(
            profiles: [profile("a")],
            currentProfile: { slug in
                order.append(.profile(slug))
                return self.profile(slug)
            },
            generation: { slug in
                order.append(.generation(slug))
                return 0
            }
        ) { _ in }

        XCTAssertEqual(order.perProfile, [[.profile("a"), .generation("a"), .key("a"), .probe("a")]])
    }

    // MARK: - A save that slips in between the reads

    @MainActor
    func testTheRequestKeepsTheProfileAndTheKeyOfOnePairWhenASaveSlipsIn() async throws {
        let world = World([profile("a", baseURL: "https://old.example.com")])
        let keys = InterleavingKeyStore(keys: ["a": "sk-old"]) { _ in
            // The user saves the profile while the key is read: the profile
            // points at another provider from now on.
            world.save(self.profile("a", baseURL: "https://new.example.com"))
        }
        let probes = Probes()
        let checker = HealthChecker(
            keys: keys,
            probe: { profile, key in
                probes.begin(profile, key: key)
                return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
            },
            now: { self.fixedNow }
        )

        await checker.run(
            profiles: [profile("a", baseURL: "https://old.example.com")],
            currentProfile: { world.current($0) },
            generation: { world.generation($0) }
        ) { _ in }

        XCTAssertEqual(probes.calls.count, 1)
        XCTAssertEqual(probes.calls[0].baseURL, "https://old.example.com",
                       "the request used a profile that was not read together with the key")
        XCTAssertEqual(probes.calls[0].key, "sk-old",
                       "the request carried a key that does not belong to the profile it was made for")
    }

    @MainActor
    func testTheKeyIsReadForTheAccountOfTheProfileThatWasRead() async throws {
        let world = World([profile("a")])
        let accounts = Accounts()
        let keys = InterleavingKeyStore(keys: ["a": "sk-a"]) { account in
            accounts.append(account)
        }
        let checker = HealthChecker(
            keys: keys,
            probe: { _, _ in ProbeReport(outcome: .ok(latencyMs: 1, model: nil)) },
            now: { self.fixedNow }
        )

        await checker.run(
            profiles: [profile("a")],
            currentProfile: { world.current($0) },
            generation: { world.generation($0) }
        ) { _ in }

        XCTAssertEqual(accounts.all, ["a"], "the key was read for another account")
    }

    /// The accounts the keys were read for.
    private final class Accounts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ account: String) {
            lock.withLock { values.append(account) }
        }

        var all: [String] { lock.withLock { values } }
    }
}
