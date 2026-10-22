import Foundation

/// Downloads, checks and installs a new version of the app.
///
/// The order of the steps matters and is never changed:
///
/// 1. the folder of the app has to be writable, otherwise the user is told
///    before anything is downloaded;
/// 2. only the known hosts of `UpdatePolicy` are used, over https, and a
///    redirect to another host is refused;
/// 3. the archive and its signature are downloaded into a fresh temporary
///    folder, with a limit of 200 MB;
/// 4. the signature has to match, there is no way to install it anyway;
/// 5. the archive is unpacked and the new app is checked: the same bundle
///    identifier, a higher version, the same public key and a valid signature;
/// 6. a helper script replaces the bundle after this app has quit.
public struct UpdateInstaller {
    /// What the installer is doing.
    public enum Progress: Equatable {
        /// The archive is on its way.
        case downloading(received: Int64, expected: Int64?)
        /// The signature is being checked.
        case verifying
        /// The archive is being unpacked.
        case extracting
        /// The bundle is being replaced.
        case installing
    }

    /// The biggest archive that is accepted, in bytes.
    public static let maximumDownloadSize = 200 * 1024 * 1024

    /// The biggest signature file that is accepted, in bytes.
    public static let maximumSignatureSize = 64 * 1024

    /// The limit of the archive of this installer. The tests use a small one.
    public var downloadSizeLimit: Int = UpdateInstaller.maximumDownloadSize

    /// The limit of the signature file of this installer.
    public var signatureSizeLimit: Int = UpdateInstaller.maximumSignatureSize

    /// What the app knows about itself.
    public var configuration: UpdateConfiguration

    /// The session used for the downloads.
    public var session: URLSession

    /// Runs `ditto` and `codesign`.
    public var processes: ProcessRunner

    /// The process of the app; the helper waits for it to end.
    public var processIdentifier: Int32

    /// Starts the helper script.
    public var launchingHelper: (URL) throws -> Void

    public init(
        configuration: UpdateConfiguration,
        session: URLSession = .shared,
        processes: ProcessRunner = SystemProcessRunner(),
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        launchingHelper: ((URL) throws -> Void)? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.processes = processes
        self.processIdentifier = processIdentifier
        self.launchingHelper = launchingHelper ?? UpdateInstaller.launchDetached
    }

    /// Downloads the release, checks it and hands the replacement to the helper.
    ///
    /// The function returns when the helper is on its way; the app has to
    /// quit afterwards.
    public func install(_ info: UpdateInfo, progress: @escaping (Progress) -> Void) async throws {
        guard configuration.isEnabled,
              let currentVersion = configuration.version,
              let appBundle = configuration.appBundleURL
        else {
            throw UpdateError.notConfigured
        }

        // 1. The folder of the app has to be writable. When it is not, the
        //    user is told before a single byte is downloaded.
        let folder = appBundle.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateError.bundleNotWritable
        }

        // 2. Only the known hosts may be used.
        try UpdatePolicy.validate(info.zipURL)
        try UpdatePolicy.validate(info.sigURL)

        // 3. A fresh working folder for this attempt.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProfilesUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Everything is thrown away again when a step fails.
        var handedOver = false
        defer {
            if !handedOver { try? FileManager.default.removeItem(at: work) }
        }

        let archive = work.appendingPathComponent("update.zip")
        let signature = work.appendingPathComponent("update.zip.sig")

        try await download(info.zipURL, to: archive, limit: downloadSizeLimit) { received, expected in
            progress(.downloading(received: received, expected: expected))
        }
        do {
            try await download(info.sigURL, to: signature, limit: signatureSizeLimit) { _, _ in }
        } catch UpdateError.httpError(404) {
            throw UpdateError.missingSignature
        }

        // 4. The signature has to match the archive. There is no way out.
        progress(.verifying)
        guard let archiveData = try? Data(contentsOf: archive) else {
            throw UpdateError.downloadFailed
        }
        guard let signatureText = try? String(contentsOf: signature, encoding: .utf8) else {
            throw UpdateError.missingSignature
        }
        let signatureData = Data(
            base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines),
            options: .ignoreUnknownCharacters
        )
        guard let signatureData else {
            throw UpdateError.invalidSignature
        }
        guard ReleaseSigning.publicKey(fromBase64: configuration.publicKey) != nil else {
            throw UpdateError.invalidPublicKey
        }
        guard ReleaseSigning.verify(archiveData, signature: signatureData, publicKeyBase64: configuration.publicKey) else {
            throw UpdateError.invalidSignature
        }
        // The bytes that were verified are written to a new file and only that
        // file is unpacked, so nothing can change the archive in between.
        let verified = work.appendingPathComponent("verified.zip")
        try archiveData.write(to: verified)

        // 5. Unpack and look at the app inside.
        progress(.extracting)
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unpacked = try processes.run("/usr/bin/ditto", ["-x", "-k", verified.path, extracted.path])
        guard unpacked.isSuccess else {
            throw UpdateError.extractionFailed
        }

        let bundles = UpdateInstaller.appBundles(in: extracted)
        guard bundles.count == 1 else {
            throw UpdateError.unexpectedBundle
        }
        let newBundle = bundles[0]

        guard let newInfo = Bundle(url: newBundle)?.infoDictionary else {
            throw UpdateError.bundleMismatch
        }
        guard let identifier = newInfo["CFBundleIdentifier"] as? String,
              identifier == configuration.bundleIdentifier
        else {
            throw UpdateError.bundleMismatch
        }
        guard let versionText = newInfo["CFBundleShortVersionString"] as? String,
              let newVersion = SemVer(text: versionText),
              newVersion > currentVersion
        else {
            throw UpdateError.notNewer
        }
        guard let newKey = newInfo["UpdatePublicKey"] as? String,
              newKey == configuration.publicKey
        else {
            throw UpdateError.keyMismatch
        }
        let signed = try processes.run("/usr/bin/codesign", ["--verify", "--deep", newBundle.path])
        guard signed.isSuccess else {
            throw UpdateError.codesignFailed
        }

        // 6. The helper replaces the bundle after this app has quit.
        progress(.installing)
        let script = work.appendingPathComponent(InstallHelper.scriptName)
        let text = InstallHelper.script(
            pid: processIdentifier,
            currentBundle: appBundle,
            newBundle: newBundle,
            workDirectory: work
        )
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try launchingHelper(script)

        // The helper removes the working folder when it is done.
        handedOver = true
    }

    /// Every `Claude Profiles.app` inside a folder.
    static func appBundles(in folder: URL) -> [URL] {
        var found: [URL] = []
        var stack = [folder]
        while let current = stack.popLast() {
            let children = (try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                // Only a real folder counts: a link or a file with the name is never opened.
                guard SafeFileSystem.kind(of: child) == .directory else { continue }
                if child.lastPathComponent == "Claude Profiles.app" {
                    found.append(child)
                    continue
                }
                // Another bundle is never opened.
                guard child.pathExtension != "app" else { continue }
                stack.append(child)
            }
        }
        return found
    }

    /// Starts the helper script detached from the app.
    ///
    /// The script has to survive the quit of the app, so it is started through
    /// `nohup` in the background and gets its own process.
    ///
    /// It also starts with an empty environment: an exported function of the
    /// shell of the app, an alias or a shim in the PATH must not be able to
    /// change what the helper does. `env -i` gives the script a PATH of its
    /// own and the home folder of the user, and nothing else.
    static func launchDetached(_ script: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            HelperLaunch.command(
                script: script,
                home: FileManager.default.homeDirectoryForCurrentUser
            ),
        ]
        try process.run()
    }

    /// Downloads a file and writes it to the disk.
    func download(
        _ url: URL,
        to destination: URL,
        limit: Int,
        progress: @escaping (Int64, Int64?) -> Void
    ) async throws {
        try UpdatePolicy.validate(url)

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")

        let delegate = DownloadDelegate(destination: destination, limit: limit, progress: progress)
        // The session of the installer is the base, so the tests can answer
        // with their own protocol; only the delegate that guards the
        // redirects and writes the file is added.
        let configuration = session.configuration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let downloadSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        // The session is released on every path, also when the download fails.
        defer { downloadSession.finishTasksAndInvalidate() }
        let task = downloadSession.dataTask(with: request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Writes the bytes of a download to a file and reports the progress.
///
/// The delegate is also the guard of the redirects: a redirect is only
/// followed when it leads to one of the allowed hosts.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    private let destination: URL
    private let limit: Int
    private let progress: (Int64, Int64?) -> Void

    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var failure: UpdateError?
    private var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, limit: Int, progress: @escaping (Int64, Int64?) -> Void) {
        self.destination = destination
        self.limit = limit
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        if let failure {
            self.continuation = nil
            continuation.resume(throwing: failure)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                failure = .httpError(404)
                completionHandler(.cancel)
                return
            }
            if (300...399).contains(http.statusCode) {
                // The redirect was refused; its answer arrives here. The reason
                // was already set by the redirect check.
                if failure == nil {
                    let target = http.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
                    failure = .disallowedHost(target?.host ?? response.url?.host ?? "")
                }
                completionHandler(.cancel)
                return
            }
            guard http.statusCode == 200 else {
                failure = .httpError(http.statusCode)
                completionHandler(.cancel)
                return
            }
        }

        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination)
        else {
            failure = .downloadFailed
            completionHandler(.cancel)
            return
        }
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        if received > Int64(limit) {
            failure = .fileTooLarge
            dataTask.cancel()
            return
        }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            failure = .downloadFailed
            dataTask.cancel()
            return
        }
        progress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil

        guard let continuation else { return }
        self.continuation = nil

        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if let urlError = error as? URLError {
                continuation.resume(throwing: UpdateChecker.map(urlError))
            } else {
                continuation.resume(throwing: UpdateError.downloadFailed)
            }
        } else {
            // The file is on the disk.
            continuation.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            guard let url = request.url else { throw UpdateError.invalidResponse }
            try UpdatePolicy.validate(url)
            completionHandler(request)
        } catch {
            // A redirect to another host, or to an address that is not secure,
            // is refused and nothing is written.
            failure = (error as? UpdateError) ?? .downloadFailed
            completionHandler(nil)
        }
    }
}
