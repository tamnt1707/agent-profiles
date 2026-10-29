import Foundation

/// The outcome of reading `profiles.json`.
public struct LoadedData: Sendable {
    /// The profiles that could be read (empty when the file is missing or broken).
    public var data: AppData
    /// Set when the file existed but could not be read or parsed.
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

/// Store failures that have no case in `ProfileError`.
public enum StoreError: LocalizedError, Equatable, Sendable {
    /// `profiles.json` could not be read, so it is not overwritten by an
    /// automatic save. A copy of the unreadable file exists. A successful write
    /// of `profiles.json` clears this state.
    case dataFileNotLoaded(String)
    /// `profiles.json` could not be read and no copy of it exists, so nothing is written.
    case dataFileUnreadable(String)
    /// A slug that is not safe to use as a file name.
    case unsafeSlug(String)
    /// The config folder of the new slug already exists. It is never adopted.
    case targetHomeExists(String)
    /// The file could not be read and no copy of it exists, so an explicit save is refused too.
    case noBackup(String)

    public var errorDescription: String? {
        switch self {
        case .dataFileNotLoaded(let path): return "profiles.json was not loaded and is not overwritten: \(path)"
        case .dataFileUnreadable(let path): return "profiles.json could not be read and no copy exists: \(path)"
        case .unsafeSlug(let slug): return "unsafe profile slug: \(slug)"
        case .targetHomeExists(let path): return "config folder already exists: \(path)"
        case .noBackup(let path): return "no copy of the unreadable file could be made: \(path)"
        }
    }
}

/// Whether the last read of `profiles.json` failed. Shared by every copy of a
/// `Store`, because `Store` is a value type.
private final class LoadState {
    var failed = false
    /// The copy of the unreadable file, when one was made.
    var backup: URL?
    /// An explicit profile save succeeded while the file was unreadable. The
    /// failed state ends only when the next write of `profiles.json` succeeds.
    var recovering = false
}

/// What a rename changed, so that a later failure can undo exactly that.
private struct RenameRecord {
    /// The key that was moved from the old slug to the new one.
    var movedKey: String?
    /// The value the new slug had before the move (a stale entry, if any).
    var newKeyBefore: String?
    /// The config folder was moved from the old slug to the new one.
    var homeMoved = false
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
    private let loadState = LoadState()
    /// Writes the copy of an unreadable file. Injected by tests to make the copy fail.
    private let writeBackup: (Data, URL) throws -> Void

    public init(paths: Paths = Paths(), keys: KeyStore = KeychainStore()) {
        self.init(paths: paths, keys: keys, writeBackup: { bytes, target in
            try bytes.write(to: target, options: .withoutOverwriting)
        })
    }

    init(paths: Paths, keys: KeyStore, writeBackup: @escaping (Data, URL) throws -> Void) {
        self.paths = paths
        self.keys = keys
        self.writeBackup = writeBackup
    }

    /// `true` when the last `load()` could not read `profiles.json`. Automatic
    /// saves are refused until `profiles.json` is written again.
    public var loadFailed: Bool { loadState.failed }

    /// `true` when the copy of the unreadable file exists on disk.
    private var hasCopyOfDataFile: Bool {
        guard let backup = loadState.backup else { return false }
        return FileManager.default.fileExists(atPath: backup.path)
    }

    /// Items shared read-through from `~/.claude`. `settings.json` and the
    /// credentials are deliberately NOT shared, so every profile keeps its own
    /// provider settings.
    public static let sharedItems = ["CLAUDE.md", "skills", "commands", "agents", "output-styles"]

    // MARK: - Data file

    /// Reads `profiles.json`. A file that cannot be read or parsed, or that holds
    /// a profile with an unsafe slug, is copied to `profiles.json.corrupt-<unix
    /// time>` instead of being silently replaced, and `loadFailed` is set. The
    /// settings of such a file are still read and kept; the profile list is empty.
    ///
    /// Calling `load()` again is the reload: a file that parses now clears the
    /// failed state, and a file that is still broken stays failed without a
    /// second copy of the same content.
    public func load() -> LoadedData {
        let file = paths.dataFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            loadState.failed = false
            loadState.recovering = false
            loadState.backup = nil
            return LoadedData(data: AppData())
        }
        guard let bytes = try? Data(contentsOf: file) else {
            return failedLoad(bytes: nil)
        }
        guard let data = Store.parse(bytes) else {
            return failedLoad(bytes: bytes)
        }
        loadState.failed = false
        loadState.recovering = false
        loadState.backup = nil
        return LoadedData(data: data)
    }

    /// `true` when `load()` would read `profiles.json` without a warning. Nothing
    /// is changed: no copy is made and the failed state stays as it is.
    public func isReadable() -> Bool {
        let file = paths.dataFile
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        guard let bytes = try? Data(contentsOf: file) else { return false }
        return Store.parse(bytes) != nil
    }

    /// The profiles of a file that is valid, `nil` for a broken one.
    private static func parse(_ bytes: Data) -> AppData? {
        guard String(data: bytes, encoding: .utf8) != nil,
              let data = try? JSONDecoder().decode(AppData.self, from: bytes),
              data.profiles.allSatisfy({ Slug.isSafe($0.slug) })
        else {
            return nil
        }
        return data
    }

    /// Records the failed load, copies the file aside and names the copy.
    private func failedLoad(bytes: Data?) -> LoadedData {
        loadState.failed = true
        loadState.recovering = false
        let settings = bytes.map(AppData.settingsOnly(from:)) ?? AppData()
        loadState.backup = backUpDataFile(bytes)
        guard let backup = loadState.backup else {
            return LoadedData(data: settings, warning: .dataUnreadable(paths.dataFile.path))
        }
        return LoadedData(data: settings, warning: .corruptFileBackedUp(path: backup.path))
    }

    /// Writes `profiles.json` atomically: a temporary file then a rename.
    ///
    /// Refused while the last load failed, so that a file which could not be
    /// read is never overwritten by a save of the (empty) in-memory list. The
    /// one exception is the write that follows a successful explicit profile
    /// save. A successful write clears the failed state.
    public func save(_ data: AppData) throws {
        guard !loadState.failed || loadState.recovering else {
            throw hasCopyOfDataFile
                ? StoreError.dataFileNotLoaded(paths.dataFile.path)
                : StoreError.dataFileUnreadable(paths.dataFile.path)
        }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        // The name carries the pid, so two running instances never share one file.
        let temporary = paths.root.appendingPathComponent(
            "profiles.json.\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        let text = JSONText.encode(data)
        do {
            try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ProfileError.ioFailed(temporary.path)
        }
        guard rename(temporary.path, paths.dataFile.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ProfileError.ioFailed(paths.dataFile.path)
        }
        // Only now is profiles.json readable again.
        loadState.failed = false
        loadState.recovering = false
    }

    /// Copies `profiles.json` aside as `profiles.json.corrupt-<unix time>`.
    ///
    /// Content that was already copied is not copied again. A different copy in
    /// the same second gets a counter, so an earlier copy is never overwritten.
    /// Returns `nil` when no copy could be made.
    private func backUpDataFile(_ bytes: Data?) -> URL? {
        let manager = FileManager.default
        let prefix = "profiles.json.corrupt-"
        if let bytes {
            let existing = (try? manager.contentsOfDirectory(atPath: paths.root.path)) ?? []
            for name in existing where name.hasPrefix(prefix) {
                let candidate = paths.root.appendingPathComponent(name)
                if let copy = try? Data(contentsOf: candidate), copy == bytes {
                    return candidate
                }
            }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        var target = paths.root.appendingPathComponent("\(prefix)\(stamp)")
        var counter = 1
        while manager.fileExists(atPath: target.path) {
            target = paths.root.appendingPathComponent("\(prefix)\(stamp)-\(counter)")
            counter += 1
        }
        do {
            try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            if let bytes {
                try writeBackup(bytes, target)
            } else {
                try manager.copyItem(at: paths.dataFile, to: target)
            }
            return target
        } catch {
            return nil
        }
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
        // The slug becomes a file name and a Keychain account: nothing else may reach them.
        guard Slug.isSafe(profile.slug) else {
            throw StoreError.unsafeSlug(profile.slug)
        }
        if let other = others.first(where: { $0.slug == profile.slug }) {
            throw ProfileError.duplicateCommand(profile.slug, other.name)
        }
        let url = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty && !url.hasPrefix("https://") && !url.hasPrefix("http://") {
            throw ProfileError.invalidBaseURL
        }
        // The working folder ends up in a command that is typed into a live
        // shell, so a folder with a control character in its name is refused
        // here, before the profile is saved.
        let workdir = profile.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workdir.isEmpty, !FolderPathSafety.isSafe(workdir) {
            throw ProfileError.unsafeFolderToSave(profile.workdir)
        }
        _ = try ShellQuote.parseExtraEnv(profile.extraEnv)
        // Prices are typed by hand: only finite, non-negative values are kept.
        guard UsageCost.isValidPrice(profile.priceInputPerMillion),
              UsageCost.isValidPrice(profile.priceOutputPerMillion)
        else {
            throw ProfileError.invalidPrice
        }
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
        try writeLauncher(script, to: scriptURL)
        if profile.isolate {
            let home = paths.home(for: profile.slug)
            try manager.createDirectory(at: home, withIntermediateDirectories: true)
            if profile.shareFromDefault {
                try linkShared(home)
            }
        }
    }

    /// Writes an executable launcher atomically: the text goes to a new file
    /// next to the target, which is made executable and renamed over the target.
    ///
    /// A symbolic link at the target is replaced, never written through, and a
    /// reader never sees a half written script.
    private func writeLauncher(_ script: String, to target: URL) throws {
        let manager = FileManager.default
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        )
        do {
            try Data(script.utf8).write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        } catch {
            try? manager.removeItem(at: temporary)
            throw ProfileError.ioFailed(target.path)
        }
        guard rename(temporary.path, target.path) == 0 else {
            try? manager.removeItem(at: temporary)
            throw ProfileError.ioFailed(target.path)
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

    /// Handles a rename: moves the Keychain entry and the config folder and
    /// removes the old launcher.
    ///
    /// Nothing changes when `homes/<new>` already exists: such a folder is never
    /// adopted. A failure undoes the moves that already happened.
    /// `ownsOldLauncher` says that the old launcher belongs to this profile even
    /// without the marker (an older version wrote it that way).
    public func migrateSlug(from old: String, to new: String, ownsOldLauncher: Bool = false) throws {
        guard old != new, !old.isEmpty else { return }
        _ = try performRename(from: old, to: new, ownsOldLauncher: ownsOldLauncher)
    }

    /// The moves of a rename. On failure the moves that were made are undone
    /// before the error is thrown; on success the record is returned.
    private func performRename(from old: String, to new: String, ownsOldLauncher: Bool) throws -> RenameRecord {
        guard Slug.isSafe(old) else { throw StoreError.unsafeSlug(old) }
        guard Slug.isSafe(new) else { throw StoreError.unsafeSlug(new) }

        let oldHome = paths.home(for: old)
        let newHome = paths.home(for: new)
        // Checked before anything changes. A folder of the new name is never adopted.
        guard SafeFileSystem.kind(of: newHome) == .missing else {
            throw StoreError.targetHomeExists(newHome.path)
        }

        var record = RenameRecord()
        do {
            // The Keychain entry moves first.
            if let key = try keys.get(old) {
                record.newKeyBefore = try keys.get(new)
                record.movedKey = key
                try keys.set(new, key: key)
                try keys.delete(old)
            }

            // The config folder moves with the profile.
            if SafeFileSystem.kind(of: oldHome) != .missing {
                do {
                    try FileManager.default.moveItem(at: oldHome, to: newHome)
                } catch {
                    throw ProfileError.ioFailed(oldHome.path)
                }
                record.homeMoved = true
            }
        } catch {
            undoMoves(record, from: old, to: new)
            throw error
        }

        // The old launcher goes last. A file that is not ours is kept.
        let oldScript = paths.script(for: old)
        if ownsOldLauncher || ScriptRenderer.isManagedLauncher(at: oldScript) {
            try? SafeFileSystem.remove(at: oldScript)
        }
        return record
    }

    /// Moves the Keychain entry and the config folder back as far as they moved.
    /// Only what the record names is touched.
    private func undoMoves(_ record: RenameRecord, from old: String, to new: String) {
        if record.homeMoved {
            try? FileManager.default.moveItem(at: paths.home(for: new), to: paths.home(for: old))
        }
        if let moved = record.movedKey {
            try? keys.set(old, key: moved)
            if let before = record.newKeyBefore {
                try? keys.set(new, key: before)
            } else {
                try? keys.delete(new)
            }
        }
    }

    /// Undoes a whole rename after a later step failed: the moves are undone, the
    /// launcher of the new name is taken away when it is ours, and the launcher
    /// of the old name is written again.
    private func undoRename(
        _ record: RenameRecord,
        from old: String,
        to new: String,
        previous: Profile?,
        strings: ScriptStrings
    ) {
        undoMoves(record, from: old, to: new)

        let newScript = paths.script(for: new)
        if ScriptRenderer.isManagedLauncher(at: newScript) {
            try? SafeFileSystem.remove(at: newScript)
        }

        if let previous {
            try? materialize(previous, strings: strings)
        }
    }

    // MARK: - Saving

    /// Saves a profile: the launcher, the Keychain entry and the config folder.
    ///
    /// Everything that can be checked without a side effect is checked first.
    /// A rename happens before the launcher is written, and the typed key is
    /// written last: a failure at any earlier step leaves the old key and the
    /// old files as they were. A successful explicit save lets the write of
    /// `profiles.json` that follows it clear the state set by a failed load.
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
        // After a failed load the first explicit save needs the copy of the
        // original file. Without it the unreadable list is never replaced.
        if loadState.failed {
            guard hasCopyOfDataFile else {
                throw StoreError.noBackup(paths.dataFile.path)
            }
        }

        let renamedFrom = previous.flatMap { $0.slug == profile.slug ? nil : $0.slug }
        let secret = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // A key that is needed but neither typed nor stored is refused before the
        // rename, so a rejected save moves nothing. After a rename the key sits
        // under the new name, which holds whatever the old name held.
        if profile.auth != .none, secret.isEmpty {
            var hasKey = try keys.hasKey(profile.slug)
            if let renamedFrom, !hasKey {
                hasKey = try keys.hasKey(renamedFrom)
            }
            guard hasKey else { throw ProfileError.missingAPIKey }
        }

        // 2. The rename, the launcher and the key.
        var record: RenameRecord?
        do {
            if let renamedFrom {
                record = try performRename(from: renamedFrom, to: profile.slug, ownsOldLauncher: previous != nil)
            }
            try materialize(profile, strings: strings)
            if profile.auth == .none {
                // No credential is used, so a stored one is removed and a typed one is never stored.
                try keys.delete(profile.slug)
            } else if !secret.isEmpty {
                try keys.set(profile.slug, key: secret)
            }
        } catch {
            if let renamedFrom, let record {
                undoRename(record, from: renamedFrom, to: profile.slug, previous: previous, strings: strings)
            }
            throw error
        }

        // The failed state ends with the next successful write of profiles.json.
        if loadState.failed {
            loadState.recovering = true
        }
        return SaveResult(slug: profile.slug, renamedFrom: renamedFrom)
    }

    // MARK: - Removing

    /// Removes the `bin` and `homes` folders of the data root when they are empty.
    ///
    /// Nothing else is removed: a folder with content stays, and the root folder
    /// itself (it also holds `profiles.json`) is never touched.
    public func removeEmptySharedFolders() {
        for folder in [paths.binDir, paths.homesDir] {
            guard SafeFileSystem.kind(of: folder) == .directory else { continue }
            // A folder that cannot be listed is kept.
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  children.isEmpty
            else { continue }
            _ = rmdir(folder.path)
        }
    }

    /// The config folder of a profile, when it is safe to remove it.
    ///
    /// The slug has to be a single harmless path component and the folder has
    /// to be a direct child of `<root>/homes/`. A folder that is a symbolic
    /// link is allowed: only the link itself is removed.
    func validatedHomePath(for slug: String) throws -> URL {
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

    /// How many times the config folder of a profile is emptied before the leftover is reported.
    static let removeAttempts = 4

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
            // A Claude Code that still runs in a terminal of this profile may
            // write a file while the folder is being emptied, and the last
            // `rmdir` then fails. The walk is repeated a few times: the second
            // one finds only what was written in between.
            var lastError: Error?
            for attempt in 0..<Store.removeAttempts {
                do {
                    try SafeFileSystem.remove(at: home)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt + 1 < Store.removeAttempts { usleep(150_000) }
                }
            }
            if lastError == nil {
                report.removedHome = true
            } else {
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
        if data.pathPromptDeclined {
            out += ",\n  \"path_prompt_declined\": true"
        }
        // The rule of the field is in one place: it is written only when the
        // menu bar is turned off.
        out += MenuBarSetting.json(data.showMenuBar)
        if let lastUpdateCheck = data.lastUpdateCheck {
            out += ",\n  \"last_update_check\": \(escape(Timestamp.string(from: lastUpdateCheck)))"
        }
        out += "\n}"
        return out
    }

    static func encode(_ profile: Profile, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        var fields = [
            "\"name\": \(escape(profile.name))",
            "\"slug\": \(escape(profile.slug))",
            "\"base_url\": \(escape(profile.baseURL))",
            "\"auth\": \(escape(profile.auth.rawValue))",
            "\"model\": \(escape(profile.model))",
            "\"opus_model\": \(escape(profile.opusModel))",
            "\"sonnet_model\": \(escape(profile.sonnetModel))",
            "\"haiku_model\": \(escape(profile.haikuModel))",
            "\"extra_env\": \(escape(profile.extraEnv))",
            "\"workdir\": \(escape(profile.workdir))",
            "\"isolate\": \(profile.isolate)",
            "\"share_from_default\": \(profile.shareFromDefault)",
        ]
        // Optional: written only when there is a list, as a multi-line array like serde_json.
        if !profile.recentDirs.isEmpty {
            let item = String(repeating: " ", count: indent + 4)
            let items = profile.recentDirs.map { item + escape($0) }.joined(separator: ",\n")
            fields.append("\"recent_dirs\": [\n\(items)\n\(inner)]")
        }
        // The price keys are written only when set, so a profile without them is
        // written exactly as the older app wrote it.
        if let price = profile.priceInputPerMillion {
            fields.append("\"price_input_per_million\": \(price)")
        }
        if let price = profile.priceOutputPerMillion {
            fields.append("\"price_output_per_million\": \(price)")
        }
        var out = pad + "{\n"
        out += fields.map { inner + $0 }.joined(separator: ",\n") + "\n"
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
