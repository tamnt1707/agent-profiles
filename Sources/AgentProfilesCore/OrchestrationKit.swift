import Foundation

/// The Claude Orchestration Kit: six subagents and the instructions of the
/// orchestrator session, installed into the config folder of one profile.
///
/// The files and the managed block of `CLAUDE.md` are the ones that the
/// `install.sh` of the kit writes, so a profile that was set up with the script
/// is recognized, and the other way round.
public enum OrchestrationKit {
    /// The agents, in the order of the kit.
    public static let agentNames = ["scout", "researcher", "builder", "tester", "reviewer", "committer"]

    /// The lines that mark the block of `CLAUDE.md` that the kit owns.
    public static let beginMark = "<!-- BEGIN claude-orchestration-kit (managed by install.sh; edits inside this block are overwritten on reinstall) -->"
    public static let endMark = "<!-- END claude-orchestration-kit -->"

    /// Which models the agents ask for.
    public enum ModelMode: Equatable, Sendable {
        /// scout and committer use `haiku`, the others `sonnet`.
        case tiered
        /// Every agent uses the model of the session.
        case inherit
    }

    /// Why a profile gets its model mode.
    public enum ModeReason: Equatable, Sendable {
        /// No Base URL: the Anthropic API serves haiku, sonnet and opus.
        case anthropic
        /// A third-party provider that maps opus, sonnet and haiku to three different models.
        case distinctModels(host: String)
        /// A third-party provider with no mapping: a request for `haiku` or `sonnet` would fail.
        case noMapping(host: String)
        /// All three aliases map to the same model: tiers would save nothing.
        case sameModel(String)
        /// A third-party provider with some of the aliases mapped.
        case partialMapping(host: String)
    }

    /// The model mode of a profile and the reason for it.
    public static func modelMode(for profile: Profile) -> (mode: ModelMode, reason: ModeReason) {
        let base = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return (.tiered, .anthropic) }

        let opus = profile.opusModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let sonnet = profile.sonnetModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let haiku = profile.haikuModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host(of: base)

        if !opus.isEmpty, !sonnet.isEmpty, !haiku.isEmpty,
           opus != sonnet, sonnet != haiku, opus != haiku {
            return (.tiered, .distinctModels(host: host))
        }
        if opus.isEmpty, sonnet.isEmpty, haiku.isEmpty {
            return (.inherit, .noMapping(host: host))
        }
        if opus == sonnet, sonnet == haiku {
            return (.inherit, .sameModel(opus))
        }
        return (.inherit, .partialMapping(host: host))
    }

    /// The host of a Base URL, for a sentence.
    private static func host(of base: String) -> String {
        var rest = Substring(base)
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        return String(rest.prefix { $0 != "/" })
    }

    /// The text of `agents/<name>.md` for a model mode.
    public static func agentText(_ name: String, mode: ModelMode) -> String? {
        guard let source = agentSources[name] else { return nil }
        var text = source + "\n"
        if mode == .inherit {
            // Only the model line of the frontmatter changes.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                line.hasPrefix("model:") && line.dropFirst(6).first?.isWhitespace == true ? "model: inherit" : String(line)
            }
            text = lines.joined(separator: "\n")
        }
        return text
    }

    /// The managed block of `CLAUDE.md`, marks included, with its final newline.
    public static var block: String {
        beginMark + "\n" + templateSource + "\n" + endMark + "\n"
    }

    /// `text` without the managed block, and without the one blank line that is put before it.
    public static func removingBlock(from text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A text that ends with a newline has no last line.
        if lines.last == "" { lines.removeLast() }
        var out: [String] = []
        var pendingBlank = false
        var skipping = false
        for line in lines {
            if line == beginMark {
                skipping = true
                pendingBlank = false
                continue
            }
            if skipping {
                if line == endMark { skipping = false }
                continue
            }
            if line.isEmpty {
                if pendingBlank { out.append("") }
                pendingBlank = true
            } else {
                if pendingBlank { out.append("") }
                out.append(line)
                pendingBlank = false
            }
        }
        if pendingBlank { out.append("") }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// `text` with the managed block added, or replaced when it is there.
    public static func addingBlock(to text: String) -> String {
        var out = removingBlock(from: text)
        if !out.isEmpty {
            // One blank line between the content of the user and the block.
            if !out.hasSuffix("\n") { out += "\n" }
            out += "\n"
        }
        return out + block
    }

    /// `true` when the text has the managed block.
    public static func hasBlock(_ text: String) -> Bool {
        text.contains(beginMark)
    }
}

/// Why a part of the kit was not written.
public enum OrchestrationRefusal: Equatable, Sendable {
    /// The folder or the file is a link, shared with another profile. It is never written through.
    case shared
    /// Something else than a folder or a file is in the way.
    case unusable
}

/// The two items of the config folder that the kit writes into.
public enum OrchestrationItem: Equatable, Sendable {
    case agents
    case claudeMd

    var fileName: String {
        switch self {
        case .agents: return "agents"
        case .claudeMd: return "CLAUDE.md"
        }
    }
}

/// What is installed in the config folder of a profile.
public struct OrchestrationStatus: Equatable, Sendable {
    /// How many of the six agent files are there.
    public var agentsPresent: Int
    /// How many of them are what the kit would write now.
    public var agentsCurrent: Int
    /// `true` when the managed block is in `CLAUDE.md`.
    public var hasBlock: Bool
    /// `true` when the managed block is what the kit would write now.
    public var blockCurrent: Bool
    /// Set when `agents/` is a link: nothing can be installed there.
    public var agentsRefusal: OrchestrationRefusal?
    /// Set when `CLAUDE.md` is a link: the block cannot be written there.
    public var claudeMdRefusal: OrchestrationRefusal?
    /// The model mode a new install would use.
    public var mode: OrchestrationKit.ModelMode
    public var reason: OrchestrationKit.ModeReason

    /// Nothing of the kit is there.
    public var isEmpty: Bool { agentsPresent == 0 && !hasBlock }

    /// Everything that can be written is written, and is current.
    public var isCurrent: Bool {
        let agentsDone = agentsRefusal != nil || agentsCurrent == OrchestrationKit.agentNames.count
        let blockDone = claudeMdRefusal != nil || blockCurrent
        return agentsDone && blockDone
    }
}

/// What an install or a removal did.
public struct OrchestrationReport: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        /// Files were written (`changed`) or were already right.
        case done(changed: Int)
        case refused(OrchestrationRefusal)
    }

    public var agents: Part
    public var claudeMd: Part
    public var mode: OrchestrationKit.ModelMode
    public var reason: OrchestrationKit.ModeReason
}

/// Why the kit cannot be installed into a profile.
public enum OrchestrationError: Error, Equatable, Sendable {
    /// The profile shares the folder of Claude Code: its config folder is not its own.
    case notIsolated
    /// The config folder is a link or something that is not a folder.
    case homeNotAFolder(String)
    /// A file could not be written or removed.
    case ioFailed(String)
}

extension Store {
    /// What the kit has in the config folder of the profile.
    public func orchestrationStatus(for profile: Profile) -> OrchestrationStatus {
        let (mode, reason) = OrchestrationKit.modelMode(for: profile)
        var status = OrchestrationStatus(
            agentsPresent: 0, agentsCurrent: 0, hasBlock: false, blockCurrent: false,
            agentsRefusal: nil, claudeMdRefusal: nil, mode: mode, reason: reason
        )
        guard let home = try? kitFolder(for: profile),
              SafeFileSystem.kind(of: home) == .directory else { return status }

        let agentsDir = home.appendingPathComponent("agents")
        switch SafeFileSystem.kind(of: agentsDir) {
        case .directory:
            for name in OrchestrationKit.agentNames {
                let file = agentsDir.appendingPathComponent("\(name).md")
                guard SafeFileSystem.kind(of: file) == .file else { continue }
                status.agentsPresent += 1
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   text == OrchestrationKit.agentText(name, mode: mode) {
                    status.agentsCurrent += 1
                }
            }
        case .missing: break
        case .link: status.agentsRefusal = .shared
        default: status.agentsRefusal = .unusable
        }

        let claudeMd = home.appendingPathComponent("CLAUDE.md")
        switch SafeFileSystem.kind(of: claudeMd) {
        case .file:
            if let text = try? String(contentsOf: claudeMd, encoding: .utf8) {
                status.hasBlock = OrchestrationKit.hasBlock(text)
                status.blockCurrent = status.hasBlock
                    && text == OrchestrationKit.addingBlock(to: text)
            }
        case .missing: break
        case .link: status.claudeMdRefusal = .shared
        default: status.claudeMdRefusal = .unusable
        }
        return status
    }

    /// Installs the agents and the orchestrator block into the config folder of the profile.
    ///
    /// A link is never written through: a profile that shares `agents/` or
    /// `CLAUDE.md` with `~/.claude` would change the files of another profile.
    /// The part that is a link is refused and reported; the other one is done.
    /// A file that is replaced is first copied to `<file>.bak.<timestamp>`.
    public func installOrchestration(for profile: Profile, now: Date = Date()) throws -> OrchestrationReport {
        let home = try orchestrationHome(for: profile, create: true)
        let (mode, reason) = OrchestrationKit.modelMode(for: profile)
        let stamp = Self.backupStamp(now)

        // The agents.
        let agentsDir = home.appendingPathComponent("agents")
        let agents: OrchestrationReport.Part
        switch SafeFileSystem.kind(of: agentsDir) {
        case .link: agents = .refused(.shared)
        case .file, .other: agents = .refused(.unusable)
        case .missing, .directory:
            if SafeFileSystem.kind(of: agentsDir) == .missing {
                do { try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: false) }
                catch { throw OrchestrationError.ioFailed(agentsDir.path) }
            }
            var changed = 0
            for name in OrchestrationKit.agentNames {
                guard let text = OrchestrationKit.agentText(name, mode: mode) else { continue }
                let file = agentsDir.appendingPathComponent("\(name).md")
                if try writeKitFile(text, to: file, stamp: stamp) { changed += 1 }
            }
            agents = .done(changed: changed)
        }

        // The block of CLAUDE.md.
        let claudeMd = home.appendingPathComponent("CLAUDE.md")
        let block: OrchestrationReport.Part
        switch SafeFileSystem.kind(of: claudeMd) {
        case .link: block = .refused(.shared)
        case .directory, .other: block = .refused(.unusable)
        case .missing, .file:
            let current = (try? String(contentsOf: claudeMd, encoding: .utf8)) ?? ""
            let changed = try writeKitFile(OrchestrationKit.addingBlock(to: current), to: claudeMd, stamp: stamp)
            block = .done(changed: changed ? 1 : 0)
        }
        return OrchestrationReport(agents: agents, claudeMd: block, mode: mode, reason: reason)
    }

    /// Removes the six agent files and the managed block. The rest of `agents/` and
    /// of `CLAUDE.md` is left as it is. A link is never written through.
    public func removeOrchestration(for profile: Profile, now: Date = Date()) throws -> OrchestrationReport {
        let home = try orchestrationHome(for: profile, create: false)
        let (mode, reason) = OrchestrationKit.modelMode(for: profile)
        let stamp = Self.backupStamp(now)

        let agentsDir = home.appendingPathComponent("agents")
        let agents: OrchestrationReport.Part
        switch SafeFileSystem.kind(of: agentsDir) {
        case .link: agents = .refused(.shared)
        case .file, .other: agents = .refused(.unusable)
        case .missing: agents = .done(changed: 0)
        case .directory:
            var changed = 0
            for name in OrchestrationKit.agentNames {
                let file = agentsDir.appendingPathComponent("\(name).md")
                guard SafeFileSystem.kind(of: file) == .file else { continue }
                try SafeFileSystem.remove(at: file)
                changed += 1
            }
            agents = .done(changed: changed)
        }

        let claudeMd = home.appendingPathComponent("CLAUDE.md")
        let block: OrchestrationReport.Part
        switch SafeFileSystem.kind(of: claudeMd) {
        case .link: block = .refused(.shared)
        case .directory, .other: block = .refused(.unusable)
        case .missing: block = .done(changed: 0)
        case .file:
            let current = (try? String(contentsOf: claudeMd, encoding: .utf8)) ?? ""
            if OrchestrationKit.hasBlock(current) {
                let changed = try writeKitFile(OrchestrationKit.removingBlock(from: current), to: claudeMd, stamp: stamp)
                block = .done(changed: changed ? 1 : 0)
            } else {
                block = .done(changed: 0)
            }
        }
        return OrchestrationReport(agents: agents, claudeMd: block, mode: mode, reason: reason)
    }

    /// Replaces a link to `~/.claude` (`agents` or `CLAUDE.md`) in the config folder
    /// of the profile with a copy of what it points to.
    ///
    /// The copy is made first and the link is removed only after that, so the
    /// profile is never left without the item. What the link points to is only
    /// read: `~/.claude` is not changed.
    public func unshareOrchestrationItem(_ item: OrchestrationItem, for profile: Profile) throws {
        let home = try orchestrationHome(for: profile, create: false)
        let link = home.appendingPathComponent(item.fileName)
        guard SafeFileSystem.kind(of: link) == .link else { return }

        let manager = FileManager.default
        let temporary = home.appendingPathComponent(".\(item.fileName).\(UUID().uuidString).tmp")
        let target = link.resolvingSymlinksInPath()
        do {
            switch item {
            case .agents:
                try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
                var isFolder: ObjCBool = false
                if manager.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
                    for child in try manager.contentsOfDirectory(atPath: target.path) {
                        try manager.copyItem(
                            at: target.appendingPathComponent(child),
                            to: temporary.appendingPathComponent(child)
                        )
                    }
                }
            case .claudeMd:
                let data = (try? Data(contentsOf: target)) ?? Data()
                try data.write(to: temporary, options: .withoutOverwriting)
            }
            try SafeFileSystem.remove(at: link)
            guard rename(temporary.path, link.path) == 0 else { throw OrchestrationError.ioFailed(link.path) }
        } catch {
            try? SafeFileSystem.remove(at: temporary)
            throw (error as? OrchestrationError) ?? OrchestrationError.ioFailed(link.path)
        }
    }

    /// Where the kit of a profile goes: its own folder, or `~/.claude` for the
    /// default setup. Only the kit is written there, never a delete.
    func kitFolder(for profile: Profile) throws -> URL {
        profile.isDefaultClaude ? paths.defaultClaudeDir : try validatedHomePath(for: profile.slug)
    }

    /// The config folder of an isolated profile, created when asked.
    private func orchestrationHome(for profile: Profile, create: Bool) throws -> URL {
        let home = try kitFolder(for: profile)
        guard profile.isolate else { throw OrchestrationError.notIsolated }
        switch SafeFileSystem.kind(of: home) {
        case .directory: return home
        case .missing:
            guard create else { return home }
            do { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
            catch { throw OrchestrationError.ioFailed(home.path) }
            return home
        default:
            throw OrchestrationError.homeNotAFolder(home.path)
        }
    }

    /// Writes `text` into `file` when it differs. The file that is replaced is
    /// copied first. Returns `true` when the file changed.
    private func writeKitFile(_ text: String, to file: URL, stamp: String) throws -> Bool {
        if SafeFileSystem.kind(of: file) == .file {
            if let old = try? String(contentsOf: file, encoding: .utf8), old == text { return false }
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".bak." + stamp)
            if SafeFileSystem.kind(of: backup) == .missing {
                try? FileManager.default.copyItem(at: file, to: backup)
            }
        }
        do {
            // Written in place, so the file keeps its permissions.
            try Data(text.utf8).write(to: file)
        } catch {
            throw OrchestrationError.ioFailed(file.path)
        }
        return true
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
