import Foundation

/// The account a config folder of Claude Code is signed in with, as
/// `claude auth status` reports it.
public struct AccountInfo: Equatable, Sendable {
    public var loggedIn: Bool
    /// `claude.ai` for a subscription, for example. `nil` when not signed in.
    public var authMethod: String?
    public var email: String?
    public var organization: String?
    /// `free`, `pro`, `max`…
    public var subscription: String?

    public init(
        loggedIn: Bool,
        authMethod: String? = nil,
        email: String? = nil,
        organization: String? = nil,
        subscription: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.organization = organization
        self.subscription = subscription
    }

    /// Reads the output of `claude auth status`. A login shell can print text
    /// before the JSON, so the object is cut out from the first `{` to the last
    /// `}`. `nil` when there is no readable object.
    public init?(output: String) {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            loggedIn: loggedIn,
            authMethod: text("authMethod").flatMap { $0 == "none" ? nil : $0 },
            email: text("email"),
            organization: text("orgName"),
            subscription: text("subscriptionType")
        )
    }
}

/// Asks the CLI which account a profile is signed in with. No model is called:
/// `claude auth status` reads the local sign-in, so it costs no tokens.
public struct AccountProbe: Sendable {
    /// Seconds before the CLI is ended.
    public static let timeout: TimeInterval = 20

    private let runner: HeadlessRunner
    private let executable: @Sendable () -> String?
    private let baseEnvironment: @Sendable (_ executable: String) -> [String: String]

    public init(
        runner: HeadlessRunner = SystemHeadlessRunner(),
        executable: @escaping @Sendable () -> String? = { AgentDetector.detect(.claude).path },
        baseEnvironment: @escaping @Sendable (_ executable: String) -> [String: String] = HeadlessProbe.defaultEnvironment
    ) {
        self.runner = runner
        self.executable = executable
        self.baseEnvironment = baseEnvironment
    }

    /// The account of `profile`, `nil` when the CLI is missing, did not answer
    /// or printed something unreadable.
    public func fetch(
        profile: Profile,
        paths: Paths,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) async -> AccountInfo? {
        guard let path = executable() else { return nil }
        let request: HeadlessRequest
        if profile.isDefaultClaude {
            // Plain `claude` in the login shell of the user, like the connection check.
            request = HeadlessRequest(
                executable: "/bin/zsh",
                arguments: ["-l", "-i", "-c", "claude auth status"],
                environment: inherited,
                currentDirectory: NSTemporaryDirectory(),
                timeout: Self.timeout
            )
        } else {
            var env = baseEnvironment(path)
            if profile.isolate {
                env["CLAUDE_CONFIG_DIR"] = paths.home(for: profile.slug).path
            }
            request = HeadlessRequest(
                executable: path,
                arguments: ["auth", "status"],
                environment: env,
                currentDirectory: NSTemporaryDirectory(),
                timeout: Self.timeout
            )
        }
        guard let result = try? await runner.run(request), !result.timedOut, !result.launchFailed else { return nil }
        return AccountInfo(output: result.output)
    }
}
