import Foundation

/// One run of a program that is not shown to the user.
public struct HeadlessRequest: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// The whole environment of the program: nothing is inherited.
    public var environment: [String: String]
    public var currentDirectory: String
    /// Seconds after which the program is ended.
    public var timeout: TimeInterval

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        timeout: TimeInterval
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
    }
}

/// What a headless run left behind.
public struct HeadlessResult: Equatable, Sendable {
    public var status: Int32
    /// What the program wrote on its standard output.
    public var output: String
    /// The program was still running when the time was up, and was ended.
    public var timedOut: Bool
    /// The program could not be started at all.
    public var launchFailed: Bool

    public init(status: Int32, output: String, timedOut: Bool = false, launchFailed: Bool = false) {
        self.status = status
        self.output = output
        self.timedOut = timedOut
        self.launchFailed = launchFailed
    }
}

/// Runs a headless request. The tests replace it with a stub.
public protocol HeadlessRunner: Sendable {
    func run(_ request: HeadlessRequest) async throws -> HeadlessResult
}

/// Runs the request with `Process`. A cancelled task ends the program.
public struct SystemHeadlessRunner: HeadlessRunner {
    public init() {}

    /// Holds the process so that the cancellation handler can end it.
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var timedOutFlag = false
        private var cancelled = false

        func set(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            self.process = process
            return true
        }

        func timeOut() {
            lock.lock(); defer { lock.unlock() }
            timedOutFlag = true
            if process?.isRunning == true { process?.terminate() }
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOutFlag
        }
    }

    public func run(_ request: HeadlessRequest) async throws -> HeadlessResult {
        let handle = Handle()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HeadlessResult, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: request.executable)
                    process.arguments = request.arguments
                    process.environment = request.environment
                    process.currentDirectoryURL = URL(fileURLWithPath: request.currentDirectory)
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    // The program reads nothing from the keyboard.
                    process.standardInput = FileHandle.nullDevice
                    guard handle.set(process) else {
                        continuation.resume(returning: HeadlessResult(status: -1, output: ""))
                        return
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: HeadlessResult(status: -1, output: "", launchFailed: true))
                        return
                    }
                    let timer = DispatchWorkItem { handle.timeOut() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout, execute: timer)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()
                    continuation.resume(returning: HeadlessResult(
                        status: process.terminationStatus,
                        output: String(decoding: data, as: UTF8.self),
                        timedOut: handle.timedOut
                    ))
                }
            }
        } onCancel: {
            handle.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

/// Tests a profile by asking the CLI of its agent for one short answer, with
/// the settings of the profile. That is the request the user's own commands
/// make, so it answers what a plain request to the provider cannot: the name
/// of the model as it is declared, the way the CLI signs in, its own retries.
public struct HeadlessProbe: Sendable {
    /// Seconds before the CLI is ended and the test counts as a timeout.
    public static let timeout: TimeInterval = 45

    /// The words the CLI is asked to answer with.
    static let prompt = "ping"

    private let runner: HeadlessRunner
    private let executable: @Sendable () -> String?
    private let baseEnvironment: @Sendable (_ executable: String) -> [String: String]

    /// - Parameters:
    ///   - runner: runs the CLI.
    ///   - executable: the path of the CLI, `nil` when it is not installed.
    ///   - baseEnvironment: what the CLI needs besides the settings of the
    ///     profile: the home folder and the PATH of the user.
    public init(
        runner: HeadlessRunner = SystemHeadlessRunner(),
        executable: @escaping @Sendable () -> String? = { AgentDetector.detect(.claude).path },
        baseEnvironment: @escaping @Sendable (_ executable: String) -> [String: String] = HeadlessProbe.defaultEnvironment
    ) {
        self.runner = runner
        self.executable = executable
        self.baseEnvironment = baseEnvironment
    }

    /// Sends one short request through the CLI with the settings of `profile`.
    ///
    /// Nothing is run when the address is invalid, when the key would travel
    /// over plain http to a remote host, when a key is needed and `key` is
    /// empty, or when the CLI is not installed.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func testConnection(profile: Profile, key: String, paths: Paths) async throws -> ProbeReport {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            guard let url = ProviderEndpoint.url(baseURL: base, path: "v1/messages") else {
                return ProbeReport(outcome: .invalidURL)
            }
            if ProviderEndpoint.isInsecure(url) {
                return ProbeReport(outcome: .insecureURL)
            }
        }
        if profile.auth != .none && trimmedKey.isEmpty {
            return ProbeReport(outcome: .missingKey)
        }
        guard let path = executable() else {
            return ProbeReport(outcome: .cliNotFound)
        }
        guard let request = try? Self.request(
            profile: profile, key: trimmedKey, paths: paths,
            executable: path, environment: baseEnvironment(path)
        ) else {
            return ProbeReport(outcome: .cliFailed)
        }

        let started = ContinuousClock.now
        let result = try await runner.run(request)
        let latency = Int(started.duration(to: ContinuousClock.now) / Duration.milliseconds(1))
        return Self.report(for: result, key: trimmedKey, latencyMs: latency)
    }

    // MARK: - The request

    /// The arguments: one short, plain answer, without tools, skills, MCP
    /// servers or a saved session, so the request is small and leaves nothing behind.
    static let arguments = [
        "-p", prompt,
        "--output-format", "json",
        "--tools", "",
        "--no-session-persistence",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--system-prompt", "Reply with the single word OK.",
    ]

    /// The request for a profile. The environment is the one of the launcher
    /// of the profile: the same variables, with the model names as they are declared.
    static func request(
        profile: Profile,
        key: String,
        paths: Paths,
        executable: String,
        environment base: [String: String]
    ) throws -> HeadlessRequest {
        var env = base
        func set(_ name: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { env[name] = trimmed }
        }
        // Without this the CLI retries a failed request for minutes.
        env["CLAUDE_CODE_MAX_RETRIES"] = "0"
        if let variable = profile.auth.envVarName, !key.isEmpty {
            env[variable] = key
        }
        set("ANTHROPIC_BASE_URL", profile.baseURL)
        set("ANTHROPIC_MODEL", profile.model)
        set("ANTHROPIC_DEFAULT_OPUS_MODEL", profile.opusModel)
        set("ANTHROPIC_DEFAULT_SONNET_MODEL", profile.sonnetModel)
        set("ANTHROPIC_DEFAULT_HAIKU_MODEL", profile.haikuModel)
        if profile.isolate {
            env["CLAUDE_CONFIG_DIR"] = paths.home(for: profile.slug).path
        }
        for entry in try ShellQuote.parseExtraEnv(profile.extraEnv) {
            env[entry.key] = entry.value
        }
        return HeadlessRequest(
            executable: executable,
            arguments: arguments,
            environment: env,
            currentDirectory: NSTemporaryDirectory(),
            timeout: timeout
        )
    }

    /// What a Mac login needs: the home folder, the user and the PATH of the
    /// login shell, with the folder of the CLI in front.
    @Sendable
    public static func defaultEnvironment(executable: String) -> [String: String] {
        let process = ProcessInfo.processInfo.environment
        var env: [String: String] = ["TERM": "dumb", "LANG": "en_US.UTF-8"]
        for name in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = process[name] { env[name] = value }
        }
        let folder = (executable as NSString).deletingLastPathComponent
        let path = AgentDetector.loginShellPath() ?? process["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = folder + ":" + path
        return env
    }

    // MARK: - The answer

    /// Turns what the CLI printed into a report. The key never appears in it.
    static func report(for result: HeadlessResult, key: String, latencyMs: Int) -> ProbeReport {
        if result.timedOut { return ProbeReport(outcome: .timeout) }
        if result.launchFailed { return ProbeReport(outcome: .cliFailed) }
        guard let json = lastObject(in: result.output) else {
            return ProbeReport(
                outcome: .cliFailed,
                providerMessage: ProviderMessage.sanitize(result.output, key: key, limit: ProviderMessage.maxLength)
            )
        }
        let isError = json["is_error"] as? Bool ?? (result.status != 0)
        let text = json["result"] as? String ?? ""
        let message = ProviderMessage.sanitize(text, key: key, limit: ProviderMessage.maxLength)
        if !isError {
            let model = (json["modelUsage"] as? [String: Any])?.keys.sorted().first
            let milliseconds = (json["duration_ms"] as? Int) ?? latencyMs
            return ProbeReport(outcome: .ok(latencyMs: milliseconds, model: model))
        }
        let outcome = classify(status: json["api_error_status"] as? Int, text: text.lowercased())
        return ProbeReport(outcome: outcome, providerMessage: message)
    }

    /// The last line of the output that is a JSON object.
    private static func lastObject(in output: String) -> [String: Any]? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            else { continue }
            return object
        }
        return nil
    }

    /// The outcome of an error: by the status of the provider when there is one, else by its words.
    static func classify(status: Int?, text lowered: String) -> ProbeOutcome {
        switch status {
        case 401?: return .unauthorized
        case 403?: return .forbidden
        case 429?: return .rateLimited
        case let code? where (500...599).contains(code): return .serverError(code)
        case 404?:
            return ConnectionProbe.mentionsUnknownModel(lowered) ? .modelNotFound : .notFound
        case 400?:
            return ConnectionProbe.mentionsUnknownModel(lowered) ? .modelNotFound : .unexpectedStatus(400)
        case let code?: return .unexpectedStatus(code)
        case nil: break
        }
        if lowered.contains("not logged in") || lowered.contains("/login") { return .notLoggedIn }
        if ConnectionProbe.mentionsUnknownModel(lowered) { return .modelNotFound }
        if lowered.contains("enotfound") || lowered.contains("getaddrinfo") { return .network(.dns) }
        if lowered.contains("timed out") || lowered.contains("etimedout") || lowered.contains("timeout") {
            return .timeout
        }
        if lowered.contains("certificate") || lowered.contains("tls") || lowered.contains("ssl") {
            return .network(.tls)
        }
        if lowered.contains("enetunreach") || lowered.contains("offline")
            || lowered.contains("network is unreachable") {
            return .network(.offline)
        }
        if lowered.contains("econnrefused") || lowered.contains("econnreset") || lowered.contains("connection") {
            return .network(.other)
        }
        return .cliFailed
    }
}
