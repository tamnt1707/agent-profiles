import XCTest
@testable import ClaudeProfilesCore

/// The generation rules of a health check: a profile that changes while the
/// check runs is never tested with the settings of another one, and the answer
/// of an older setting never reaches the dot of a newer one.
final class HealthGenerationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(
        _ slug: String,
        auth: AuthKind = .bearer,
        baseURL: String = "https://api.example.com"
    ) -> Profile {
        Profile(name: slug, slug: slug, baseURL: baseURL, auth: auth)
    }

    /// The state of the profiles while a check runs. It changes in the middle
    /// of the run, like it does when the user saves, renames or deletes a
    /// profile.
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

        /// The user saves the profile. The generation rises for the names it
        /// touches, unless the list of names is empty.
        func save(_ profile: Profile, bump names: [String]? = nil) {
            lock.withLock {
                if let index = profiles.firstIndex(where: { $0.slug == profile.slug }) {
                    profiles[index] = profile
                } else {
                    profiles.append(profile)
                }
                for name in names ?? [profile.slug] {
                    generations[name, default: 0] += 1
                }
            }
        }

        /// The user deletes the profile.
        func delete(_ slug: String) {
            lock.withLock {
                profiles.removeAll { $0.slug == slug }
                generations[slug, default: 0] += 1
            }
        }

        /// The user renames the profile. The old name and the new one both move.
        func rename(from old: String, to new: String) {
            lock.withLock {
                guard let index = profiles.firstIndex(where: { $0.slug == old }) else { return }
                profiles[index].slug = new
                generations[old, default: 0] += 1
                generations[new, default: 0] += 1
            }
        }
    }

    /// Records every request: the profile, the URL and the key it got.
    private final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(slug: String, baseURL: String, key: String)] = []

        func begin(_ profile: Profile, key: String) {
            lock.withLock { calls.append((profile.slug, profile.baseURL, key)) }
        }
    }

    private func keyStore(_ pairs: [String: String]) throws -> InMemoryKeyStore {
        let keys = InMemoryKeyStore()
        for (slug, key) in pairs {
            try keys.set(slug, key: key)
        }
        return keys
    }

    /// Runs a check over the world and returns the steps it reported.
    @MainActor
    private func runCheck(
        _ checker: HealthChecker,
        world: World,
        profiles: [Profile]
    ) async -> [HealthCheckStep] {
        var steps: [HealthCheckStep] = []
        await checker.run(
            profiles: profiles,
            currentProfile: { world.current($0) },
            generation: { world.generation($0) }
        ) { steps.append($0) }
        return steps
    }

    // MARK: - The generation itself

    func testTheGenerationStartsAtZeroAndRisesWithEveryChange() {
        var book = HealthBook()
        XCTAssertEqual(book.generation(for: "a"), 0)
        book.bump(slug: "a")
        XCTAssertEqual(book.generation(for: "a"), 1)
        book.bump(slug: "a")
        XCTAssertEqual(book.generation(for: "a"), 2)
        XCTAssertEqual(book.generation(for: "b"), 0, "the generation of another profile moved")
    }

    func testSavingAProfileWithOtherSettingsRaisesItsGeneration() {
        var book = HealthBook()
        let old = profile("a")
        var new = profile("a")
        new.baseURL = "https://other.example.com"
        book.profileSaved(old: old, new: new, typedKey: "")
        XCTAssertEqual(book.generation(for: "a"), 1)
    }

    func testSavingAProfileWithoutOtherSettingsKeepsItsGeneration() {
        var book = HealthBook()
        let old = profile("a")
        book.profileSaved(old: old, new: profile("a"), typedKey: "")
        XCTAssertEqual(book.generation(for: "a"), 0)
    }

    func testARenameRaisesTheGenerationOfBothNames() {
        var book = HealthBook()
        let old = profile("a")
        let new = profile("b")
        book.profileSaved(old: old, new: new, typedKey: "")
        XCTAssertEqual(book.generation(for: "a"), 1, "the old name did not move")
        XCTAssertEqual(book.generation(for: "b"), 1, "the new name did not move")
    }

    func testDeletingAProfileRaisesItsGenerationAndDropsItsResult() {
        var book = HealthBook()
        let tested = self.profile("a")
        let generation = book.generation(for: "a")
        book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: tested, generation: generation)
        XCTAssertNotNil(book.lastTest(for: tested))

        book.profileDeleted(slug: "a")

        XCTAssertEqual(book.generation(for: "a"), 1, "the generation of a deleted profile did not move")
        XCTAssertNil(book.lastTest(for: tested))
    }

    // MARK: - The answer of an older setting

    func testAnAnswerOfTheCurrentGenerationIsRecorded() {
        var book = HealthBook()
        let tested = self.profile("a")
        let generation = book.generation(for: "a")
        XCTAssertTrue(book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: tested, generation: generation))
        XCTAssertNotNil(book.lastTest(for: tested))
    }

    func testAnAnswerOfAnOlderGenerationIsNotRecorded() {
        var book = HealthBook()
        let tested = self.profile("a")
        let generation = book.generation(for: "a")
        // The user saves a new key while the request is on its way.
        book.bump(slug: "a")
        XCTAssertFalse(book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: tested, generation: generation))
        XCTAssertNil(book.lastTest(for: tested), "the answer of an older key reached the dot")
    }

    func testAnAnswerOfAProfileThatIsGoneIsNotRecorded() {
        var book = HealthBook()
        let tested = self.profile("a")
        let generation = book.generation(for: "a")
        XCTAssertFalse(book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: nil, generation: generation))
        XCTAssertNil(book.lastTest(for: tested))
    }

    // MARK: - The check itself

    @MainActor
    func testAProfileSavedDuringTheRunIsNotTested() async throws {
        let world = World([profile("a"), profile("b")])
        let keys = try keyStore(["a": "sk-a", "b": "sk-b"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            if tested.slug == "a" {
                // The user saves profile b with another URL and another key.
                world.save(self.profile("b", baseURL: "https://other.example.com"))
                try? keys.set("b", key: "sk-b-new")
            }
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })

        let steps = await runCheck(checker, world: world, profiles: [profile("a"), profile("b")])

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "the changed profile was tested")
        XCTAssertEqual(steps, [
            .tested(slug: "a", outcome: .ok(latencyMs: 1, model: nil), at: fixedNow),
            .skipped(slug: "b"),
        ])
    }

    @MainActor
    func testTheRequestUsesTheProfileAndTheKeyOfThisMoment() async throws {
        let world = World([profile("b", baseURL: "https://old.example.com")])
        let keys = try keyStore(["b": "sk-old"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })
        // The profile and its key changed without the generation moving: the
        // request still has to use the profile of this moment and its own key.
        world.save(profile("b", baseURL: "https://new.example.com"), bump: [])
        try keys.set("b", key: "sk-new")

        await runCheck(checker, world: world, profiles: [profile("b", baseURL: "https://old.example.com")])

        XCTAssertEqual(probes.calls.count, 1)
        XCTAssertEqual(probes.calls[0].baseURL, "https://new.example.com", "the request went to the old URL")
        XCTAssertEqual(probes.calls[0].key, "sk-new", "the request carried another key")
    }

    @MainActor
    func testAProfileDeletedDuringTheRunIsNotTested() async throws {
        let world = World([profile("a"), profile("b")])
        let keys = try keyStore(["a": "sk-a", "b": "sk-b"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            if tested.slug == "a" {
                world.delete("b")
            }
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })

        let steps = await runCheck(checker, world: world, profiles: [profile("a"), profile("b")])

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "the deleted profile was tested")
        XCTAssertEqual(steps, [
            .tested(slug: "a", outcome: .ok(latencyMs: 1, model: nil), at: fixedNow),
            .skipped(slug: "b"),
        ])
    }

    @MainActor
    func testAnAuthNoneProfileDeletedDuringTheRunSendsNothing() async throws {
        let world = World([profile("a"), profile("b", auth: .none)])
        let keys = try keyStore(["a": "sk-a"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            if tested.slug == "a" {
                world.delete("b")
            }
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })

        await runCheck(checker, world: world, profiles: [profile("a"), profile("b", auth: .none)])

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "the deleted profile was asked anyway")
    }

    @MainActor
    func testAProfileAddedAgainWithTheSameNameIsNotTested() async throws {
        let world = World([profile("a"), profile("b")])
        let keys = try keyStore(["a": "sk-a", "b": "sk-b"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            if tested.slug == "a" {
                // The user deletes profile b and adds it again with the same
                // name, the same URL and the same auth kind.
                world.delete("b")
                world.save(self.profile("b"))
            }
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })

        let steps = await runCheck(checker, world: world, profiles: [profile("a"), profile("b")])

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "the profile that came back was tested")
        XCTAssertEqual(steps.last, .skipped(slug: "b"))
    }

    @MainActor
    func testTheResultOfADeletedProfileIsNotKeptForTheProfileThatComesBack() async throws {
        var book = HealthBook()
        let again = self.profile("b")
        let generation = book.generation(for: "b")
        let world = World([again])

        // The user deletes the profile and adds it again with the same name.
        world.delete("b")
        world.save(again)
        book.profileDeleted(slug: "b")
        book.profileSaved(old: nil, new: again, typedKey: "")

        XCTAssertFalse(
            book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: world.current("b"), generation: generation),
            "the answer of the old profile was kept for the new one"
        )
        XCTAssertNil(book.lastTest(for: again))
    }

    @MainActor
    func testAProfileRenamedDuringTheRunIsNotTested() async throws {
        let world = World([profile("a"), profile("b")])
        let keys = try keyStore(["a": "sk-a", "b": "sk-b"])
        let probes = Probes()
        let checker = HealthChecker(keys: keys, probe: { tested, key in
            probes.begin(tested, key: key)
            if tested.slug == "a" {
                world.rename(from: "b", to: "c")
            }
            return ProbeReport(outcome: .ok(latencyMs: 1, model: nil))
        }, now: { self.fixedNow })

        let steps = await runCheck(checker, world: world, profiles: [profile("a"), profile("b")])

        XCTAssertEqual(probes.calls.map { $0.slug }, ["a"], "the renamed profile was tested")
        XCTAssertEqual(steps.last, .skipped(slug: "b"))
    }

    @MainActor
    func testTheResultOfARenamedProfileIsNotKeptForTheNewName() async throws {
        var book = HealthBook()
        let old = self.profile("b")
        let generation = book.generation(for: "b")

        book.profileSaved(old: old, new: self.profile("c"), typedKey: "")

        XCTAssertFalse(
            book.record(.ok(latencyMs: 1, model: nil), at: fixedNow, for: self.profile("c"), generation: generation),
            "the answer of the old name was kept for the new one"
        )
        XCTAssertNil(book.lastTest(for: self.profile("c")))
    }
}
