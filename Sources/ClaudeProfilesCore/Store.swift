import Foundation

/// The outcome of reading `profiles.json`.
public struct LoadedData: Sendable {
    /// The profiles that could be read (empty when the file is missing or broken).
    public var data: AppData
    /// Set when the file existed but could not be parsed.
    public var warning: ProfileError?

    public init(data: AppData, warning: ProfileError? = nil) {
        self.data = data
        self.warning = warning
    }
}

/// Something that could not be removed and has to be cleaned up by hand.
public enum RemovalFailure: Equatable, Sendable {
    /// The Keychain entry (the account name).
    case key(String)
    /// The launcher script (the path).
    case script(String)
    /// The config folder (the path).
    case home(String)
    /// The entry in `profiles.json`.
    case dataFile
}

/// What the removal of a profile did.
public struct RemovalReport: Equatable, Sendable {
    /// The Keychain entry is gone.
    public var removedKey: Bool
    /// The launcher is gone.
    public var removedScript: Bool
    /// The config folder is gone.
    public var removedHome: Bool
    /// What is still on the disk.
    public var failures: [RemovalFailure]

    public init(
        removedKey: Bool = false,
        removedScript: Bool = false,
        removedHome: Bool = false,
        failures: [RemovalFailure] = []
    ) {
        self.removedKey = removedKey
        self.removedScript = removedScript
        self.removedHome = removedHome
        self.failures = failures
    }
}

/// The result of a successful save.
public struct SaveResult: Equatable, Sendable {
    /// The slug that was saved.
    public var slug: String
    /// The slug the profile had before, when it was renamed.
    public var renamedFrom: String?
}

/// Profiles on disk, launcher scripts and per-profile Claude config folders.
///
/// Layout (everything under `~/.claude-profiles`, nothing touches `~/.claude`):
///   profiles.json            profile list + app settings (no secrets)
///   bin/claude-<slug>        launcher script per profile
///   homes/<slug>/            CLAUDE_CONFIG_DIR for that profile
public struct Store {
    public let paths: Paths
    public let keys: KeyStore

    public init(paths: Paths = Paths(), keys: KeyStore = KeychainStore()) {
        self.paths = paths
        self.keys = keys
    }

    /// Items shared read-through from `~/.claude`. `settings.json` and the
    /// credentials are deliberately NOT shared, so every profile keeps its own
    /// provider settings.
    public static let sharedItems = ["CLAUDE.md", "skills", "commands", "agents", "output-styles"]

    // MARK: - Data file

    /// Reads `profiles.json`. A file that cannot be parsed is copied to
    /// `profiles.json.corrupt-<unix time>` instead of being silently replaced.
    public func load() -> LoadedData {
        guard FileManager.default.fileExists(atPath: paths.dataFile.path) else {
            return LoadedData(data: AppData())
        }
        guard let raw = try? String(contentsOf: paths.dataFile, encoding: .utf8) else {
            return LoadedData(data: AppData(), warning: .ioFailed(paths.dataFile.path))
        }
        if let data = try? JSONDecoder().decode(AppData.self, from: Data(raw.utf8)) {
            return LoadedData(data: data)
        }
        let backup = backUpCorruptFile(raw)
        return LoadedData(data: AppData(), warning: .corruptFileBackedUp(path: backup.path))
    }

    /// Writes `profiles.json` atomically: `profiles.json.tmp` then a rename.
    public func save(_ data: AppData) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let temporary = paths.root.appendingPathComponent("profiles.json.tmp")
        let text = JSONText.encode(data)
        do {
            try Data(text.utf8).write(to: temporary)
        } catch {
            throw ProfileError.ioFailed(temporary.path)
        }
        guard rename(temporary.path, paths.dataFile.path) == 0 else {
            throw ProfileError.ioFailed(paths.dataFile.path)
        }
    }

    /// Copies a broken `profiles.json` aside, at most once per content.
    private func backUpCorruptFile(_ raw: String) -> URL {
        let manager = FileManager.default
        let prefix = "profiles.json.corrupt-"
        let existing = (try? manager.contentsOfDirectory(atPath: paths.root.path)) ?? []
        for name in existing where name.hasPrefix(prefix) {
            let candidate = paths.root.appendingPathComponent(name)
            if let copy = try? String(contentsOf: candidate, encoding: .utf8), copy == raw {
                return candidate
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let target = paths.root.appendingPathComponent("\(prefix)\(stamp)")
        try? raw.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    // MARK: - Validation

    /// Checks a profile against the other profiles of the list.
    public func validate(_ profile: Profile, others: [Profile]) throws {
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileError.emptyName
        }
        if profile.slug.isEmpty {
            throw ProfileError.emptySlug
        }
        if let other = others.first(where: { $0.slug == profile.slug }) {
            throw ProfileError.duplicateCommand(profile.slug, other.name)
        }
        let url = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && !url.hasPrefix("https://") && !url.hasPrefix("http://") {
            throw ProfileError.invalidBaseURL
        }
        _ = try ShellQuote.parseExtraEnv(profile.extraEnv)
    }

    // MARK: - Command name

    /// The path of a file in `bin/` that this app did not write, if there is one.
    ///
    /// The launcher of the profile that is edited belongs to the app, even when
    /// an older version wrote it without the marker. Every other file is
    /// foreign: it is never overwritten and never deleted.
    public func foreignCommandPath(for slug: String, ownedBy owner: String?) -> String? {
        guard slug != owner else { return nil }
        let url = paths.script(for: slug)
        guard SafeFileSystem.kind(of: url) != .missing else { return nil }
        guard ScriptRenderer.isManagedLauncher(at: url) else { return url.path }
        return nil
    }

    /// Throws when the command name is taken by a file this app did not write.
    public func validateCommandFile(_ slug: String, ownedBy owner: String?) throws {
        if let path = foreignCommandPath(for: slug, ownedBy: owner) {
            throw ProfileError.foreignCommandExists(slug, path)
        }
    }

    // MARK: - Files

    /// Writes the launcher, creates the isolated config folder and the shared links.
    public func materialize(_ profile: Profile, strings: ScriptStrings = .english) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let scriptURL = paths.script(for: profile.slug)
        let script = try ScriptRenderer.render(profile: profile, paths: paths, strings: strings)
        do {
            try Data(script.utf8).write(to: scriptURL)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw ProfileError.ioFailed(scriptURL.path)
        }
        if profile.isolate {
            let home = paths.home(for: profile.slug)
            try manager.createDirectory(at: home, withIntermediateDirectories: true)
            if profile.shareFromDefault {
                try linkShared(home)
            }
        }
    }

    /// Symlinks the shared items of `~/.claude` into an isolated profile home.
    private func linkShared(_ home: URL) throws {
        let manager = FileManager.default
        for item in Store.sharedItems {
            let source = paths.defaultClaudeDir.appendingPathComponent(item)
            let destination = home.appendingPathComponent(item)
            guard manager.fileExists(atPath: source.path) else { continue }
            // `attributesOfItem` does not follow symlinks: an existing (even
            // broken) link is left alone.
            if (try? manager.attributesOfItem(atPath: destination.path)) != nil { continue }
            try manager.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }

    /// Handles a rename: moves the Keychain entry, the launcher and the config folder.
    public func migrateSlug(from old: String, to new: String) throws {
        guard old != new, !old.isEmpty else { return }

        // The Keychain entry moves first: when it fails, nothing else changed.
        if let key = try keys.get(old) {
            try keys.set(new, key: key)
            do {
                try keys.delete(old)
            } catch {
                // The key would be stored twice: undo the move.
                try? keys.delete(new)
                throw error
            }
        }

        // The old launcher is replaced by the new one when the profile is written.
        try? SafeFileSystem.remove(at: paths.script(for: old))

        // The config folder moves with the profile.
        let oldHome = paths.home(for: old)
        let newHome = paths.home(for: new)
        if SafeFileSystem.kind(of: oldHome) != .missing, SafeFileSystem.kind(of: newHome) == .missing {
            do {
                try FileManager.default.moveItem(at: oldHome, to: newHome)
            } catch {
                throw ProfileError.ioFailed(oldHome.path)
            }
        }
    }

    /// Undoes a rename as far as possible: the Keychain entry and the config
    /// folder move back and the old launcher is written again.
    public func rollbackSlug(from new: String, to old: String, restoring previous: Profile?, strings: ScriptStrings = .english) {
        // The Keychain entry moves back.
        if let key = try? keys.get(new) {
            try? keys.set(old, key: key)
            try? keys.delete(new)
        }

        // The config folder moves back.
        let newHome = paths.home(for: new)
        let oldHome = paths.home(for: old)
        if SafeFileSystem.kind(of: newHome) != .missing, SafeFileSystem.kind(of: oldHome) == .missing {
            try? FileManager.default.moveItem(at: newHome, to: oldHome)
        }

        // The launcher of the new name is taken away again, but only when it is
        // one of ours.
        let newScript = paths.script(for: new)
        if ScriptRenderer.isManagedLauncher(at: newScript) {
            try? SafeFileSystem.remove(at: newScript)
        }

        // The old launcher is written again.
        if let previous {
            try? materialize(previous, strings: strings)
        }
    }

    // MARK: - Saving

    /// Saves a profile: the launcher, the Keychain entry and the config folder.
    ///
    /// Everything that can be checked without a side effect is checked first,
    /// so a rejected profile does not change the Keychain or the disk. When a
    /// step after the rename fails, the rename is rolled back.
    @discardableResult
    public func saveProfile(
        _ profile: Profile,
        others: [Profile],
        previous: Profile? = nil,
        key: String? = nil,
        strings: ScriptStrings = .english
    ) throws -> SaveResult {
        // 1. The checks, before anything is changed.
        try validate(profile, others: others)
        try validateCommandFile(profile.slug, ownedBy: previous?.slug)

        // 2. The rename and everything that follows it.
        let renamedFrom = previous.flatMap { $0.slug == profile.slug ? nil : $0.slug }
        do {
            if let renamedFrom {
                try migrateSlug(from: renamedFrom, to: profile.slug)
            }

            let secret = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !secret.isEmpty {
                try keys.set(profile.slug, key: secret)
            }
            if profile.auth != .none, (try keys.get(profile.slug)) == nil {
                throw ProfileError.missingAPIKey
            }
            try materialize(profile, strings: strings)
        } catch {
            // The rename is undone as far as possible.
            if let renamedFrom {
                rollbackSlug(from: profile.slug, to: renamedFrom, restoring: previous, strings: strings)
            }
            throw error
        }

        return SaveResult(slug: profile.slug, renamedFrom: renamedFrom)
    }

    // MARK: - Removing

    /// The config folder of a profile, when it is safe to remove it.
    ///
    /// The slug has to be a single harmless path component and the folder has
    /// to be a direct child of `<root>/homes/`. A folder that is a symbolic
    /// link is allowed: only the link itself is removed.
    private func validatedHomePath(for slug: String) throws -> URL {
        let home = paths.home(for: slug)
        guard Slug.isSafe(slug) else {
            throw ProfileError.unsafeDeletePath(home.path)
        }
        let parent = home.deletingLastPathComponent()
        guard parent.standardizedFileURL == paths.homesDir.standardizedFileURL,
              home.lastPathComponent == slug,
              parent.resolvingSymlinksInPath() == paths.homesDir.resolvingSymlinksInPath() else {
            throw ProfileError.unsafeDeletePath(home.path)
        }
        return home
    }

    /// Removes everything that belongs to a profile: the Keychain entry, the
    /// launcher and the whole config folder with its sessions and history.
    ///
    /// An unsafe slug or path refuses the whole removal and nothing is
    /// deleted. After that every step is attempted, even when an earlier one
    /// failed, and the leftovers are reported so the user can remove them by
    /// hand.
    public func remove(_ profile: Profile) throws -> RemovalReport {
        let home = try validatedHomePath(for: profile.slug)
        var report = RemovalReport()

        // 1. The Keychain entry.
        do {
            try keys.delete(profile.slug)
            report.removedKey = true
        } catch {
            report.failures.append(.key(profile.slug))
        }

        // 2. The launcher. A file of another program is never deleted.
        let script = paths.script(for: profile.slug)
        switch SafeFileSystem.kind(of: script) {
        case .missing:
            report.removedScript = true
        default:
            if ScriptRenderer.isManagedLauncher(at: script) {
                do {
                    try SafeFileSystem.remove(at: script)
                    report.removedScript = true
                } catch {
                    report.failures.append(.script(script.path))
                }
            } else {
                report.failures.append(.script(script.path))
            }
        }

        // 3. The config folder, even when the profile is not isolated.
        switch SafeFileSystem.kind(of: home) {
        case .missing:
            report.removedHome = true
        default:
            do {
                try SafeFileSystem.remove(at: home)
                report.removedHome = true
            } catch {
                report.failures.append(.home(home.path))
            }
        }

        return report
    }
}

/// Writes JSON exactly like the Rust implementation did, so that the file stays
/// byte compatible with the old app: two space indentation, the same key order
/// and the same escaping.
enum JSONText {
    static func encode(_ data: AppData) -> String {
        var out = "{\n"
        out += "  \"terminal\": \(escape(data.terminal.rawValue)),\n"
        out += "  \"profiles\": "
        if data.profiles.isEmpty {
            out += "[],\n"
        } else {
            out += "[\n"
            for (index, profile) in data.profiles.enumerated() {
                out += encode(profile, indent: 4)
                out += index == data.profiles.count - 1 ? "\n" : ",\n"
            }
            out += "  ],\n"
        }
        out += "  \"language\": \(escape(data.language.rawValue)),\n"
        out += "  \"appearance\": \(escape(data.appearance.rawValue)),\n"
        out += "  \"auto_check_updates\": \(data.autoCheckUpdates)"
        if let lastUpdateCheck = data.lastUpdateCheck {
            out += ",\n  \"last_update_check\": \(escape(Timestamp.string(from: lastUpdateCheck)))"
        }
        out += "\n}"
        return out
    }

    static func encode(_ profile: Profile, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        var out = pad + "{\n"
        out += "\(inner)\"name\": \(escape(profile.name)),\n"
        out += "\(inner)\"slug\": \(escape(profile.slug)),\n"
        out += "\(inner)\"base_url\": \(escape(profile.baseURL)),\n"
        out += "\(inner)\"auth\": \(escape(profile.auth.rawValue)),\n"
        out += "\(inner)\"model\": \(escape(profile.model)),\n"
        out += "\(inner)\"opus_model\": \(escape(profile.opusModel)),\n"
        out += "\(inner)\"sonnet_model\": \(escape(profile.sonnetModel)),\n"
        out += "\(inner)\"haiku_model\": \(escape(profile.haikuModel)),\n"
        out += "\(inner)\"extra_env\": \(escape(profile.extraEnv)),\n"
        out += "\(inner)\"workdir\": \(escape(profile.workdir)),\n"
        out += "\(inner)\"isolate\": \(profile.isolate),\n"
        out += "\(inner)\"share_from_default\": \(profile.shareFromDefault)\n"
        out += "\(pad)}"
        return out
    }

    /// Escapes a string the way `serde_json` does.
    static func escape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
