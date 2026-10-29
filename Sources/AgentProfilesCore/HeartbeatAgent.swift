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

    /// The words the CLI is sent.
    static let prompt = "ping"

    private let paths: Paths
    private let runner: ProcessRunner
    private let userID: UInt32
    private let searchPath: () -> String

    /// - Parameters:
    ///   - runner: runs `launchctl`; the tests replace it with a stub.
    ///   - searchPath: the PATH the agent gets (launchd gives none worth the name).
    public init(
        paths: Paths = Paths(),
        runner: ProcessRunner = SystemProcessRunner(),
        userID: UInt32 = getuid(),
        searchPath: @escaping () -> String = HeartbeatAgent.defaultSearchPath
    ) {
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

    /// `~/.claude-profiles/heartbeat/<slug>.log`: what the agent printed.
    public func logURL(for slug: String) -> URL {
        paths.root.appendingPathComponent("heartbeat", isDirectory: true)
            .appendingPathComponent(slug + ".log")
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
        let dictionary: [String: Any] = [
            "Label": label(for: profile.slug),
            "ProgramArguments": [paths.script(for: profile.slug).path, "-p", Self.prompt],
            "StartCalendarInterval": Self.calendarEntries(for: profile.heartbeat),
            "EnvironmentVariables": ["PATH": searchPath()],
            "WorkingDirectory": paths.home.path,
            "StandardOutPath": logURL(for: profile.slug).path,
            "StandardErrorPath": logURL(for: profile.slug).path,
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
        try manager.createDirectory(at: logURL(for: profile.slug).deletingLastPathComponent(), withIntermediateDirectories: true)

        // Unchanged and loaded: nothing to do.
        if (try? Data(contentsOf: target)) == data, isLoaded(slug: profile.slug) { return }

        _ = try? runner.run(Self.launchctl, ["bootout", domain(for: profile.slug)])
        try data.write(to: target, options: .atomic)
        let result = try runner.run(Self.launchctl, ["bootstrap", "gui/\(userID)", target.path])
        guard result.isSuccess else { throw ProfileError.heartbeatFailed("launchctl: " + result.output) }
    }

    /// Unloads the agent of `slug` and deletes its file. Absent is fine.
    public func remove(slug: String) {
        guard Slug.isSafe(slug) else { return }
        _ = try? runner.run(Self.launchctl, ["bootout", domain(for: slug)])
        try? FileManager.default.removeItem(at: plistURL(for: slug))
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
        for slug in installedSlugs() where !wanted.contains(slug) {
            remove(slug: slug)
        }
        return failed
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
