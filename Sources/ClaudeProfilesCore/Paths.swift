import Foundation

/// Where the app keeps its data. The root is injectable so tests can use a
/// temporary directory instead of the real `~/.claude-profiles`.
public struct Paths: Sendable {
    /// `~/.claude-profiles` by default.
    public let root: URL
    /// The user's home directory, used to share `~/.claude` between profiles.
    public let home: URL

    public init(root: URL? = nil, home: URL? = nil) {
        // CLAUDE_PROFILES_HOME lets a developer run the app against a
        // throwaway home directory (the system home ignores $HOME). Release
        // builds ignore it, so a stray variable cannot move the real data.
        #if DEBUG
        let override = ProcessInfo.processInfo.environment["CLAUDE_PROFILES_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let override: URL? = nil
        #endif
        let homeURL = home ?? override ?? FileManager.default.homeDirectoryForCurrentUser
        self.home = homeURL
        self.root = root ?? homeURL.appendingPathComponent(".claude-profiles", isDirectory: true)
    }

    /// `~/.claude-profiles/profiles.json`
    public var dataFile: URL { root.appendingPathComponent("profiles.json") }
    /// `~/.claude-profiles/bin`
    public var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    /// `~/.claude-profiles/homes`
    public var homesDir: URL { root.appendingPathComponent("homes", isDirectory: true) }
    /// The user's real Claude configuration, never modified by us.
    public var defaultClaudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }

    /// The launcher script of a profile.
    public func script(for slug: String) -> URL {
        binDir.appendingPathComponent("claude-\(slug)")
    }

    /// The isolated `CLAUDE_CONFIG_DIR` of a profile.
    public func home(for slug: String) -> URL {
        homesDir.appendingPathComponent(slug, isDirectory: true)
    }

    /// The command users type in a terminal.
    public func command(for slug: String) -> String { "claude-\(slug)" }
}
