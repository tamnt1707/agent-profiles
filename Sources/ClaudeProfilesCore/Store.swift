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
        if others.contains(where: { $0.slug == profile.slug }) {
            throw ProfileError.duplicateSlug(profile.slug)
        }
        let url = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && !url.hasPrefix("https://") && !url.hasPrefix("http://") {
            throw ProfileError.invalidBaseURL
        }
        _ = try ShellQuote.parseExtraEnv(profile.extraEnv)
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
        if let key = try keys.get(old) {
            try keys.set(new, key: key)
            try keys.delete(old)
        }
        try? FileManager.default.removeItem(at: paths.script(for: old))
        let oldHome = paths.home(for: old)
        let newHome = paths.home(for: new)
        let manager = FileManager.default
        if manager.fileExists(atPath: oldHome.path), !manager.fileExists(atPath: newHome.path) {
            try manager.moveItem(at: oldHome, to: newHome)
        }
    }

    /// Removes a profile's launcher and key. The config folder (sessions,
    /// history) is kept on purpose.
    public func remove(_ profile: Profile) throws {
        try? FileManager.default.removeItem(at: paths.script(for: profile.slug))
        try keys.delete(profile.slug)
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
        out += "  \"appearance\": \(escape(data.appearance.rawValue))\n"
        out += "}"
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
