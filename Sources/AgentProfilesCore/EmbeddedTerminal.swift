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

/// One tab of the terminal of a profile.
public struct TerminalSession: Equatable, Sendable, Identifiable {
    /// The identity of the tab. Never used again, not even after the tab is closed.
    public let id: Int
    /// The number shown in the title of the tab: 1, 2, 3… for each profile.
    public let number: Int
    public var state: TerminalSessionState
    /// The number of the process that runs in the tab. It changes when the tab is restarted.
    fileprivate(set) var run: Int
}

/// The embedded terminals of the app: any number of tabs for each profile.
///
/// A tab that is restarted gets a new run number. The end of an older run,
/// which can arrive late, is then ignored: it must not mark the new run as ended.
public struct TerminalSessionBook: Equatable, Sendable {
    private var byProfile: [String: [TerminalSession]] = [:]
    private var nextNumber: [String: Int] = [:]
    private var lastID = 0
    private var lastRun = 0

    public init() {}

    /// The tabs of a profile, in the order they were opened.
    public func sessions(for slug: String) -> [TerminalSession] {
        byProfile[slug] ?? []
    }

    /// One tab, `nil` when it does not exist.
    public func session(_ id: Int) -> TerminalSession? {
        byProfile.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    /// The profile a tab belongs to.
    public func slug(of id: Int) -> String? {
        byProfile.first { $0.value.contains { $0.id == id } }?.key
    }

    /// How many processes run, in all profiles.
    public var runningCount: Int {
        byProfile.values.reduce(0) { $0 + $1.filter { $0.state == .running }.count }
    }

    /// How many processes run in a profile.
    public func runningCount(for slug: String) -> Int {
        sessions(for: slug).filter { $0.state == .running }.count
    }

    /// A tab is opened for the profile, with a process that starts now.
    /// Returns its identity and the number of the run.
    @discardableResult
    public mutating func open(_ slug: String) -> (id: Int, run: Int) {
        lastID += 1
        lastRun += 1
        let number = (nextNumber[slug] ?? 0) + 1
        nextNumber[slug] = number
        byProfile[slug, default: []].append(
            TerminalSession(id: lastID, number: number, state: .running, run: lastRun)
        )
        return (lastID, lastRun)
    }

    /// A new process starts in an existing tab. Returns the new run number, `nil` when there is no such tab.
    @discardableResult
    public mutating func restart(_ id: Int) -> Int? {
        guard let slug = slug(of: id), let index = byProfile[slug]?.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        lastRun += 1
        byProfile[slug]?[index].run = lastRun
        byProfile[slug]?[index].state = .running
        return lastRun
    }

    /// The process of the run ended. Returns `false` and changes nothing when
    /// the run is not the current one of the tab.
    @discardableResult
    public mutating func exited(_ id: Int, run: Int, code: Int32?) -> Bool {
        guard let slug = slug(of: id), let index = byProfile[slug]?.firstIndex(where: { $0.id == id }),
              byProfile[slug]?[index].run == run, byProfile[slug]?[index].state == .running
        else { return false }
        byProfile[slug]?[index].state = .exited(code: code)
        return true
    }

    /// The tab is closed.
    public mutating func close(_ id: Int) {
        guard let slug = slug(of: id) else { return }
        byProfile[slug]?.removeAll { $0.id == id }
        if byProfile[slug]?.isEmpty == true {
            byProfile[slug] = nil
            nextNumber[slug] = nil
        }
    }

    /// Every tab of the profile is closed. Returns their identities.
    @discardableResult
    public mutating func closeAll(_ slug: String) -> [Int] {
        let ids = sessions(for: slug).map(\.id)
        byProfile[slug] = nil
        nextNumber[slug] = nil
        return ids
    }

    /// The profile has a new slug: its tabs go with it.
    public mutating func renamed(from old: String, to new: String) {
        guard old != new, let sessions = byProfile[old] else { return }
        byProfile[new] = sessions
        nextNumber[new] = nextNumber[old]
        byProfile[old] = nil
        nextNumber[old] = nil
    }
}
