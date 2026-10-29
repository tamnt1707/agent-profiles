import Foundation

/// How a profile is started inside the app: the shell and its command.
///
/// The command is the one that "Copy command" copies (`claude-<slug>`), after a
/// `cd` into the folder when there is one. The folder of the launchers is put
/// in front of PATH first, so the short name runs even when the PATH setup of
/// the shell was never done.
public enum EmbeddedTerminalSpec {
    /// The shell that runs the command. A login shell, so the PATH of the user is there.
    public static let shell = "/bin/zsh"

    /// The text that is passed to the shell with `-c`.
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when a path holds a control
    ///   character, as for any other terminal.
    public static func shellCommand(
        for profile: Profile,
        paths: Paths,
        workdirOverride: String? = nil
    ) throws -> String {
        let command = try Launcher.command(
            for: profile, paths: paths, workdirOverride: workdirOverride, useShortName: true
        )
        let bin = paths.binDir.path
        guard FolderPathSafety.isSafe(bin) else {
            throw ProfileError.unsafeFolderToOpen(bin)
        }
        return "export PATH=\(ShellQuote.quote(bin)):\"$PATH\"; " + command
    }

    /// The arguments of the shell: a login shell that is interactive, like the one of a terminal window.
    public static func arguments(command: String) -> [String] {
        ["-l", "-i", "-c", command]
    }
}

/// What one embedded terminal is doing.
public enum TerminalSessionState: Equatable, Sendable {
    /// The process runs.
    case running
    /// The process ended. `code` is `nil` when a signal ended it.
    case exited(code: Int32?)
}

/// The embedded terminals of the app, one per profile, by slug.
///
/// A session that is started again gets a new run number. The end of an older
/// run, which can arrive late, is then ignored: it must not mark the new run
/// as ended.
public struct TerminalSessionBook: Equatable, Sendable {
    private var states: [String: TerminalSessionState] = [:]
    private var runs: [String: Int] = [:]
    private var lastRun = 0

    public init() {}

    /// The state of the terminal of a profile, `nil` when it has none.
    public func state(for slug: String) -> TerminalSessionState? {
        states[slug]
    }

    /// The slugs that have a running process, sorted.
    public var runningSlugs: [String] {
        states.filter { $0.value == .running }.map(\.key).sorted()
    }

    /// A process was started for the profile. Returns the number of this run.
    @discardableResult
    public mutating func started(_ slug: String) -> Int {
        lastRun += 1
        runs[slug] = lastRun
        states[slug] = .running
        return lastRun
    }

    /// The process of the run ended. Returns `false` and changes nothing when
    /// the run is not the current one of the profile.
    @discardableResult
    public mutating func exited(_ slug: String, run: Int, code: Int32?) -> Bool {
        guard runs[slug] == run, states[slug] == .running else { return false }
        states[slug] = .exited(code: code)
        return true
    }

    /// The terminal of the profile is gone.
    public mutating func closed(_ slug: String) {
        states[slug] = nil
        runs[slug] = nil
    }

    /// The profile has a new slug: its terminal goes with it.
    public mutating func renamed(from old: String, to new: String) {
        guard old != new, let state = states[old] else { return }
        states[new] = state
        runs[new] = runs[old]
        states[old] = nil
        runs[old] = nil
    }
}
