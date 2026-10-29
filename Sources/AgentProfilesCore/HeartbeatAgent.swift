import Foundation

/// Keeps one LaunchAgent per profile with an active heartbeat.
///
/// macOS starts the agent at the times of the schedule, with the app closed or
/// open. A Mac that sleeps at that time runs the agent when it wakes up. The
/// agent runs the launcher script of the profile with `-p ping`, so the
/// request goes out with the settings and the key of that profile.
public struct HeartbeatAgent {
    /// Every label starts with this, so the agents of the app are told apart
    /// from all others and nothing else in `LaunchAgents` is ever touched.
    public static let labelPrefix = "com.agentprofiles.heartbeat."

    static let resultExtension = "last"

    /// The shell that runs the CLI and writes the result file. Its arguments:
    /// the CLI, then `-p ping`. The environment holds `HEARTBEAT_RESULT`.
    ///
    /// The file is: the time the run ended (seconds since 1970), the exit code,
    /// then the output of the CLI cut to 2000 bytes. It is written to a
    /// temporary file and moved over the old one, so a reader never sees half
    /// of it and nothing older than the last run is kept.
    static let runner = """
    out="$("$@" 2>&1)"; code=$?
    { printf '%s\\n%s\\n' "$(date +%s)" "$code"; printf '%s' "$out" | head -c 2000; } > "$HEARTBEAT_RESULT.tmp" \\
      && mv "$HEARTBEAT_RESULT.tmp" "$HEARTBEAT_RESULT"
    exit "$code"
    """

    /// The words the CLI is sent.
    static let prompt = "ping"

    private let paths: Paths
    private let runner: ProcessRunner
    private let userID: UInt32
    private let searchPath: () -> String
    private let cliPath: () -> String?

    /// - Parameters:
    ///   - runner: runs `launchctl`; the tests replace it with a stub.
    ///   - searchPath: the PATH the agent gets (launchd gives none worth the name).
    public init(
        paths: Paths = Paths(),
        runner: ProcessRunner = SystemProcessRunner(),
        userID: UInt32 = getuid(),
        searchPath: @escaping () -> String = HeartbeatAgent.defaultSearchPath,
        cliPath: @escaping () -> String? = { AgentDetector.detect(.claude).path }
    ) {
        self.cliPath = cliPath
        self.paths = paths
        self.runner = runner
        self.userID = userID
        self.searchPath = searchPath
    }

    /// The PATH of the login shell, with the folder of the CLI in front.
    @Sendable
    public static func defaultSearchPath() -> String {
        let shell = AgentDetector.loginShellPath() ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        guard let cli = AgentDetector.detect(.claude).path else { return shell }
        return (cli as NSString).deletingLastPathComponent + ":" + shell
    }

    // MARK: - Where things are

    public func label(for slug: String) -> String { Self.labelPrefix + slug }

    /// `~/Library/LaunchAgents/<label>.plist`
    public func plistURL(for slug: String) -> URL {
        launchAgentsDir.appendingPathComponent(label(for: slug) + ".plist")
    }

    /// `~/.claude-profiles/heartbeat/<slug>.last`: the result of the last run,
    /// and only of the last one. Each run writes the file again.
    public func resultURL(for slug: String) -> URL {
        paths.root.appendingPathComponent("heartbeat", isDirectory: true)
            .appendingPathComponent(slug + "." + Self.resultExtension)
    }

    private var launchAgentsDir: URL {
        paths.home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    // MARK: - The plist

    /// One entry of `StartCalendarInterval` for each time and each day.
    static func calendarEntries(for heartbeat: Heartbeat) -> [[String: Int]] {
        let days: [Int?] = heartbeat.days.isEmpty ? [nil] : heartbeat.days.sorted()
        var entries: [[String: Int]] = []
        for day in days {
            for time in heartbeat.times {
                var entry = ["Hour": time.hour, "Minute": time.minute]
                if let day { entry["Weekday"] = day }
                entries.append(entry)
            }
        }
        return entries
    }

    /// The property list of the agent of `profile`.
    func plist(for profile: Profile) throws -> Data {
        // The default setup has no launcher: the CLI itself is run.
        let program: String
        if profile.isDefaultClaude {
            guard let cli = cliPath() else { throw ProfileError.heartbeatFailed("claude not found") }
            program = cli
        } else {
            program = paths.script(for: profile.slug).path
        }
        let dictionary: [String: Any] = [
            "Label": label(for: profile.slug),
            "ProgramArguments": ["/bin/sh", "-c", Self.runner, "heartbeat", program, "-p", Self.prompt],
            "StartCalendarInterval": Self.calendarEntries(for: profile.heartbeat),
            "EnvironmentVariables": [
                "PATH": searchPath(),
                "HEARTBEAT_RESULT": resultURL(for: profile.slug).path,
                // A key that no longer works must not keep the run waiting.
                "CLAUDE_CODE_MAX_RETRIES": "0",
            ],
            "WorkingDirectory": paths.home.path,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }

    // MARK: - Install and remove

    /// Writes the agent of `profile` and loads it. A profile whose schedule is
    /// not active has no agent: it is removed.
    public func apply(_ profile: Profile) throws {
        guard profile.heartbeat.isActive, Slug.isSafe(profile.slug) else {
            remove(slug: profile.slug)
            return
        }
        let manager = FileManager.default
        let target = plistURL(for: profile.slug)
        let data = try plist(for: profile)
        try manager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try manager.createDirectory(at: resultURL(for: profile.slug).deletingLastPathComponent(), withIntermediateDirectories: true)

        // The log of an earlier version grew with every run: it is not used any more.
        removeLegacyLog(slug: profile.slug)

        // Unchanged and loaded: nothing to do.
        if (try? Data(contentsOf: target)) == data, isLoaded(slug: profile.slug) { return }

        _ = try? runner.run(Self.launchctl, ["bootout", domain(for: profile.slug)])
        try data.write(to: target, options: .atomic)
        let result = try runner.run(Self.launchctl, ["bootstrap", "gui/\(userID)", target.path])
        guard result.isSuccess else { throw ProfileError.heartbeatFailed("launchctl: " + result.output) }
    }

    /// Unloads the agent of `slug` and deletes everything it left: its file and
    /// its log. Absent is fine. Returns `true` when nothing of it is left.
    @discardableResult
    public func remove(slug: String) -> Bool {
        guard Slug.isSafe(slug) else { return false }
        _ = try? runner.run(Self.launchctl, ["bootout", domain(for: slug)])
        let manager = FileManager.default
        try? manager.removeItem(at: plistURL(for: slug))
        try? manager.removeItem(at: resultURL(for: slug))
        removeLegacyLog(slug: slug)
        removeLogFolderIfEmpty()
        return !manager.fileExists(atPath: plistURL(for: slug).path)
            && !manager.fileExists(atPath: resultURL(for: slug).path)
    }

    /// Deletes `<slug>.log`, the appended log that an earlier version wrote.
    private func removeLegacyLog(slug: String) {
        try? FileManager.default.removeItem(
            at: resultURL(for: slug).deletingPathExtension().appendingPathExtension("log")
        )
    }

    /// `true` when the agent of `slug` or its log is on the disk.
    public func hasTraces(slug: String) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: plistURL(for: slug).path)
            || manager.fileExists(atPath: resultURL(for: slug).path)
    }

    private func removeLogFolderIfEmpty() {
        let folder = resultURL(for: "x").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if names.isEmpty { try? FileManager.default.removeItem(at: folder) }
    }

    /// The slugs that have a log on the disk.
    func resultSlugs() -> [String] {
        let folder = resultURL(for: "x").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            guard let dot = name.lastIndex(of: "."),
                  ["last", "log"].contains(String(name[name.index(after: dot)...])) else { return nil }
            let slug = String(name[..<dot])
            return Slug.isSafe(slug) ? slug : nil
        }
    }

    /// Brings the agents in line with `profiles`: each active schedule has its
    /// agent, every other agent of the app is removed (a deleted or renamed
    /// profile, a schedule that was turned off). Returns the slugs that failed.
    @discardableResult
    public func sync(_ profiles: [Profile]) -> [String] {
        var failed: [String] = []
        let wanted = Set(profiles.filter { $0.heartbeat.isActive }.map(\.slug))
        for profile in profiles {
            do { try apply(profile) } catch { failed.append(profile.slug) }
        }
        for slug in Set(installedSlugs() + resultSlugs()) where !wanted.contains(slug) {
            remove(slug: slug)
        }
        return failed
    }

    /// The result of the last run of `slug`, `nil` when it never ran.
    public func lastResult(slug: String) -> HeartbeatResult? {
        guard Slug.isSafe(slug),
              let text = try? String(contentsOf: resultURL(for: slug), encoding: .utf8) else { return nil }
        return HeartbeatResult(parsing: text)
    }

    /// Runs the agent of `slug` once, now. It is how a schedule is tried.
    public func runNow(slug: String) throws {
        let result = try runner.run(Self.launchctl, ["kickstart", domain(for: slug)])
        guard result.isSuccess else { throw ProfileError.heartbeatFailed("launchctl: " + result.output) }
    }

    func isLoaded(slug: String) -> Bool {
        ((try? runner.run(Self.launchctl, ["print", domain(for: slug)]))?.isSuccess) ?? false
    }

    /// The slugs of the agents of the app that are on disk.
    func installedSlugs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: launchAgentsDir.path)) ?? []
        return names.compactMap { name in
            guard name.hasPrefix(Self.labelPrefix), name.hasSuffix(".plist") else { return nil }
            let slug = String(name.dropFirst(Self.labelPrefix.count).dropLast(".plist".count))
            return Slug.isSafe(slug) ? slug : nil
        }
    }

    private static let launchctl = "/bin/launchctl"

    private func domain(for slug: String) -> String { "gui/\(userID)/\(label(for: slug))" }
}
