import Foundation

/// What went wrong while the shell files were changed.
public enum ShellPathError: Error, Equatable, Sendable {
    /// A file has a broken or duplicated Claude Profiles block (or a foreign file
    /// sits where the fish file belongs). Nothing in that shell is touched.
    case damaged(String)
    /// The shell is not one the app edits.
    case unsupported
    /// A file could not be read or written.
    case ioFailed(String)
}

/// The state of the PATH setup of one shell.
public enum ShellStatus: Equatable, Sendable {
    /// Every file of the shell has the managed block (or the fish file).
    case configured
    /// Some files have it, others do not.
    case partlyConfigured
    /// A line the user wrote by hand already adds the folder. Nothing is edited.
    case manual
    case notConfigured
    /// A block is broken, or a foreign file is in the way. Nothing is edited.
    case damaged
    /// The shell is not one the app edits. The user copies the line by hand.
    case unsupported
}

/// What an install did.
public enum InstallOutcome: Equatable, Sendable {
    /// The files that now carry the setup, and the backups made on the way.
    case added(files: [URL], backups: [URL])
    /// Nothing was changed: the setup is there already (managed or by hand).
    case alreadyConfigured(managed: Bool)
}

/// Adds the `claude-<name>` folder to the PATH of the supported shells.
///
/// Every shell file gets ONE block between exact markers, or the fish shell gets
/// one dedicated file. The block is safe to run twice: it adds the folder to
/// PATH only when it is not there yet, so several files that are read by the
/// same shell never duplicate the entry.
///
/// Removal restores each edited file byte for byte. Only our markers are ever
/// recognised: a line the user wrote is never edited or removed.
public struct ShellPathSetup: Sendable {
    public static let beginMarker = "# >>> Claude Profiles >>>"
    public static let endMarker = "# <<< Claude Profiles <<<"
    /// Appended to the name of an edited file: `.zshrc.claude-profiles.bak`.
    public static let backupSuffix = ".claude-profiles.bak"
    public static let fishFileName = "claude-profiles.fish"

    /// A file the app writes for a shell.
    public enum Target: Equatable, Sendable {
        /// A file that gets the managed block.
        case block(URL)
        /// The dedicated fish file (the whole file belongs to the app).
        case fishFile(URL)

        public var url: URL {
            switch self {
            case .block(let url), .fishFile(let url): return url
            }
        }
    }

    /// The home directory (where `~/.profile` and friends are).
    public let home: URL
    /// The folder that holds the `claude-<name>` launchers.
    public let binDir: URL
    /// The login shell path, for example `/bin/zsh`.
    public let loginShell: String
    /// The process environment, read for `ZDOTDIR` and `XDG_CONFIG_HOME`.
    public let environment: [String: String]

    public init(
        home: URL,
        binDir: URL,
        loginShell: String = ShellPathSetup.currentLoginShell(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.binDir = binDir
        self.loginShell = loginShell
        self.environment = environment
    }

    public init(
        paths: Paths,
        loginShell: String = ShellPathSetup.currentLoginShell(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(home: paths.home, binDir: paths.binDir, loginShell: loginShell, environment: environment)
    }

    /// The login shell of the user, from the account database (not the environment).
    public static func currentLoginShell() -> String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "" }
        return String(cString: shell)
    }

    /// The shell of the login shell path.
    public var loginKind: ShellKind { ShellKind.from(loginShell: loginShell) }

    // MARK: - Locations

    private var zdotdir: URL {
        guard let value = nonEmpty("ZDOTDIR") else { return home }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private var configHome: URL {
        guard let value = nonEmpty("XDG_CONFIG_HOME") else {
            return home.appendingPathComponent(".config", isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private func nonEmpty(_ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    private var fishFile: URL {
        configHome
            .appendingPathComponent("fish", isDirectory: true)
            .appendingPathComponent("conf.d", isDirectory: true)
            .appendingPathComponent(Self.fishFileName)
    }

    private func homeFile(_ name: String) -> URL {
        home.appendingPathComponent(name)
    }

    /// The files a shell reads today, where the setup goes.
    ///
    /// Bash reads only the first existing of `.bash_profile`, `.bash_login` and
    /// `.profile` at login, so that one is used (`.bash_profile` when none
    /// exists). `.bashrc` gets the block too when it exists, for interactive
    /// shells that are not login shells.
    public func targets(for shell: ShellKind) -> [Target] {
        switch shell {
        case .zsh:
            return [.block(zdotdir.appendingPathComponent(".zshrc"))]
        case .bash:
            var result: [Target] = [.block(bashLoginFile())]
            let rc = homeFile(".bashrc")
            if SafeFileSystem.kind(of: rc) != .missing {
                result.append(.block(rc))
            }
            return result
        case .fish:
            return [.fishFile(fishFile)]
        case .posix:
            return [.block(homeFile(".profile"))]
        case .nushell, .csh, .other:
            return []
        }
    }

    private func bashLoginFile() -> URL {
        for name in [".bash_profile", ".bash_login", ".profile"] {
            let url = homeFile(name)
            if SafeFileSystem.kind(of: url) != .missing { return url }
        }
        return homeFile(".bash_profile")
    }

    /// Every file the app may have edited, whether a shell reads it now or not.
    /// Removal looks at all of them, so nothing is left after a shell changed.
    public func candidateTargets() -> [Target] {
        var all: [Target] = [.block(zdotdir.appendingPathComponent(".zshrc")), .block(homeFile(".zshrc"))]
        for name in [".bash_profile", ".bash_login", ".profile", ".bashrc"] {
            all.append(.block(homeFile(name)))
        }
        all.append(.fishFile(fishFile))
        var seen = Set<String>()
        return all.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// The files that may hold a line the user wrote by hand for this shell.
    private func scanFiles(for shell: ShellKind) -> [URL] {
        switch shell {
        case .zsh:
            return [
                zdotdir.appendingPathComponent(".zshrc"),
                zdotdir.appendingPathComponent(".zprofile"),
                zdotdir.appendingPathComponent(".zshenv"),
                homeFile(".zshrc"),
                homeFile(".zprofile"),
                homeFile(".zshenv"),
            ]
        case .bash:
            return [".bash_profile", ".bash_login", ".profile", ".bashrc"].map(homeFile)
        case .fish:
            return [configHome.appendingPathComponent("fish/config.fish")]
        case .posix:
            return [homeFile(".profile")]
        case .nushell, .csh, .other:
            return []
        }
    }

    // MARK: - Paths in the lines

    /// The bin folder relative to the home folder (`.claude-profiles/bin`), or
    /// `nil` when it is not under home or has characters that need quoting.
    private var homeRelative: String? {
        let homePath = home.standardizedFileURL.path
        let binPath = binDir.standardizedFileURL.path
        guard binPath.hasPrefix(homePath + "/") else { return nil }
        let relative = String(binPath.dropFirst(homePath.count + 1))
        guard !relative.isEmpty,
              relative.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
        else { return nil }
        return relative
    }

    private var absoluteBin: String { binDir.standardizedFileURL.path }

    /// The folder for a double quoted shell word: `$HOME/…` or the absolute path.
    private var doubleQuotedBin: String {
        if let relative = homeRelative { return "$HOME/" + relative }
        return absoluteBin
    }

    /// The text of the managed block for the POSIX shells (zsh, bash, sh).
    /// The check makes it a no-op when the folder is already on PATH.
    private var posixBlock: String {
        let pattern: String
        let assignment: String
        if let relative = homeRelative {
            pattern = "*\":$HOME/\(relative):\"*"
            assignment = "export PATH=\"$HOME/\(relative):$PATH\""
        } else {
            pattern = "*" + ShellQuote.quote(":" + absoluteBin + ":") + "*"
            assignment = "export PATH=" + ShellQuote.quote(absoluteBin) + ":\"$PATH\""
        }
        return [
            Self.beginMarker,
            "case \":$PATH:\" in \(pattern)) ;; *) \(assignment) ;; esac",
            Self.endMarker,
        ].joined(separator: "\n") + "\n"
    }

    /// The dedicated fish file. It belongs to the app: the first line is the marker.
    private var fishText: String {
        let bin = doubleQuotedBin
        return [
            Self.beginMarker,
            "# Managed by Claude Profiles. Removed when the last profile is deleted.",
            "if type -q fish_add_path",
            "    fish_add_path -g \"\(bin)\"",
            "else if not contains -- \"\(bin)\" $PATH",
            "    set -gx PATH \"\(bin)\" $PATH",
            "end",
            Self.endMarker,
        ].joined(separator: "\n") + "\n"
    }

    /// The line a user adds by hand, for a shell the app does not edit or for
    /// when the file is not ours to change.
    public func manualLine(for shell: ShellKind) -> String {
        let bin = doubleQuotedBin
        switch shell {
        case .zsh, .bash, .posix:
            if let relative = homeRelative {
                return "export PATH=\"$HOME/\(relative):$PATH\""
            }
            return "export PATH=" + ShellQuote.quote(absoluteBin) + ":\"$PATH\""
        case .fish:
            return "fish_add_path -g \"\(bin)\""
        case .nushell:
            if let relative = homeRelative {
                let parts = relative.split(separator: "/").map { "\"\($0)\"" }.joined(separator: " ")
                return "$env.PATH = ($env.PATH | prepend ($nu.home-path | path join \(parts)))"
            }
            return "$env.PATH = ($env.PATH | prepend '\(absoluteBin)')"
        case .csh:
            return "setenv PATH \"\(bin):$PATH\""
        case .other:
            return absoluteBin
        }
    }

    // MARK: - Status

    private struct TargetState {
        var managed: Bool
        var damaged: Bool
    }

    /// The state of the PATH setup of a shell. Never throws: a file that cannot
    /// be read counts as damaged, so the app refuses to touch it.
    public func status(for shell: ShellKind) -> ShellStatus {
        guard shell.isSupported else { return .unsupported }
        do {
            let files = targets(for: shell)
            var managed = 0
            for file in files {
                let current = try state(of: file)
                if current.damaged { return .damaged }
                if current.managed { managed += 1 }
            }
            if !files.isEmpty && managed == files.count { return .configured }
            if managed > 0 { return .partlyConfigured }
            for file in scanFiles(for: shell) {
                if let data = try Self.readFile(file), manualLineFound(in: [UInt8](data)) {
                    return .manual
                }
            }
            return .notConfigured
        } catch {
            return .damaged
        }
    }

    /// The status of the login shell.
    public func loginStatus() -> ShellStatus { status(for: loginKind) }

    private func state(of target: Target) throws -> TargetState {
        switch target {
        case .block(let url):
            guard let data = try Self.readFile(url) else {
                return TargetState(managed: false, damaged: false)
            }
            switch Self.blockState([UInt8](data)) {
            case .none: return TargetState(managed: false, damaged: false)
            case .intact: return TargetState(managed: true, damaged: false)
            case .damaged: return TargetState(managed: false, damaged: true)
            }
        case .fishFile(let url):
            guard SafeFileSystem.kind(of: url) != .missing else {
                return TargetState(managed: false, damaged: false)
            }
            // The fish file is ours only when its first line is the marker.
            guard let data = try Self.readFile(url),
                  case .intact(let range) = Self.blockState([UInt8](data)),
                  range.lowerBound == 0
            else {
                return TargetState(managed: false, damaged: true)
            }
            return TargetState(managed: true, damaged: false)
        }
    }

    /// `true` when a line outside our block adds the bin folder to PATH by hand.
    private func manualLineFound(in bytes: [UInt8]) -> Bool {
        var inside = false
        for line in Self.lines(bytes) {
            if line.text == Self.beginMarker { inside = true; continue }
            if line.text == Self.endMarker { inside = false; continue }
            if inside { continue }
            if isManualPathLine(line.text) { return true }
        }
        return false
    }

    private func isManualPathLine(_ text: String) -> Bool {
        guard !text.hasPrefix("#"), text.contains(".claude-profiles/bin") else { return false }
        return text.contains("PATH") || text.contains("path")
    }

    // MARK: - Install

    /// Adds the setup to every file of the shell that does not have it yet.
    ///
    /// Refused for a damaged shell or an unsupported one. A shell that has the
    /// setup by hand is left alone.
    public func install(for shell: ShellKind) throws -> InstallOutcome {
        guard shell.isSupported else { throw ShellPathError.unsupported }
        switch status(for: shell) {
        case .damaged:
            throw ShellPathError.damaged(firstDamaged(in: targets(for: shell)) ?? "")
        case .configured:
            return .alreadyConfigured(managed: true)
        case .manual:
            return .alreadyConfigured(managed: false)
        case .unsupported:
            throw ShellPathError.unsupported
        case .notConfigured, .partlyConfigured:
            break
        }

        var files: [URL] = []
        var backups: [URL] = []
        for target in targets(for: shell) {
            if try state(of: target).managed { continue }
            switch target {
            case .block(let url):
                let result = try installBlock(url)
                files.append(result.file)
                if let backup = result.backup { backups.append(backup) }
            case .fishFile(let url):
                try Self.createFolder(url.deletingLastPathComponent())
                try Self.writeAtomically(Data(fishText.utf8), to: url, mode: 0o644)
                files.append(url)
            }
        }
        return .added(files: files, backups: backups)
    }

    private func installBlock(_ url: URL) throws -> (file: URL, backup: URL?) {
        let target = Self.writeTarget(url)
        let original = try Self.readFile(url)
        try Self.createFolder(target.deletingLastPathComponent())

        // The one-time backup of the original content. A file that did not
        // exist is backed up as an empty file: that is how removal knows it
        // was created by the app.
        let backup = Self.backupURL(for: target)
        var madeBackup: URL?
        if SafeFileSystem.kind(of: backup) == .missing {
            do {
                try (original ?? Data()).write(to: backup, options: .withoutOverwriting)
            } catch {
                throw ShellPathError.ioFailed(backup.path)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            madeBackup = backup
        }

        var output = original ?? Data()
        if !output.isEmpty {
            // Ends the last line first. Then the block follows, after a blank line
            // when the file already ended with a newline.
            output.append(Self.lineFeed)
        }
        output.append(Data(posixBlock.utf8))
        try Self.writeAtomically(output, to: target, mode: Self.permissions(of: target))
        return (target, madeBackup)
    }

    // MARK: - Remove

    /// Removes the setup from every file of the shell that has it.
    ///
    /// A damaged file refuses the whole shell before anything changes. Returns
    /// the files that were changed or deleted.
    public func remove(for shell: ShellKind) throws -> [URL] {
        guard shell.isSupported else { throw ShellPathError.unsupported }
        return try removeTargets(targets(for: shell))
    }

    /// Removes the setup from every file the app may have edited, for every
    /// shell. Used when the last profile is deleted. Manual lines stay.
    public func removeEverything() throws -> [URL] {
        try removeTargets(candidateTargets())
    }

    /// The files that carry the setup now, across every shell.
    public func managedFiles() -> [URL] {
        candidateTargets().compactMap { target in
            guard let current = try? state(of: target), current.managed else { return nil }
            return target.url
        }
    }

    private func removeTargets(_ files: [Target]) throws -> [URL] {
        var states: [TargetState] = []
        for file in files {
            let current = try state(of: file)
            if current.damaged { throw ShellPathError.damaged(file.url.path) }
            states.append(current)
        }
        var changed: [URL] = []
        for (file, state) in zip(files, states) where state.managed {
            switch file {
            case .block(let url):
                if try removeBlock(url) { changed.append(Self.writeTarget(url)) }
            case .fishFile(let url):
                guard unlink(url.path) == 0 else { throw ShellPathError.ioFailed(url.path) }
                changed.append(url)
            }
        }
        return changed
    }

    /// Removes the block from one file. Returns `false` when there was none.
    private func removeBlock(_ url: URL) throws -> Bool {
        let target = Self.writeTarget(url)
        guard let original = try Self.readFile(url) else { return false }
        let bytes = [UInt8](original)
        guard case .intact(let range) = Self.blockState(bytes) else { return false }

        // Take the line feed that the block was put after, too: the file comes
        // back exactly as it was.
        var start = range.lowerBound
        if start > 0 && bytes[start - 1] == Self.lineFeed {
            start -= 1
        }
        var restored = bytes
        restored.removeSubrange(start..<range.upperBound)

        let backup = Self.backupURL(for: target)
        let backupData = try? Data(contentsOf: backup)
        // The file was created by the app: it is deleted, with its backup.
        if restored.isEmpty, SafeFileSystem.kind(of: url) != .link, let backupData, backupData.isEmpty {
            guard unlink(target.path) == 0 else { throw ShellPathError.ioFailed(target.path) }
            _ = unlink(backup.path)
            return true
        }
        try Self.writeAtomically(Data(restored), to: target, mode: Self.permissions(of: target))
        // The backup is gone when it matches the restored content: nothing is lost.
        if let backupData, backupData == Data(restored) {
            _ = unlink(backup.path)
        }
        return true
    }

    private func firstDamaged(in files: [Target]) -> String? {
        for file in files {
            if let current = try? state(of: file), current.damaged { return file.url.path }
        }
        return nil
    }

    // MARK: - Block engine (bytes, so every other byte is kept)

    private static let lineFeed: UInt8 = 0x0A

    private struct Line {
        let range: Range<Int>
        let text: String
    }

    private enum BlockState {
        case none
        case intact(Range<Int>)
        case damaged
    }

    /// The lines of a file, each with its byte range (including its line feed).
    private static func lines(_ bytes: [UInt8]) -> [Line] {
        var result: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == lineFeed {
            result.append(makeLine(bytes, start..<(index + 1)))
            start = index + 1
        }
        if start < bytes.count {
            result.append(makeLine(bytes, start..<bytes.count))
        }
        return result
    }

    private static func makeLine(_ bytes: [UInt8], _ range: Range<Int>) -> Line {
        let text = String(decoding: bytes[range], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Line(range: range, text: text)
    }

    /// Our block: one begin line and one end line, in that order. Anything else
    /// with our markers (a missing end, a duplicate, the wrong order) is damaged.
    private static func blockState(_ bytes: [UInt8]) -> BlockState {
        let all = lines(bytes)
        let begins = all.indices.filter { all[$0].text == beginMarker }
        let ends = all.indices.filter { all[$0].text == endMarker }
        if begins.isEmpty && ends.isEmpty { return .none }
        guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else { return .damaged }
        return .intact(all[begins[0]].range.lowerBound..<all[ends[0]].range.upperBound)
    }

    // MARK: - Files

    /// The file a path points to: a symbolic link is followed, so the link stays.
    static func writeTarget(_ url: URL) -> URL {
        SafeFileSystem.kind(of: url) == .link ? url.resolvingSymlinksInPath() : url
    }

    /// The content of the file, or `nil` when there is none.
    static func readFile(_ url: URL) throws -> Data? {
        let target = writeTarget(url)
        switch SafeFileSystem.kind(of: target) {
        case .missing:
            return nil
        case .file:
            guard let data = try? Data(contentsOf: target) else { throw ShellPathError.ioFailed(url.path) }
            return data
        default:
            throw ShellPathError.ioFailed(url.path)
        }
    }

    static func backupURL(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + backupSuffix)
    }

    /// The permission bits of a file, or the default of a new file.
    static func permissions(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        else { return 0o644 }
        return mode
    }

    static func createFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ShellPathError.ioFailed(url.path)
        }
    }

    /// Writes a file atomically: a temporary file in the same folder, then a
    /// rename over the target. A reader never sees half a file.
    static func writeAtomically(_ data: Data, to target: URL, mode: Int) throws {
        let folder = target.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(
            ".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ShellPathError.ioFailed(target.path)
        }
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ShellPathError.ioFailed(target.path)
        }
    }
}
