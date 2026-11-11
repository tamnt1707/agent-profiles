import XCTest
@testable import AgentProfilesCore

/// Records the logins that were removed. Never touches a real Keychain.
final class RecordingLoginStore: ClaudeLoginStore, @unchecked Sendable {
    private(set) var removed: [String] = []
    /// When set, every removal fails.
    var fails = false

    func removeLogin(configDir: String) throws -> Bool {
        if fails { throw ProfileError.keychainWriteFailed }
        removed.append(configDir)
        return true
    }
}

/// Answers for `security` like the real tool would, without running it.
private final class SecurityStub: ProcessRunner, @unchecked Sendable {
    /// How many items each service holds.
    var items: [String: Int] = [:]
    /// The status of a removal that finds an item (0 is success).
    var removalStatus: Int32 = 0
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        XCTAssertEqual(executable, "/usr/bin/security")
        calls.append(arguments)
        guard let index = arguments.firstIndex(of: "-s"), index + 1 < arguments.count else {
            return ProcessResult(status: 1)
        }
        let service = arguments[index + 1]
        guard let count = items[service], count > 0 else { return ProcessResult(status: 44) }
        if removalStatus == 0 { items[service] = count - 1 }
        return ProcessResult(status: removalStatus)
    }
}

final class ClaudeLoginTests: XCTestCase {
    // MARK: - The service name

    func testTheServiceIsTheHashOfTheFolderPath() {
        // Taken from the Keychain of a real machine: Claude Code named the
        // items of these two folders this way.
        XCTAssertEqual(
            ClaudeLogin.service(forConfigDir: "/Users/tamnt/.claude-profiles/homes/2"),
            "Claude Code-credentials-56d58803"
        )
        XCTAssertEqual(
            ClaudeLogin.service(forConfigDir: "/Users/tamnt/.claude"),
            "Claude Code-credentials-791d2776"
        )
    }

    func testThePathIsHashedExactlyAsItIsExported() {
        XCTAssertNotEqual(
            ClaudeLogin.service(forConfigDir: "/Users/tamnt/.claude-profiles/homes/2/"),
            "Claude Code-credentials-56d58803"
        )
    }

    // MARK: - The removal with `security`

    private let root = URL(fileURLWithPath: "/Users/someone/.claude-profiles/homes", isDirectory: true)

    private func loginStore(_ stub: SecurityStub) -> SecurityToolLoginStore {
        SecurityToolLoginStore(allowedRoot: root, account: "someone", runner: stub)
    }

    func testTheLoginOfAProfileFolderIsRemoved() throws {
        let folder = root.appendingPathComponent("work").path
        let service = ClaudeLogin.service(forConfigDir: folder)
        let stub = SecurityStub()
        stub.items = [service: 1]

        XCTAssertTrue(try loginStore(stub).removeLogin(configDir: folder))
        XCTAssertEqual(stub.items[service], 0)
        XCTAssertEqual(stub.calls.first, ["delete-generic-password", "-s", service, "-a", "someone"])
    }

    func testEveryCopyOfTheLoginIsRemoved() throws {
        let folder = root.appendingPathComponent("work").path
        let service = ClaudeLogin.service(forConfigDir: folder)
        let stub = SecurityStub()
        stub.items = [service: 2]

        XCTAssertTrue(try loginStore(stub).removeLogin(configDir: folder))
        XCTAssertEqual(stub.items[service], 0)
    }

    func testNoLoginIsNotAnError() throws {
        let stub = SecurityStub()
        XCTAssertFalse(try loginStore(stub).removeLogin(configDir: root.appendingPathComponent("work").path))
    }

    func testAFolderOutsideTheProfileFoldersIsNeverTouched() throws {
        let stub = SecurityStub()
        let store = loginStore(stub)
        XCTAssertFalse(try store.removeLogin(configDir: "/Users/someone/.claude"))
        XCTAssertFalse(try store.removeLogin(configDir: root.path))
        XCTAssertFalse(try store.removeLogin(configDir: root.appendingPathComponent("../../.claude").path))
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testThePlainServiceIsNeverRemoved() throws {
        let stub = SecurityStub()
        stub.items = [ClaudeLogin.defaultService: 1]
        _ = try loginStore(stub).removeLogin(configDir: root.appendingPathComponent("work").path)
        XCTAssertEqual(stub.items[ClaudeLogin.defaultService], 1)
        XCTAssertFalse(stub.calls.contains { $0.contains(ClaudeLogin.defaultService) })
    }

    func testARefusedRemovalThrows() {
        let folder = root.appendingPathComponent("work").path
        let stub = SecurityStub()
        stub.items = [ClaudeLogin.service(forConfigDir: folder): 1]
        stub.removalStatus = 51
        XCTAssertThrowsError(try loginStore(stub).removeLogin(configDir: folder))
    }

    // MARK: - The store

    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    func testRemovingAProfileRemovesItsLogin() throws {
        let logins = RecordingLoginStore()
        let store = Store(paths: paths, keys: InMemoryKeyStore(), logins: logins)
        let profile = Profile.sample(name: "Work", slug: "work")
        try store.materialize(profile)

        let report = try store.remove(profile)

        XCTAssertEqual(logins.removed, [paths.home(for: "work").path])
        XCTAssertTrue(report.removedLogin)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testAFailedLoginRemovalIsReportedAndTheRestIsStillRemoved() throws {
        let logins = RecordingLoginStore()
        logins.fails = true
        let store = Store(paths: paths, keys: InMemoryKeyStore(), logins: logins)
        let profile = Profile.sample(name: "Work", slug: "work")
        try store.materialize(profile)

        let report = try store.remove(profile)

        let service = ClaudeLogin.service(forConfigDir: paths.home(for: "work").path)
        XCTAssertEqual(report.failures, [.login(service)])
        XCTAssertFalse(report.removedLogin)
        XCTAssertTrue(report.removedHome)
        XCTAssertTrue(report.removedScript)
    }

    func testTheDefaultProfileKeepsItsLogin() {
        let logins = RecordingLoginStore()
        let store = Store(paths: paths, keys: InMemoryKeyStore(), logins: logins)
        XCTAssertThrowsError(try store.remove(.defaultClaude))
        XCTAssertTrue(logins.removed.isEmpty)
    }

    func testARenameRemovesTheLoginOfTheOldFolder() throws {
        let logins = RecordingLoginStore()
        let store = Store(paths: paths, keys: InMemoryKeyStore(), logins: logins)
        var profile = Profile.sample(name: "Work", slug: "work")
        profile.auth = .none
        try store.saveProfile(profile, others: [])
        XCTAssertTrue(logins.removed.isEmpty)

        var renamed = profile
        renamed.name = "Job"
        renamed.slug = "job"
        try store.saveProfile(renamed, others: [], previous: profile)

        XCTAssertEqual(logins.removed, [paths.home(for: "work").path])
    }

    func testTheDeleteDialogNamesTheLogin() {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        XCTAssertTrue(target?.items.contains(.login) == true)
        XCTAssertEqual(
            DeleteDialogText.itemText(.login, strings: .vietnamese),
            "tài khoản Claude đã đăng nhập trong profile này, nếu có"
        )
    }
}
