import CryptoKit
import XCTest
@testable import ClaudeProfilesCore

/// A command runner that answers for `codesign` and really runs `ditto`.
final class FakeProcessRunner: ProcessRunner {
    /// The status that `codesign --verify` answers with.
    var codesignStatus: Int32 = 0
    /// The status that `ditto` answers with. `nil` really unpacks the archive.
    var dittoStatus: Int32?
    /// Every command that was started.
    private(set) var calls: [(executable: String, arguments: [String])] = []

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append((executable, arguments))
        if executable.hasSuffix("codesign") {
            return ProcessResult(status: codesignStatus)
        }
        if executable.hasSuffix("ditto"), let dittoStatus {
            return ProcessResult(status: dittoStatus)
        }
        return try SystemProcessRunner().run(executable, arguments)
    }
}

final class UpdateInstallerTests: XCTestCase {
    private let bundleIdentifier = "local.claude-profiles"
    private let zipURL = "https://github.com/tamnt1707/claude-profiles/releases/download/v2.0.0/Claude-Profiles-2.0.0-macos.zip"
    private let sigURL = "https://github.com/tamnt1707/claude-profiles/releases/download/v2.0.0/Claude-Profiles-2.0.0-macos.zip.sig"

    private var temp: TempDirectory!
    private var key = Curve25519.Signing.PrivateKey()
    private var publicKey = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        temp = try TempDirectory(name: "updater")
        StubURLProtocol.reset()
        // A throwaway key pair, only for the tests.
        key = Curve25519.Signing.PrivateKey()
        publicKey = ReleaseSigning.publicKeyBase64(key.publicKey)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        temp = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes an app bundle with an `Info.plist`.
    @discardableResult
    private func makeApp(
        named name: String = "Claude Profiles.app",
        in folder: URL,
        identifier: String? = nil,
        version: String,
        updateKey: String? = nil
    ) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key><string>Claude Profiles</string>
          <key>CFBundleIdentifier</key><string>\(identifier ?? bundleIdentifier)</string>
          <key>CFBundleShortVersionString</key><string>\(version)</string>
          <key>CFBundleVersion</key><string>\(version)</string>
          <key>UpdatePublicKey</key><string>\(updateKey ?? publicKey)</string>
        </dict>
        </plist>
        """
        try Data(plist.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// Packs an app bundle into a zip, the way the release script does.
    private func makeArchive(of app: URL) throws -> Data {
        let zip = temp.url.appendingPathComponent("release.zip")
        try? FileManager.default.removeItem(at: zip)
        let result = try SystemProcessRunner().run(
            "/usr/bin/ditto",
            ["-c", "-k", "--keepParent", app.path, zip.path]
        )
        guard result.isSuccess else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return try Data(contentsOf: zip)
    }

    /// The configuration of an app that is already installed.
    private func configuration(app: URL, version: String = "1.0.0", key overrideKey: String? = nil) -> UpdateConfiguration {
        UpdateConfiguration(
            repo: "tamnt1707/claude-profiles",
            publicKey: overrideKey ?? publicKey,
            version: SemVer(text: version),
            bundleIdentifier: bundleIdentifier,
            appBundleURL: app
        )
    }

    private func info() -> UpdateInfo {
        UpdateInfo(
            version: SemVer(text: "2.0.0")!,
            notes: "Notes",
            zipURL: URL(string: zipURL)!,
            sigURL: URL(string: sigURL)!
        )
    }

    /// Serves an archive and its signature.
    private func serve(archive: Data, signature: Data? = nil) {
        StubURLProtocol.answer(.bytes(archive), for: zipURL)
        if let signature {
            StubURLProtocol.answer(.bytes(signature), for: sigURL)
        }
    }

    private func sign(_ data: Data) throws -> Data {
        Data(try ReleaseSigning.sign(data, privateKey: key).base64EncodedString().utf8)
    }

    /// The folders the installer created, so the test can see that they are
    /// cleaned up again.
    private func workingFolders() -> Set<String> {
        let root = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { $0.hasPrefix("ClaudeProfilesUpdate-") })
    }

    // MARK: - The rules before the download

    func testRefusesAnAddressThatIsNotAllowed() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        let info = UpdateInfo(
            version: SemVer(text: "2.0.0")!,
            notes: "",
            zipURL: URL(string: "https://example.com/update.zip")!,
            sigURL: URL(string: "https://example.com/update.zip.sig")!
        )
        await assertThrows(.disallowedHost("example.com")) {
            try await installer.install(info) { _ in }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRefusesAnAddressThatIsNotSecure() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        let info = UpdateInfo(
            version: SemVer(text: "2.0.0")!,
            notes: "",
            zipURL: URL(string: "http://github.com/update.zip")!,
            sigURL: URL(string: "http://github.com/update.zip.sig")!
        )
        await assertThrows(.insecureURL) {
            try await installer.install(info) { _ in }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRefusesARedirectToAnotherHost() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        StubURLProtocol.answer(.redirect(to: "https://example.com/update.zip"), for: zipURL)
        StubURLProtocol.answer(.bytes(Data("x".utf8)), for: sigURL)

        await assertThrows(.disallowedHost("example.com")) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testStopsBeforeTheDownloadWhenTheFolderCannotBeWritten() async throws {
        let folder = temp.url.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try makeApp(in: folder, version: "1.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.bundleNotWritable) {
            try await installer.install(self.info()) { _ in }
        }
        // Nothing was downloaded at all.
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRefusesWhenTheAppIsNotConfigured() async throws {
        var installer = UpdateInstaller(
            configuration: UpdateConfiguration(),
            session: StubURLProtocol.session()
        )
        installer.launchingHelper = { _ in }

        await assertThrows(.notConfigured) {
            try await installer.install(self.info()) { _ in }
        }
    }

    // MARK: - The signature

    func testRefusesAMissingSignature() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = try makeArchive(of: try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0"))
        serve(archive: archive)
        // The signature is not there.
        StubURLProtocol.answer(.json("not found", statusCode: 404), for: sigURL)

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        let before = workingFolders()
        await assertThrows(.missingSignature) {
            try await installer.install(self.info()) { _ in }
        }
        XCTAssertEqual(workingFolders(), before, "the downloads have to be deleted")
    }

    func testRefusesAWrongSignature() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = try makeArchive(of: try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0"))
        // The signature belongs to another archive.
        let otherKey = Curve25519.Signing.PrivateKey()
        let wrong = try ReleaseSigning.sign(Data("something else".utf8), privateKey: otherKey)
        serve(archive: archive, signature: Data(wrong.base64EncodedString().utf8))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        let before = workingFolders()
        await assertThrows(.invalidSignature) {
            try await installer.install(self.info()) { _ in }
        }
        XCTAssertEqual(workingFolders(), before, "the downloads have to be deleted")
    }

    func testRefusesABrokenSignatureFile() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = try makeArchive(of: try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0"))
        serve(archive: archive, signature: Data("this is not base64".utf8))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.invalidSignature) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesABrokenPublicKey() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = try makeArchive(of: try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0"))
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(
            configuration: configuration(app: app, key: "not a key"),
            session: StubURLProtocol.session()
        )
        installer.launchingHelper = { _ in }

        await assertThrows(.invalidPublicKey) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesADownloadThatIsTooBig() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = try makeArchive(of: try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0"))
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }
        installer.downloadSizeLimit = 16

        await assertThrows(.fileTooLarge) {
            try await installer.install(self.info()) { _ in }
        }
    }

    // MARK: - The new app inside the archive

    func testRefusesAnArchiveWithoutTheApp() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let other = try makeApp(named: "Something else.app", in: temp.url.appendingPathComponent("new"), version: "2.0.0")
        let archive = try makeArchive(of: other)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.unexpectedBundle) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesAnotherBundleIdentifier() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let newApp = try makeApp(
            in: temp.url.appendingPathComponent("new"),
            identifier: "com.somebody.else",
            version: "2.0.0"
        )
        serve(archive: try makeArchive(of: newApp), signature: nil)
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.bundleMismatch) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesAnOlderVersion() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let newApp = try makeApp(in: temp.url.appendingPathComponent("new"), version: "0.9.0")
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.notNewer) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesTheSameVersion() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let newApp = try makeApp(in: temp.url.appendingPathComponent("new"), version: "1.0.0")
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.notNewer) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesAnotherPublicKey() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let otherKey = ReleaseSigning.publicKeyBase64(Curve25519.Signing.PrivateKey().publicKey)
        let newApp = try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0", updateKey: otherKey)
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.keyMismatch) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesABrokenSignatureOfTheNewApp() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let newApp = try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0")
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        let processes = FakeProcessRunner()
        processes.codesignStatus = 1
        var installer = UpdateInstaller(
            configuration: configuration(app: app),
            session: StubURLProtocol.session(),
            processes: processes
        )
        installer.launchingHelper = { _ in }

        await assertThrows(.codesignFailed) {
            try await installer.install(self.info()) { _ in }
        }
    }

    func testRefusesAnArchiveThatCannotBeOpened() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let archive = Data("this is not a zip file".utf8)
        serve(archive: archive, signature: try sign(archive))

        let processes = FakeProcessRunner()
        processes.dittoStatus = 1
        var installer = UpdateInstaller(
            configuration: configuration(app: app),
            session: StubURLProtocol.session(),
            processes: processes
        )
        installer.launchingHelper = { _ in }

        await assertThrows(.extractionFailed) {
            try await installer.install(self.info()) { _ in }
        }
    }

    // MARK: - The happy path

    func testHandsTheNewVersionToTheHelper() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let newApp = try makeApp(in: temp.url.appendingPathComponent("new"), version: "2.0.0")
        let archive = try makeArchive(of: newApp)
        serve(archive: archive, signature: try sign(archive))

        var helper: URL?
        var helperText = ""
        let processes = FakeProcessRunner()
        var installer = UpdateInstaller(
            configuration: configuration(app: app),
            session: StubURLProtocol.session(),
            processes: processes
        )
        installer.processIdentifier = 4242
        installer.launchingHelper = { url in
            helper = url
            helperText = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        var progress: [UpdateInstaller.Progress] = []
        try await installer.install(info()) { progress.append($0) }

        // The helper was written and holds the right paths.
        let script = try XCTUnwrap(helper)
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        XCTAssertTrue(helperText.contains("PID='4242'"))
        XCTAssertTrue(helperText.contains("CURRENT='\(app.path)'"))
        XCTAssertTrue(helperText.contains("xattr -dr com.apple.quarantine"))

        // The progress was reported.
        XCTAssertTrue(progress.contains(.verifying))
        XCTAssertTrue(progress.contains(.extracting))
        XCTAssertTrue(progress.contains(.installing))
        XCTAssertTrue(progress.contains { if case .downloading = $0 { return true } else { return false } })
    }

    func testTheSignatureIsCheckedOverTheExactBytes() throws {
        // The signature is only good for the exact bytes it was made for.
        let data = Data("the archive".utf8)
        let signature = try ReleaseSigning.sign(data, privateKey: key)
        XCTAssertTrue(ReleaseSigning.verify(data, signature: signature, publicKeyBase64: publicKey))
        XCTAssertFalse(ReleaseSigning.verify(Data("other".utf8), signature: signature, publicKeyBase64: publicKey))
        // One byte more is already a different archive.
        var changed = data
        changed.append(0)
        XCTAssertFalse(ReleaseSigning.verify(changed, signature: signature, publicKeyBase64: publicKey))
    }

    func testThePublicKeyOfAnotherPairIsRefused() throws {
        let other = Curve25519.Signing.PrivateKey()
        let signature = try ReleaseSigning.sign(Data("x".utf8), privateKey: other)
        XCTAssertFalse(ReleaseSigning.verify(Data("x".utf8), signature: signature, publicKeyBase64: publicKey))
    }

    func testABrokenPublicKeyIsRefused() {
        XCTAssertFalse(ReleaseSigning.verify(Data("x".utf8), signature: Data("y".utf8), publicKeyBase64: "nonsense"))
        XCTAssertNil(ReleaseSigning.publicKey(fromBase64: "nonsense"))
        XCTAssertNil(ReleaseSigning.publicKey(fromBase64: ""))
    }

    // MARK: - The redirects of the download

    private let releaseAssetURL = "https://release-assets.githubusercontent.com/github-production-release-asset/1/update.zip?X-Amz-Signature=abc"

    /// The installer of the tests, with a configuration that is installed.
    private func redirectInstaller() -> UpdateInstaller {
        UpdateInstaller(
            configuration: configuration(app: temp.url.appendingPathComponent("Claude Profiles.app")),
            session: StubURLProtocol.session()
        )
    }

    func testFollowsTheRedirectToTheReleaseAssets() async throws {
        // The same redirect GitHub answers with for a release asset.
        StubURLProtocol.answer(.redirect(to: releaseAssetURL), for: zipURL)
        StubURLProtocol.answer(.bytes(Data("archive".utf8)), for: releaseAssetURL)
        let destination = temp.url.appendingPathComponent("update.zip")

        try await redirectInstaller().download(URL(string: zipURL)!, to: destination, limit: 1024) { _, _ in }

        XCTAssertEqual(try Data(contentsOf: destination), Data("archive".utf8))
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.url?.host == "release-assets.githubusercontent.com" })
    }

    func testRefusesARedirectToAnotherHostAndWritesNothing() async throws {
        StubURLProtocol.answer(
            StubURLProtocol.Answer(
                statusCode: 302,
                headers: ["Location": "https://evil.example/update.zip"],
                body: Data("payload".utf8)
            ),
            for: zipURL
        )
        let destination = temp.url.appendingPathComponent("update.zip")

        await assertThrows(.disallowedHost("evil.example")) {
            try await redirectInstaller().download(URL(string: zipURL)!, to: destination, limit: 1024) { _, _ in }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no bytes may be written")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.host == "evil.example" }, "the target is never requested")
    }

    func testRefusesARedirectToPlainHTTPAndWritesNothing() async throws {
        StubURLProtocol.answer(
            StubURLProtocol.Answer(
                statusCode: 302,
                headers: ["Location": "http://github.com/update.zip"],
                body: Data("payload".utf8)
            ),
            for: zipURL
        )
        let destination = temp.url.appendingPathComponent("update.zip")

        await assertThrows(.insecureURL) {
            try await redirectInstaller().download(URL(string: zipURL)!, to: destination, limit: 1024) { _, _ in }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no bytes may be written")
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.scheme == "http" }, "plain http is never requested")
    }

    // MARK: - The bundles inside the archive

    func testOnlyARealFolderCountsAsTheApp() throws {
        // A link with the name of the app is not opened.
        let real = try makeApp(in: temp.url.appendingPathComponent("real"), version: "2.0.0")
        let links = temp.url.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("Claude Profiles.app"),
            withDestinationURL: real
        )
        XCTAssertEqual(UpdateInstaller.appBundles(in: links), [])

        // A file with the name of the app is not an app either.
        let files = temp.url.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data("not an app".utf8).write(to: files.appendingPathComponent("Claude Profiles.app"))
        XCTAssertEqual(UpdateInstaller.appBundles(in: files), [])

        // The real folder is found.
        XCTAssertEqual(UpdateInstaller.appBundles(in: temp.url.appendingPathComponent("real")).count, 1)
    }

    func testTwoBundlesInTheArchiveAreRefused() async throws {
        let app = try makeApp(in: temp.url, version: "1.0.0")
        let parent = temp.url.appendingPathComponent("two", isDirectory: true)
        try makeApp(in: parent.appendingPathComponent("first", isDirectory: true), version: "2.0.0")
        try makeApp(in: parent.appendingPathComponent("second", isDirectory: true), version: "2.0.0")
        XCTAssertEqual(UpdateInstaller.appBundles(in: parent).count, 2)

        let archive = try makeArchive(of: parent)
        serve(archive: archive, signature: try sign(archive))

        var installer = UpdateInstaller(configuration: configuration(app: app), session: StubURLProtocol.session())
        installer.launchingHelper = { _ in }

        await assertThrows(.unexpectedBundle) {
            try await installer.install(self.info()) { _ in }
        }
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: UpdateError,
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as UpdateError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}
