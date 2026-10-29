import Foundation

/// The command line agents that a profile can run. Only Claude Code is
/// supported for now; the others are added here, one case each.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude

    /// The agent of a profile that does not say which one it runs.
    public static let `default` = AgentKind.claude

    /// The name of the program, as it is typed in a terminal.
    public var executable: String {
        switch self {
        case .claude: return "claude"
        }
    }

    /// The folders where the program is usually installed, relative to the
    /// home folder when they start with `~/`.
    var commonLocations: [String] {
        switch self {
        case .claude:
            return [
                "~/.local/bin/claude",
                "~/.claude/local/claude",
                "~/.npm-global/bin/claude",
                "~/.bun/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ]
        }
    }
}

/// Whether the program of an agent is installed on this Mac, and where.
public struct AgentInstall: Equatable, Sendable {
    public var agent: AgentKind
    /// The path of the program, `nil` when it was not found.
    public var path: String?

    public init(agent: AgentKind, path: String?) {
        self.agent = agent
        self.path = path
    }

    public var isInstalled: Bool { path != nil }
}

/// Finds the programs of the agents on this Mac.
public enum AgentDetector {
    /// How long the login shell may take to answer.
    static let lookupTimeout: TimeInterval = 4

    /// Looks for the program of an agent.
    ///
    /// The usual folders are looked at first: that is quick and asks no shell.
    /// Then the login shell is asked where the name is, because the PATH of
    /// the user (a version manager, a package manager) is only known there.
    ///
    /// - Parameters:
    ///   - isExecutable: tells whether a path is a program. Injectable for the tests.
    ///   - lookup: asks the shell for a name. Injectable for the tests.
    public static func detect(
        _ agent: AgentKind,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        lookup: (String) -> String? = shellLookup
    ) -> AgentInstall {
        for location in agent.commonLocations {
            let path = location.hasPrefix("~/")
                ? home.path + String(location.dropFirst(1))
                : location
            if isExecutable(path) { return AgentInstall(agent: agent, path: path) }
        }
        if let found = lookup(agent.executable), isExecutable(found) {
            return AgentInstall(agent: agent, path: found)
        }
        return AgentInstall(agent: agent, path: nil)
    }

    /// Looks for every agent.
    public static func detectAll(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        lookup: (String) -> String? = shellLookup
    ) -> [AgentKind: AgentInstall] {
        var found: [AgentKind: AgentInstall] = [:]
        for agent in AgentKind.allCases {
            found[agent] = detect(agent, home: home, isExecutable: isExecutable, lookup: lookup)
        }
        return found
    }

    /// The absolute path in what `command -v` printed, `nil` when there is none.
    ///
    /// A name that is an alias prints `name: aliased to <path> …`: the path is taken from it.
    public static func parseLookup(_ output: String) -> String? {
        var result: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("/"), !line.contains(" ") {
                result = line
            } else if let range = line.range(of: " aliased to ") {
                let word = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if word.hasPrefix("/") { result = word }
            }
        }
        return result
    }

    /// The PATH of the login shell, the one a terminal window has. Asked once,
    /// then kept: the shell may take a while. `nil` when the shell does not answer.
    public static func loginShellPath() -> String? {
        pathCache.value { shellOutput("printf '%s' \"$PATH\"") }
    }

    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var path: String?

        func value(_ make: () -> String?) -> String? {
            lock.lock(); defer { lock.unlock() }
            if !done {
                path = make().flatMap { $0.isEmpty ? nil : $0 }
                done = true
            }
            return path
        }
    }

    private static let pathCache = PathCache()

    /// Asks a login, interactive shell where `name` is. Stops waiting after `lookupTimeout`.
    ///
    /// The shell is the one that opens terminal windows: its startup files hold
    /// the PATH of the user. It reads nothing from the keyboard.
    public static func shellLookup(_ name: String) -> String? {
        shellOutput("command -v \(name)").flatMap(parseLookup)
    }

    /// What a command prints when the login shell runs it, `nil` when it does not answer in time.
    static func shellOutput(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + lookupTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
