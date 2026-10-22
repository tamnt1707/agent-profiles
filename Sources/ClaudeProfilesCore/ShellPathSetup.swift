import Foundation

/// What went wrong while the shell files were changed.
public enum ShellPathError: Error, Equatable, Sendable {
    /// A file has a broken or duplicated Claude Profiles block, a block whose
    /// body was changed by hand, or a foreign file sits where the fish file
    /// belongs. Nothing in that shell is touched. Carries the file.
    case damaged(String)
    /// The shell is not one the app edits.
    case unsupported
    /// A file could not be read or written.
    case ioFailed(String)
    /// A symbolic link that leads nowhere or loops. Carries the link.
    case brokenLink(String)
    /// The file, or the folder it has to be written in, is not writable.
    case notWritable(String)
    /// A file changed twice while it was being edited. That file was not written.
    case changedWhileEditing
    /// `ZDOTDIR` is set in `~/.zshenv` in a form the app cannot read. Carries `~/.zshenv`.
    case zdotdirUnresolved(String)
    /// Some files were already changed by this install before `reason` stopped it.
    /// Carries the changed files, in the order they were written.
    indirect case partial(changed: [String], reason: ShellPathError)
    /// A managed block sits in a file bash no longer reads (for example `~/.profile`
    /// once `~/.bash_profile` exists). Nothing is added; Remove it first. Carries that file.
    case blockElsewhere(String)
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
    /// `ZDOTDIR` is set in `~/.zshenv` in a form the app cannot read. Nothing is
    /// edited; the user adds the line by hand.
    case unresolvedZdotdir
}

/// What an install did.
public enum InstallOutcome: Equatable, Sendable {
    /// The files that now carry the setup, and the backups made on the way.
    case added(files: [URL], backups: [URL])
    /// Nothing was changed: the setup is there already (managed or by hand).
    case alreadyConfigured(managed: Bool)
}

/// What a removal of every shell did. A file that could not be changed is
/// reported with its reason and left alone; the others are still removed.
public struct ShellRemovalReport: Equatable, Sendable {
    public struct Skipped: Equatable, Sendable {
        public let url: URL
        public let reason: ShellPathError
    }

    /// The files that were changed or deleted.
    public var changed: [URL] = []
    /// The files that were left alone, and why.
    public var skipped: [Skipped] = []

    public init() {}
}

/// Adds the `claude-<name>` folder to the PATH of the supported shells.
///
/// Every shell file gets ONE block between exact markers, or the fish shell gets
/// one dedicated file. The block is safe to run twice: it adds the folder to
/// PATH only when it is not there yet, so several files that are read by the
/// same shell never duplicate the entry.
///
/// Removal gives back the original bytes. Only our markers are ever recognised,
/// and a block is ours only when its body is exactly the text the app writes:
/// a line the user wrote is never edited or removed.
///
/// A file is deleted only when the app created it (listed in `path-setup.json`
/// in the app's data folder) and nothing but the block is left in it.
public struct ShellPathSetup: Sendable {
    public static let beginMarker = "# >>> Claude Profiles >>>"
    public static let endMarker = "# <<< Claude Profiles <<<"
    /// Appended to the name of an edited file: `.zshrc.claude-profiles.bak`.
    public static let backupSuffix = ".claude-profiles.bak"
    public static let fishFileName = "claude-profiles.fish"
    /// The list of the files the app created, kept in the app's data folder.
    public static let createdFileName = "path-setup.json"

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
    /// The app's data folder, where `path-setup.json` is kept.
    public let root: URL
    /// The login shell path, for example `/bin/zsh`.
    public let loginShell: String
    /// The process environment, read for `ZDOTDIR` and `XDG_CONFIG_HOME`.
    public let environment: [String: String]

    /// Test hook: called after a file was read and its new content staged, just
    /// before the file is checked again. Arguments: the file and the attempt (0 or 1).
    var stagingHook: (@Sendable (URL, Int) -> Void)? = nil
    /// Test hook: called before the record file (`path-setup.json`) is written. Throwing
    /// here makes the record write fail.
    var recordWriteHook: (@Sendable () throws -> Void)? = nil

    public init(
        home: URL,
        binDir: URL,
        root: URL? = nil,
        loginShell: String = ShellPathSetup.currentLoginShell(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.binDir = binDir
        self.root = root ?? binDir.deletingLastPathComponent()
        self.loginShell = loginShell
        self.environment = environment
    }

    public init(
        paths: Paths,
        loginShell: String = ShellPathSetup.currentLoginShell(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.init(home: paths.home, binDir: paths.binDir, root: paths.root, loginShell: loginShell, environment: environment)
    }

    /// The login shell of the user, from the account database (not the environment).
    public static func currentLoginShell() -> String {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return "" }
        return String(cString: shell)
    }

    /// The shell of the login shell path.
    public var loginKind: ShellKind { ShellKind.from(loginShell: loginShell) }

    // MARK: - Locations

    /// Where zsh reads its `.zshrc`: from `~/.zshenv` when it sets `ZDOTDIR`,
    /// else from the process environment (absolute values only), else home.
    private enum ZshDirectory {
        case folder(URL)
        /// `~/.zshenv` sets `ZDOTDIR` in a form that cannot be resolved. Carries `~/.zshenv`.
        case unresolved(URL)
    }

    private var zshDirectory: ZshDirectory {
        let zshenv = homeFile(".zshenv")
        if let data = try? Self.readFile(zshenv), let text = String(data: data, encoding: .utf8) {
            switch Self.zdotdirAssignment(in: text, home: home.path) {
            case .path(let path)?: return .folder(URL(fileURLWithPath: path, isDirectory: true))
            case .unresolvable?: return .unresolved(zshenv)
            case nil: break
            }
        }
        if let value = absoluteEnvironment("ZDOTDIR") {
            return .folder(URL(fileURLWithPath: value, isDirectory: true))
        }
        return .folder(home)
    }

    private var configHome: URL {
        guard let value = absoluteEnvironment("XDG_CONFIG_HOME") else {
            return home.appendingPathComponent(".config", isDirectory: true)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    /// An environment value that is used only when it is an absolute path with
    /// no control characters. Anything else is ignored, never resolved against
    /// the current folder.
    private func absoluteEnvironment(_ key: String) -> String? {
        guard let value = environment[key], value.hasPrefix("/"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
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
            guard case .folder(let dir) = zshDirectory else { return [] }
            return [.block(dir.appendingPathComponent(".zshrc"))]
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
        var all: [Target] = []
        if case .folder(let dir) = zshDirectory {
            all.append(.block(dir.appendingPathComponent(".zshrc")))
        }
        // The folders an earlier install wrote to, so their block is found even when
        // `ZDOTDIR` can no longer be read.
        for folder in recordedZshFolders() {
            all.append(.block(folder.appendingPathComponent(".zshrc")))
        }
        all.append(.block(homeFile(".zshrc")))
        for target in bashCandidates() { all.append(target) }
        all.append(.fishFile(fishFile))
        var seen = Set<String>()
        return all.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// Every bash file that may hold our block: the three login files and `.bashrc`.
    /// Bash reads only one of the login files, but a block left in another one (after
    /// the login file changed) is still ours to find and remove.
    private func bashCandidates() -> [Target] {
        [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { .block(homeFile($0)) }
    }

    /// The files that may hold a line the user wrote by hand for this shell.
    /// The same files install writes to, so a line there is seen by the status.
    private func scanFiles(for shell: ShellKind) -> [URL] {
        switch shell {
        case .zsh:
            guard case .folder(let dir) = zshDirectory else { return [] }
            return [
                dir.appendingPathComponent(".zshrc"),
                dir.appendingPathComponent(".zprofile"),
                dir.appendingPathComponent(".zshenv"),
                // ~/.zshenv is scanned too: it is where ZDOTDIR is usually set, so a
                // line there is seen by the status. Which startup files zsh reads
                // depends on ZDOTDIR; this does not claim more than that.
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
              relative.range(of: "\\A[A-Za-z0-9._/-]+\\z", options: .regularExpression) != nil
        else { return nil }
        return relative
    }

    private var absoluteBin: String { binDir.standardizedFileURL.path }

    /// The folder for a double quoted shell word: `$HOME/…` or the absolute path.
    private var doubleQuotedBin: String {
        if let relative = homeRelative { return "$HOME/" + relative }
        return absoluteBin
    }

    /// The body of the managed block for the POSIX shells (zsh, bash, sh): one
    /// `case` line. The check makes it a no-op when the folder is already on
    /// PATH. `legacy` is the body the earlier version wrote: still recognised,
    /// never written again.
    private func posixBody(legacy: Bool) -> String {
        let pattern: String
        let assignment: String
        if let relative = homeRelative {
            pattern = "*\":$HOME/\(relative):\"*"
            assignment = legacy
                ? "export PATH=\"$HOME/\(relative):$PATH\""
                : "export PATH=\"$HOME/\(relative)${PATH:+:$PATH}\""
        } else {
            pattern = "*" + ShellQuote.quote(":" + absoluteBin + ":") + "*"
            assignment = legacy
                ? "export PATH=" + ShellQuote.quote(absoluteBin) + ":\"$PATH\""
                : "export PATH=" + ShellQuote.quote(absoluteBin) + "\"${PATH:+:$PATH}\""
        }
        // `${PATH-}` keeps `set -u` quiet; an empty PATH gives no empty entry.
        let current = legacy ? "$PATH" : "${PATH-}"
        return "case \":\(current):\" in \(pattern)) ;; *) \(assignment) ;; esac\n"
    }

    /// The text of the managed block for the POSIX shells.
    private var posixBlock: String {
        Self.beginMarker + "\n" + posixBody(legacy: false) + Self.endMarker + "\n"
    }

    /// The dedicated fish file. It belongs to the app: the whole file is the block.
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

    private var fishBytes: Data { Data(fishText.utf8) }

    /// The line a user adds by hand, for a shell the app does not edit or for
    /// when the file is not ours to change.
    public func manualLine(for shell: ShellKind) -> String {
        let bin = doubleQuotedBin
        switch shell {
        case .zsh, .bash, .posix:
            if let relative = homeRelative {
                return "export PATH=\"$HOME/\(relative)${PATH:+:$PATH}\""
            }
            return "export PATH=" + ShellQuote.quote(absoluteBin) + "\"${PATH:+:$PATH}\""
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

    /// The `ZDOTDIR` the zsh startup line of `~/.zshenv` sets.
    enum ZdotdirValue: Equatable {
        case path(String)
        case unresolvable
    }

    /// The `ZDOTDIR` that a `~/.zshenv` text sets, resolved. `nil` when the text
    /// does not mention `ZDOTDIR` at all.
    ///
    /// Conservative: exactly one plain assignment at the top level is read
    /// (`ZDOTDIR=…` or `export ZDOTDIR=…`, with a literal absolute path or a value
    /// that starts with `$HOME`, `${HOME}` or `~`). Anything else that mentions
    /// `ZDOTDIR` makes it `.unresolvable`: an assignment inside an `if`, `case`,
    /// `for`, `while`, function or brace block, inside a here-doc, a second
    /// assignment, `unset ZDOTDIR`, a conditional such as `[ -z "$ZDOTDIR" ] && …`,
    /// or any other form. Comment lines are ignored.
    static func zdotdirAssignment(in text: String, home: String) -> ZdotdirValue? {
        var values: [String] = []
        var depth = 0
        var heredoc: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if let delimiter = heredoc {
                // The body of a here-doc is text, never a statement.
                if line.contains("ZDOTDIR") { return .unresolvable }
                if trimmed == delimiter { heredoc = nil }
                continue
            }
            if trimmed.hasPrefix("#") { continue }
            if line.contains("ZDOTDIR") {
                guard depth == 0, let value = plainZdotdirValue(trimmed) else { return .unresolvable }
                values.append(value)
            }
            for segment in trimmed.split(whereSeparator: { ";&|".contains($0) }) {
                guard let first = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
                if zdotdirOpeners.contains(String(first)) || segment.contains("()") {
                    depth += 1
                } else if zdotdirClosers.contains(String(first)) {
                    depth -= 1
                    if depth < 0 { return .unresolvable }
                }
            }
            if let open = line.range(of: "<<"), !line[open.upperBound...].hasPrefix("<") {
                let word = line[open.upperBound...]
                    .drop(while: { $0 == "-" || $0 == " " || $0 == "\t" })
                    .prefix(while: { !" \t;&|)".contains($0) })
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                guard !word.isEmpty else { return .unresolvable }
                heredoc = word
            }
        }
        if values.count > 1 { return .unresolvable }
        guard let value = values.first else { return nil }
        return resolveZdotdir(value, home: home)
    }

    private static let zdotdirOpeners: Set<String> = ["if", "case", "for", "while", "until", "select", "function", "{"]
    private static let zdotdirClosers: Set<String> = ["fi", "esac", "done", "}"]

    /// The value of a plain top-level `ZDOTDIR=value` or `export ZDOTDIR=value` line,
    /// or `nil` when the line is any other form.
    private static func plainZdotdirValue(_ trimmed: String) -> String? {
        var rest = Substring(trimmed)
        if rest.hasPrefix("export") {
            let after = rest.dropFirst("export".count)
            guard after.first == " " || after.first == "\t" else { return nil }
            rest = after.drop(while: { $0 == " " || $0 == "\t" })
        }
        guard rest.hasPrefix("ZDOTDIR=") else { return nil }
        let value = rest.dropFirst("ZDOTDIR=".count).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !value.isEmpty, !value.contains(where: { ";&|()<>`".contains($0) }) else { return nil }
        return value
    }

    /// Resolves the value of a `ZDOTDIR` assignment, or says it cannot be done.
    static func resolveZdotdir(_ raw: String, home: String) -> ZdotdirValue {
        guard !raw.isEmpty else { return .unresolvable }
        // Single quotes: nothing is expanded.
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return checkedPath(String(raw.dropFirst().dropLast()), spaces: true)
        }
        var body = raw
        var quoted = false
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            body = String(raw.dropFirst().dropLast())
            quoted = true
        }
        for form in ["$HOME", "${HOME}"] {
            if body == form { return checkedPath(home, spaces: true) }
            if body.hasPrefix(form + "/") {
                return checkedPath(home + String(body.dropFirst(form.count)), spaces: quoted)
            }
        }
        // A tilde expands only when it is not quoted.
        if !quoted {
            if body == "~" { return checkedPath(home, spaces: true) }
            if body.hasPrefix("~/") { return checkedPath(home + String(body.dropFirst(1)), spaces: false) }
        }
        return checkedPath(body, spaces: quoted)
    }

    private static let unsafePathScalars = Set("$`\\\"';&|()<>*?[]{}!#".unicodeScalars)

    /// The path when it is absolute and has nothing a shell would expand or split.
    private static func checkedPath(_ path: String, spaces: Bool) -> ZdotdirValue {
        guard path.hasPrefix("/") else { return .unresolvable }
        for scalar in path.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return .unresolvable }
            if scalar == " " {
                if !spaces { return .unresolvable }
            } else if unsafePathScalars.contains(scalar) {
                return .unresolvable
            }
        }
        return .path(path)
    }

    // MARK: - Status

    /// The state of the shell as a whole, before the status is mapped.
    private enum Overall {
        case configured, partlyConfigured, manual, notConfigured, unresolvedZdotdir
    }

    /// The state of a shell. A broken or foreign file throws the error that
    /// names it, so install and remove can say which file it is.
    private func evaluate(_ shell: ShellKind) throws -> Overall {
        if shell == .zsh, case .unresolved = zshDirectory { return .unresolvedZdotdir }
        let files = targets(for: shell)
        var managed = 0
        for file in files {
            if try state(of: file) { managed += 1 }
        }
        // Every file bash reads has the block: PATH works, whatever else holds one.
        if !files.isEmpty && managed == files.count { return .configured }
        // Otherwise a block in a file bash no longer reads is the honest state: say so,
        // and never add a second block next to it.
        if try !strayBlocks(for: shell).isEmpty { return .partlyConfigured }
        if managed > 0 { return .partlyConfigured }
        for file in scanFiles(for: shell) {
            if let data = try? Self.readFile(file), manualLineFound(in: [UInt8](data)) {
                return .manual
            }
        }
        return .notConfigured
    }

    /// The state of the PATH setup of a shell. Never throws: a file that is
    /// damaged or cannot be read counts as damaged, so the app refuses to touch it.
    public func status(for shell: ShellKind) -> ShellStatus {
        guard shell.isSupported else { return .unsupported }
        do {
            switch try evaluate(shell) {
            case .configured: return .configured
            case .partlyConfigured: return .partlyConfigured
            case .manual: return .manual
            case .notConfigured: return .notConfigured
            case .unresolvedZdotdir: return .unresolvedZdotdir
            }
        } catch {
            return .damaged
        }
    }

    /// The status of the login shell.
    public func loginStatus() -> ShellStatus { status(for: loginKind) }

    /// The file that makes the shell damaged, for the message that names it. `nil`
    /// when no file of the shell is damaged.
    public func damagedFile(for shell: ShellKind) -> URL? {
        guard shell.isSupported else { return nil }
        do {
            _ = try evaluate(shell)
            return nil
        } catch ShellPathError.damaged(let path) {
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    /// The managed blocks of a shell that sit in a file the shell does not read.
    /// Only bash has such files (for example `~/.profile` once `~/.bash_profile` exists).
    public func strayFiles(for shell: ShellKind) -> [URL] {
        (try? strayBlocks(for: shell)) ?? []
    }

    /// Like `strayFiles`, but throws when a file of the shell is damaged.
    private func strayBlocks(for shell: ShellKind) throws -> [URL] {
        guard shell == .bash else { return [] }
        let read = Set(targets(for: .bash).map { $0.url.standardizedFileURL.path })
        var strays: [URL] = []
        for target in bashCandidates() where !read.contains(target.url.standardizedFileURL.path) {
            if try state(of: target) { strays.append(target.url) }
        }
        return strays
    }

    /// `true` when the file holds our block (or, for fish, our file). Throws
    /// when the block is damaged.
    private func state(of target: Target) throws -> Bool {
        switch target {
        case .block(let url):
            guard let data = try Self.readFile(url) else { return false }
            switch blockState([UInt8](data)) {
            case .none: return false
            case .intact: return true
            case .damaged: throw ShellPathError.damaged(url.path)
            }
        case .fishFile(let url):
            guard let data = try Self.readFile(url), !data.isEmpty else { return false }
            guard data == fishBytes else { throw ShellPathError.damaged(url.path) }
            return true
        }
    }

    /// `true` when a line outside our block adds the bin folder to PATH by hand.
    private func manualLineFound(in bytes: [UInt8]) -> Bool {
        var inside = false
        for line in Self.lines(bytes) {
            if line.content == Self.beginMarker { inside = true; continue }
            if line.content == Self.endMarker { inside = false; continue }
            if inside { continue }
            if isManualPathLine(line.content) { return true }
        }
        return false
    }

    private func isManualPathLine(_ text: String) -> Bool {
        let withoutIndent = text.drop(while: { $0 == " " || $0 == "\t" })
        guard !withoutIndent.hasPrefix("#"), text.contains(".claude-profiles/bin") else { return false }
        return text.contains("PATH") || text.contains("path")
    }

    // MARK: - Install

    /// Adds the setup to every file of the shell that does not have it yet.
    ///
    /// Refused for a damaged shell or an unsupported one. A shell that has the
    /// setup by hand is left alone. Every file is checked for writing before
    /// the first one is changed.
    public func install(for shell: ShellKind) throws -> InstallOutcome {
        guard shell.isSupported else { throw ShellPathError.unsupported }
        switch try evaluate(shell) {
        case .configured:
            return .alreadyConfigured(managed: true)
        case .manual:
            return .alreadyConfigured(managed: false)
        case .unresolvedZdotdir:
            throw ShellPathError.zdotdirUnresolved(homeFile(".zshenv").path)
        case .notConfigured, .partlyConfigured:
            break
        }
        // Never a second block: the existing one is removed first.
        if let stray = try strayBlocks(for: shell).first {
            throw ShellPathError.blockElsewhere(stray.path)
        }

        var pending: [Target] = []
        for target in targets(for: shell) {
            if try !state(of: target) { pending.append(target) }
        }
        for target in pending {
            try Self.requireWritable(try Self.writeTarget(target.url))
        }
        // The folder is recorded before any file in it is written (best effort removal later).
        if shell == .zsh, !pending.isEmpty, case .folder(let dir) = zshDirectory {
            try addZshFolder(dir.path)
        }

        var files: [URL] = []
        var backups: [URL] = []
        for target in pending {
            let result: (file: URL, backup: URL?)?
            do {
                switch target {
                case .block(let url): result = try installBlock(url)
                case .fishFile(let url): result = try installFish(url)
                }
            } catch let error as ShellPathError where !files.isEmpty {
                // The files already written keep the setup: report them, so the user can undo.
                throw ShellPathError.partial(changed: files.map(\.path), reason: error)
            }
            if let result {
                files.append(result.file)
                if let backup = result.backup { backups.append(backup) }
            }
        }
        if files.isEmpty { return .alreadyConfigured(managed: true) }
        return .added(files: files, backups: backups)
    }

    /// Puts the block at the end of a file. A file that did not exist is
    /// recorded as created; a file that existed gets a real backup first.
    private func installBlock(_ url: URL) throws -> (file: URL, backup: URL?)? {
        var recorded: String?
        do {
            let change = try edit(url, make: { current in
                if let current {
                    switch blockState([UInt8](current)) {
                    case .intact: return .keep
                    case .damaged: throw ShellPathError.damaged(url.path)
                    case .none: break
                    }
                }
                // The block always has LF line ends, whatever the file uses: a CRLF block cannot
                // run in a shell. A line feed ends the last line (after a bare CR too, so the
                // separator is always exactly one LF); the block then follows after a blank line.
                var output = current ?? Data()
                if !output.isEmpty { output.append(Self.lineFeed) }
                output.append(Data(self.posixBlock.utf8))
                return .write(output)
            }, beforeCommit: { current, target in
                guard let current else {
                    // Recorded before the new file appears; dropped again if the rename fails.
                    try self.setCreated(target.path, true)
                    recorded = target.path
                    return nil
                }
                return try Self.writeBackup(current, for: target)
            })
            guard case .written(let target, let backup) = change else { return nil }
            return (target, backup)
        } catch {
            if let recorded { try? setCreated(recorded, false) }
            throw error
        }
    }

    /// Writes the dedicated fish file. An empty file that exists is taken over
    /// (and backed up); a file with other content is refused.
    private func installFish(_ url: URL) throws -> (file: URL, backup: URL?)? {
        var recorded: String?
        do {
            let change = try edit(url, make: { current in
                switch current {
                case nil:
                    return .write(self.fishBytes)
                case let data? where data.isEmpty:
                    return .write(self.fishBytes)
                case let data? where data == self.fishBytes:
                    return .keep
                default:
                    throw ShellPathError.damaged(url.path)
                }
            }, beforeCommit: { current, target in
                guard let current else {
                    try self.setCreated(target.path, true)
                    recorded = target.path
                    return nil
                }
                return try Self.writeBackup(current, for: target)
            })
            guard case .written(let target, let backup) = change else { return nil }
            return (target, backup)
        } catch {
            if let recorded { try? setCreated(recorded, false) }
            throw error
        }
    }

    // MARK: - Remove

    /// Removes the setup from every file of the shell that has it.
    ///
    /// A damaged file refuses the whole shell before anything changes. Returns
    /// the files that were changed or deleted.
    public func remove(for shell: ShellKind) throws -> [URL] {
        guard shell.isSupported else { throw ShellPathError.unsupported }
        if shell == .zsh, case .unresolved = zshDirectory {
            throw ShellPathError.zdotdirUnresolved(homeFile(".zshenv").path)
        }
        // Bash removes its block from every file it may have written, not only the one it reads now.
        let candidates = shell == .bash ? bashCandidates() : targets(for: shell)
        var managed: [Target] = []
        for target in candidates {
            if try state(of: target) { managed.append(target) }
        }
        for target in managed {
            try Self.requireWritable(try Self.writeTarget(target.url))
        }
        var changed: [URL] = []
        var recordFailed = false
        for target in managed {
            guard let url = try removeOne(target) else { continue }
            changed.append(url)
            // A record that cannot be written does not stop the other files; it is reported at the end.
            do { try setCreated(url.path, false) } catch { recordFailed = true }
        }
        if recordFailed { throw ShellPathError.ioFailed(stateFile.path) }
        return changed
    }

    /// Removes the setup from every file the app may have edited, for every
    /// shell. Used when the last profile is deleted. Manual lines stay. Best
    /// effort per file: a file that cannot be changed is reported with its reason
    /// and left alone, but only when it carries our block or is in the record. A
    /// file that never had the block is not mentioned.
    public func removeEverything() -> ShellRemovalReport {
        var report = ShellRemovalReport()
        var recordFailed = false
        for target in candidateTargets() {
            do {
                guard try state(of: target), let url = try removeOne(target) else { continue }
                report.changed.append(url)
                do { try setCreated(url.path, false) } catch { recordFailed = true }
            } catch {
                guard mayHaveOurBlock(target) else { continue }
                let reason = (error as? ShellPathError) ?? .ioFailed(target.url.path)
                report.skipped.append(.init(url: target.url, reason: reason))
            }
        }
        if recordFailed {
            report.skipped.append(.init(url: stateFile, reason: .ioFailed(stateFile.path)))
        }
        return report
    }

    /// `true` when the file is in the record of created files or holds one of our markers.
    /// A file that cannot be read and is not in the record is treated as not ours.
    private func mayHaveOurBlock(_ target: Target) -> Bool {
        let path = (try? Self.writeTarget(target.url))?.path ?? target.url.path
        if createdFiles().contains(path) { return true }
        guard let data = (try? Self.readFile(target.url)) ?? nil else { return false }
        return data.range(of: Data(Self.beginMarker.utf8)) != nil
            || data.range(of: Data(Self.endMarker.utf8)) != nil
    }

    /// The files that carry the setup now, across every shell.
    public func managedFiles() -> [URL] {
        candidateTargets().compactMap { target in
            guard let managed = try? state(of: target), managed else { return nil }
            return target.url
        }
    }

    private func removeOne(_ target: Target) throws -> URL? {
        switch target {
        case .block(let url): return try removeBlock(url)
        case .fishFile(let url): return try removeFish(url)
        }
    }

    /// Takes the block out of one file. Returns the file when it was changed.
    private func removeBlock(_ url: URL) throws -> URL? {
        let created = try createdFiles().contains(Self.writeTarget(url).path)
        var restored: Data?
        let change = try edit(url, make: { current in
            guard let current else { return .keep }
            let bytes = [UInt8](current)
            let range: Range<Int>
            switch blockState(bytes) {
            case .none: return .keep
            case .damaged: throw ShellPathError.damaged(url.path)
            case .intact(let found): range = found
            }
            var start = range.lowerBound
            // The line feed that install put before the block goes too, but only when the
            // block ends the file. Content after it keeps the line break. A block that was
            // edited on Windows (CRLF lines) takes its CR as a pair with that line feed.
            if range.upperBound == bytes.count, start > 0, bytes[start - 1] == Self.lineFeed {
                start -= 1
                if Self.hasCRLFLines(bytes, from: range.lowerBound), start > 0, bytes[start - 1] == Self.carriageReturn {
                    start -= 1
                }
            }
            var rest = bytes
            rest.removeSubrange(start..<range.upperBound)
            restored = Data(rest)
            if rest.isEmpty, created, SafeFileSystem.kind(of: url) == .file { return .delete }
            return .write(Data(rest))
        })
        return finishRemoval(change, restored: restored)
    }

    /// Removes the fish file when it is ours and was created by the app.
    private func removeFish(_ url: URL) throws -> URL? {
        let created = try createdFiles().contains(Self.writeTarget(url).path)
        var restored: Data?
        let change = try edit(url, make: { current in
            guard let current, !current.isEmpty else { return .keep }
            guard current == self.fishBytes else { throw ShellPathError.damaged(url.path) }
            restored = Data()
            if created, SafeFileSystem.kind(of: url) == .file { return .delete }
            return .write(Data())
        })
        return finishRemoval(change, restored: restored)
    }

    /// Drops the backup when it matches what is left. The record is updated by the caller,
    /// after the file change, so a record error never hides the change.
    private func finishRemoval(_ change: Change, restored: Data?) -> URL? {
        switch change {
        case .unchanged:
            return nil
        case .written(let target, _):
            let backup = Self.backupURL(for: target)
            if let restored, let kept = try? Data(contentsOf: backup), kept == restored {
                _ = unlink(backup.path)
            }
            return target
        case .deleted(let target):
            let backup = Self.backupURL(for: target)
            if let kept = try? Data(contentsOf: backup), kept.isEmpty {
                _ = unlink(backup.path)
            }
            return target
        }
    }

    // MARK: - Editing one file

    /// What an edit does to one file, decided from the content read.
    private enum Edit {
        case keep
        case write(Data)
        case delete
    }

    /// What an edit did.
    private enum Change {
        case unchanged
        /// The file was replaced; `backup` is the backup made in the same step.
        case written(URL, backup: URL?)
        case deleted(URL)
    }

    /// Edits one file: `make` decides from the content read, and the new content
    /// is written only when the file did not change meanwhile. A file that
    /// changed is read and decided again once; a second change throws.
    private func edit(
        _ url: URL,
        make: (Data?) throws -> Edit,
        beforeCommit: (Data?, URL) throws -> URL? = { _, _ in nil }
    ) throws -> Change {
        for attempt in 0..<2 {
            let target = try Self.writeTarget(url)
            try Self.requireWritable(target)
            let before = Self.snapshot(of: target)
            let current = try Self.readFile(target)

            switch try make(current) {
            case .keep:
                return .unchanged
            case .delete:
                stagingHook?(target, attempt)
                guard Self.snapshot(of: target) == before else { continue }
                guard unlink(target.path) == 0 else { throw ShellPathError.ioFailed(target.path) }
                return .deleted(target)
            case .write(let data):
                try Self.createFolder(target.deletingLastPathComponent())
                let temporary = try Self.stage(data, beside: target, mode: Self.permissions(of: target))
                stagingHook?(target, attempt)
                guard Self.snapshot(of: target) == before else {
                    try? FileManager.default.removeItem(at: temporary)
                    continue
                }
                let backup: URL?
                do {
                    backup = try beforeCommit(current, target)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
                guard rename(temporary.path, target.path) == 0 else {
                    try? FileManager.default.removeItem(at: temporary)
                    if let backup { _ = unlink(backup.path) }
                    throw ShellPathError.ioFailed(target.path)
                }
                return .written(target, backup: backup)
            }
        }
        throw ShellPathError.changedWhileEditing
    }

    // MARK: - Created files

    private var stateFile: URL { root.appendingPathComponent(Self.createdFileName) }

    private struct CreatedRecord: Codable {
        var created: [String]
        /// The folders whose `.zshrc` got the block. Missing in records written before.
        var zshFolders: [String]?
    }

    /// The record as it is on disk. A record that cannot be read counts as empty:
    /// then nothing is deleted.
    private func readRecord() -> CreatedRecord {
        guard let data = try? Data(contentsOf: stateFile),
              let record = try? JSONDecoder().decode(CreatedRecord.self, from: data)
        else { return CreatedRecord(created: []) }
        return record
    }

    /// The absolute paths of the files the app created.
    private func createdFiles() -> Set<String> {
        Set(readRecord().created.filter { $0.hasPrefix("/") })
    }

    /// The `ZDOTDIR` folders an install wrote a zsh block to.
    private func recordedZshFolders() -> [URL] {
        (readRecord().zshFolders ?? [])
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Adds or drops a created file of the record. Written only when it changes.
    private func setCreated(_ path: String, _ created: Bool) throws {
        try updateRecord { record in
            var paths = Set(record.created.filter { $0.hasPrefix("/") })
            guard paths.contains(path) != created else { return false }
            if created { paths.insert(path) } else { paths.remove(path) }
            record.created = paths.sorted()
            return true
        }
    }

    /// Remembers a `ZDOTDIR` folder that got a zsh block.
    private func addZshFolder(_ folder: String) throws {
        try updateRecord { record in
            var folders = Set(record.zshFolders ?? [])
            guard folders.insert(folder).inserted else { return false }
            record.zshFolders = folders.sorted()
            return true
        }
    }

    /// Applies a change to the record and writes it, only when the change says so.
    /// Any failure throws the error that names the record file.
    private func updateRecord(_ change: (inout CreatedRecord) -> Bool) throws {
        var record = readRecord()
        guard change(&record) else { return }
        do {
            try Self.createFolder(root)
            try recordWriteHook?()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try Self.writeAtomically(try encoder.encode(record), to: stateFile, mode: 0o644)
        } catch {
            throw ShellPathError.ioFailed(stateFile.path)
        }
    }

    // MARK: - Block engine (bytes, so every other byte is kept)

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private struct Line {
        let range: Range<Int>
        /// The text of the line without its line end (LF or CRLF). Nothing else is trimmed.
        let content: String
    }

    private enum BlockState {
        case none
        case intact(Range<Int>)
        case damaged
    }

    /// The lines of a file, each with its byte range (including its line end).
    private static func lines(_ bytes: [UInt8]) -> [Line] {
        var result: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == lineFeed {
            result.append(line(bytes, start..<(index + 1)))
            start = index + 1
        }
        if start < bytes.count {
            result.append(line(bytes, start..<bytes.count))
        }
        return result
    }

    private static func line(_ bytes: [UInt8], _ range: Range<Int>) -> Line {
        var end = range.upperBound
        if end > range.lowerBound, bytes[end - 1] == lineFeed { end -= 1 }
        if end > range.lowerBound, bytes[end - 1] == carriageReturn { end -= 1 }
        let content = String(decoding: bytes[range.lowerBound..<end], as: UTF8.self)
        return Line(range: range, content: content)
    }

    /// Our block: a begin marker line and an end marker line, in that order, with
    /// a body that is exactly the text the app writes (or wrote before). Anything
    /// else with our markers is damaged and is never edited.
    private func blockState(_ bytes: [UInt8]) -> BlockState {
        let all = Self.lines(bytes)
        let begins = all.indices.filter { all[$0].content == Self.beginMarker }
        let ends = all.indices.filter { all[$0].content == Self.endMarker }
        if begins.isEmpty && ends.isEmpty { return .none }
        guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else { return .damaged }
        let begin = all[begins[0]]
        let end = all[ends[0]]
        // A file edited on Windows has CRLF lines: the body is compared with LF line ends.
        let body = Self.lfOnly(Array(bytes[begin.range.upperBound..<end.range.lowerBound]))
        let current = Array(posixBody(legacy: false).utf8)
        let legacy = Array(posixBody(legacy: true).utf8)
        guard body == current || body == legacy else { return .damaged }
        return .intact(begin.range.lowerBound..<end.range.upperBound)
    }

    /// The bytes with every CRLF turned into LF.
    private static func lfOnly(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        for index in bytes.indices {
            if bytes[index] == carriageReturn, index + 1 < bytes.count, bytes[index + 1] == lineFeed { continue }
            result.append(bytes[index])
        }
        return result
    }

    /// `true` when the line that starts at `index` (the begin marker) ends with CRLF.
    private static func hasCRLFLines(_ bytes: [UInt8], from index: Int) -> Bool {
        guard let end = bytes[index...].firstIndex(of: lineFeed), end > index else { return false }
        return bytes[end - 1] == carriageReturn
    }

    // MARK: - Files

    /// The file a path points to: a symbolic link is followed, so the link stays.
    /// A link that leads nowhere, or loops, throws the error that names it.
    static func writeTarget(_ url: URL) throws -> URL {
        guard SafeFileSystem.kind(of: url) == .link else { return url }
        guard let resolved = realpath(url.path, nil) else {
            throw ShellPathError.brokenLink(url.path)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// The content of the file, or `nil` when there is none.
    static func readFile(_ url: URL) throws -> Data? {
        let target = try writeTarget(url)
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

    /// Writes the one-time backup of a file that existed: the content it had
    /// when the block was added. Never overwrites a backup that is there.
    private static func writeBackup(_ content: Data, for target: URL) throws -> URL? {
        let backup = backupURL(for: target)
        guard SafeFileSystem.kind(of: backup) == .missing else { return nil }
        do {
            try content.write(to: backup, options: .withoutOverwriting)
        } catch {
            throw ShellPathError.ioFailed(backup.path)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        return backup
    }

    /// The permission bits of a file, or the default of a new file.
    static func permissions(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        else { return 0o644 }
        return mode
    }

    /// Throws when the file cannot be replaced: a file that is not writable
    /// (a rename would still replace it, so the check is explicit), or a folder
    /// that cannot take a new file.
    static func requireWritable(_ target: URL) throws {
        if SafeFileSystem.kind(of: target) == .file, access(target.path, W_OK) != 0 {
            throw ShellPathError.notWritable(target.path)
        }
        var folder = target.deletingLastPathComponent()
        while SafeFileSystem.kind(of: folder) == .missing, folder.path != "/" {
            folder = folder.deletingLastPathComponent()
        }
        if access(folder.path, W_OK) != 0 {
            throw ShellPathError.notWritable(folder.path)
        }
    }

    /// What `lstat` says about a file, to see whether someone changed it.
    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
    }

    private static func snapshot(of url: URL) -> Snapshot? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Snapshot(
            device: info.st_dev,
            inode: info.st_ino,
            mode: info.st_mode,
            size: info.st_size,
            seconds: Int(info.st_mtimespec.tv_sec),
            nanoseconds: Int(info.st_mtimespec.tv_nsec)
        )
    }

    static func createFolder(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw ShellPathError.ioFailed(url.path)
        }
    }

    /// Writes the data to a new temporary file next to the target and returns it.
    static func stage(_ data: Data, beside target: URL, mode: Int) throws -> URL {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ShellPathError.ioFailed(target.path)
        }
        return temporary
    }

    /// Writes a file atomically: a temporary file in the same folder, then a
    /// rename over the target. A reader never sees half a file.
    static func writeAtomically(_ data: Data, to target: URL, mode: Int) throws {
        let temporary = try stage(data, beside: target, mode: mode)
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ShellPathError.ioFailed(target.path)
        }
    }
}
