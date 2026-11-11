import Foundation

/// The two files of a Claude Code config folder that the app can edit.
///
/// Claude Code reads its user settings from `settings.json` in the config folder
/// (`CLAUDE_CONFIG_DIR`) and keeps the user-scope MCP servers under
/// `"mcpServers"` in `.claude.json`. Without `CLAUDE_CONFIG_DIR` the first file
/// is `~/.claude/settings.json` and the second one is `~/.claude.json`, in the
/// home folder and not in `~/.claude`.
public struct ClaudeConfigLocation: Equatable, Sendable {
    /// The config folder of an isolated profile. The default setup has none of its own.
    public let folder: URL?
    /// `settings.json`: permissions, model, env and the other user settings.
    public let settingsFile: URL
    /// `.claude.json`: the state Claude Code writes itself, with the MCP servers.
    public let stateFile: URL

    /// `true` when the files belong to an isolated profile of the app and may be
    /// written. The files of the user's own setup are only shown.
    public var isEditable: Bool { folder != nil }

    /// The files of a config folder of the app, which may be edited.
    public init(folder: URL) {
        self.folder = folder
        settingsFile = folder.appendingPathComponent(ClaudeConfigFileKind.settings.fileName)
        stateFile = folder.appendingPathComponent(ClaudeConfigFileKind.state.fileName)
    }

    private init(settingsFile: URL, stateFile: URL) {
        folder = nil
        self.settingsFile = settingsFile
        self.stateFile = stateFile
    }

    /// Where Claude Code reads the files of a profile.
    ///
    /// Only an isolated profile has a folder of its own under
    /// `~/.claude-profiles/homes`. The default setup and a profile that is not
    /// isolated use the user's own files, which this version only reads.
    public static func of(_ profile: Profile, paths: Paths) -> ClaudeConfigLocation {
        let home = paths.home(for: profile.slug)
        let homes = paths.homesDir.standardizedFileURL.path
        if !profile.isDefaultClaude, profile.isolate,
           home.standardizedFileURL.deletingLastPathComponent().path == homes {
            return ClaudeConfigLocation(folder: home)
        }
        return ClaudeConfigLocation(
            settingsFile: paths.defaultClaudeDir.appendingPathComponent(ClaudeConfigFileKind.settings.fileName),
            stateFile: paths.home.appendingPathComponent(ClaudeConfigFileKind.state.fileName)
        )
    }
}

/// Which of the two files is written. They follow different rules when they are missing.
public enum ClaudeConfigFileKind: Sendable {
    /// `settings.json`. Created when missing, readable by everyone (0644).
    case settings
    /// `.claude.json`. Claude Code owns it: when it is missing, the app writes
    /// only the MCP servers into a new file that only the user can read (0600).
    case state

    public var fileName: String {
        switch self {
        case .settings: return "settings.json"
        case .state: return ".claude.json"
        }
    }

    /// The permissions of a file the app creates.
    var newFileMode: mode_t {
        switch self {
        case .settings: return 0o644
        case .state: return 0o600
        }
    }
}

/// Everything that stops a config file from being read or written. The app maps
/// every case to a localized message.
public enum ClaudeConfigError: LocalizedError, Equatable {
    /// The file is not valid JSON.
    case notParsable(path: String, detail: String)
    /// The file is JSON, but not an object at the top.
    case notAnObject(path: String)
    /// A key the app edits has a value of another kind (for example `permissions.allow` is not a list of texts).
    case unexpectedShape(path: String, key: String)
    /// The file changed on disk after it was read.
    case changedOnDisk(path: String)
    /// The file, or its folder, is a symbolic link.
    case symlink(path: String)
    /// The file is not directly inside the config folder of the profile.
    case outsideFolder(path: String)
    /// Something other than a regular file is at the path.
    case notAFile(path: String)
    /// The files belong to the user's own setup, which this version does not edit.
    case notEditable(path: String)
    /// The file could not be read.
    case readFailed(path: String)
    /// The file could not be written.
    case writeFailed(path: String)
    /// An MCP server has no name.
    case emptyServerName
    /// Two MCP servers have the same name.
    case duplicateServerName(String)
    /// An MCP server lacks its command (stdio) or its URL (http, sse).
    case incompleteServer(String)

    public var errorDescription: String? {
        switch self {
        case .notParsable(let path, let detail): return "not valid JSON: \(path): \(detail)"
        case .notAnObject(let path): return "not a JSON object: \(path)"
        case .unexpectedShape(let path, let key): return "unexpected value for \(key) in \(path)"
        case .changedOnDisk(let path): return "changed on disk since it was read: \(path)"
        case .symlink(let path): return "refusing to write through a symbolic link: \(path)"
        case .outsideFolder(let path): return "refusing to write outside the profile folder: \(path)"
        case .notAFile(let path): return "not a regular file: \(path)"
        case .notEditable(let path): return "the user's own file is not edited: \(path)"
        case .readFailed(let path): return "could not read \(path)"
        case .writeFailed(let path): return "could not write \(path)"
        case .emptyServerName: return "an MCP server has no name"
        case .duplicateServerName(let name): return "two MCP servers are named \(name)"
        case .incompleteServer(let name): return "the MCP server \(name) lacks its command or URL"
        }
    }
}

/// A config file as it was read: the exact bytes, to notice a change on disk,
/// and the parsed object, which is edited in place.
public struct ClaudeConfigDocument {
    public let url: URL
    public let kind: ClaudeConfigFileKind
    /// The bytes read from disk, `nil` when the file did not exist.
    public let original: Data?
    /// The top-level object. Keys the app does not edit are kept as they are.
    public var root: [String: Any]

    public var exists: Bool { original != nil }
}

/// Reads and writes `settings.json` and `.claude.json` without losing anything.
///
/// A write replaces only the keys the app edits and keeps every other key and
/// value. It is refused when the file did not parse, when it changed on disk
/// since it was read, when it is a symbolic link or when it is not directly in
/// the config folder of the profile. The new content goes to a temporary file
/// in the same folder, which is renamed over the old one, so a reader never
/// sees half a file. The permissions of the old file are kept.
public enum ClaudeConfigFile {
    // MARK: - Reading

    /// Reads a file of an isolated profile, refusing a link or a path outside the folder.
    public static func read(_ kind: ClaudeConfigFileKind, in location: ClaudeConfigLocation) throws -> ClaudeConfigDocument {
        guard let folder = location.folder else {
            throw ClaudeConfigError.notEditable(path: url(of: kind, in: location).path)
        }
        let url = folder.appendingPathComponent(kind.fileName)
        try checkTarget(url, in: folder)
        return try document(url, kind: kind, data: readBytes(url, followLinks: false))
    }

    /// Reads a file of the user's own setup, only to show it. A link is followed:
    /// nothing is written back.
    public static func readForDisplay(_ kind: ClaudeConfigFileKind, in location: ClaudeConfigLocation) throws -> ClaudeConfigDocument {
        let url = url(of: kind, in: location)
        if location.folder != nil { return try read(kind, in: location) }
        return try document(url, kind: kind, data: readBytes(url, followLinks: true))
    }

    private static func url(of kind: ClaudeConfigFileKind, in location: ClaudeConfigLocation) -> URL {
        kind == .settings ? location.settingsFile : location.stateFile
    }

    private static func document(_ url: URL, kind: ClaudeConfigFileKind, data: Data?) throws -> ClaudeConfigDocument {
        guard let data else { return ClaudeConfigDocument(url: url, kind: kind, original: nil, root: [:]) }
        return ClaudeConfigDocument(url: url, kind: kind, original: data, root: try parse(data, path: url.path))
    }

    /// The top-level object of a JSON file.
    static func parse(_ data: Data, path: String) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw ClaudeConfigError.notParsable(path: path, detail: detail)
        }
        guard let object = value as? [String: Any] else { throw ClaudeConfigError.notAnObject(path: path) }
        return object
    }

    /// The bytes of a file, `nil` when nothing is there.
    ///
    /// Without `followLinks` the file is opened with `O_NOFOLLOW`, so a link put
    /// there after the check is not read through.
    static func readBytes(_ url: URL, followLinks: Bool) throws -> Data? {
        let flags = O_RDONLY | (followLinks ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
        if descriptor < 0 {
            switch errno {
            case ENOENT: return nil
            case ELOOP: throw ClaudeConfigError.symlink(path: url.path)
            default: throw ClaudeConfigError.readFailed(path: url.path)
            }
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ClaudeConfigError.readFailed(path: url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ClaudeConfigError.notAFile(path: url.path) }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw ClaudeConfigError.readFailed(path: url.path)
        }
    }

    // MARK: - Writing

    /// Writes the document back if its object changed, and returns the document
    /// as it is now on disk. Nothing is written when nothing changed.
    @discardableResult
    public static func write(_ document: ClaudeConfigDocument, in location: ClaudeConfigLocation) throws -> ClaudeConfigDocument {
        guard let folder = location.folder else { throw ClaudeConfigError.notEditable(path: document.url.path) }
        let url = document.url
        guard url.standardizedFileURL == folder.appendingPathComponent(document.kind.fileName).standardizedFileURL else {
            throw ClaudeConfigError.outsideFolder(path: url.path)
        }
        try checkTarget(url, in: folder)

        // Unchanged content is not written: the file keeps its date and Claude
        // Code sees no change.
        if let original = document.original,
           let before = try? parse(original, path: url.path),
           NSDictionary(dictionary: before).isEqual(to: document.root) {
            return document
        }
        if document.original == nil, document.root.isEmpty { return document }

        // `.claude.json` is Claude Code's own file: a new one holds the servers and nothing else.
        if document.kind == .state, document.original == nil, Set(document.root.keys) != ["mcpServers"] {
            throw ClaudeConfigError.notEditable(path: url.path)
        }

        var mode = document.kind.newFileMode
        if document.original != nil {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ClaudeConfigError.changedOnDisk(path: url.path) }
            mode = info.st_mode & 0o7777
        }
        try checkUnchanged(document)

        var data = ConfigJSON.data(document.root)
        data.append(0x0A)
        let temporary = folder.appendingPathComponent(
            ".\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        )
        try writeNewFile(data, to: temporary, mode: mode)

        // The last look before the rename: the window left is as small as it gets.
        do {
            try checkTarget(url, in: folder)
            try checkUnchanged(document)
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw ClaudeConfigError.writeFailed(path: url.path)
        }
        return ClaudeConfigDocument(url: url, kind: document.kind, original: data, root: document.root)
    }

    /// Refuses a path that is not directly inside the folder, a folder that is a
    /// link, and a file that is a link or not a regular file.
    static func checkTarget(_ url: URL, in folder: URL) throws {
        let folderPath = folder.standardizedFileURL.path
        let parentPath = url.standardizedFileURL.deletingLastPathComponent().path
        guard parentPath == folderPath else { throw ClaudeConfigError.outsideFolder(path: url.path) }
        switch SafeFileSystem.kind(of: folder) {
        case .directory: break
        case .link: throw ClaudeConfigError.symlink(path: folder.path)
        default: throw ClaudeConfigError.outsideFolder(path: url.path)
        }
        switch SafeFileSystem.kind(of: url) {
        case .missing, .file: return
        case .link: throw ClaudeConfigError.symlink(path: url.path)
        case .directory, .other: throw ClaudeConfigError.notAFile(path: url.path)
        }
    }

    /// Refuses the write when the bytes on disk are not the ones that were read.
    private static func checkUnchanged(_ document: ClaudeConfigDocument) throws {
        let current: Data?
        do {
            current = try readBytes(document.url, followLinks: false)
        } catch ClaudeConfigError.readFailed {
            throw ClaudeConfigError.changedOnDisk(path: document.url.path)
        }
        guard current == document.original else { throw ClaudeConfigError.changedOnDisk(path: document.url.path) }
    }

    /// Writes a file that must not exist yet, with the given permissions.
    private static func writeNewFile(_ data: Data, to url: URL, mode: mode_t) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw ClaudeConfigError.writeFailed(path: url.path) }
        var ok = fchmod(descriptor, mode) == 0
        if ok {
            ok = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
        }
        if ok { ok = fsync(descriptor) == 0 }
        close(descriptor)
        guard ok else {
            unlink(url.path)
            throw ClaudeConfigError.writeFailed(path: url.path)
        }
    }
}

/// Writes the objects of `JSONSerialization` back as JSON text.
///
/// `JSONSerialization` writes `0.1` as `0.10000000000000001`; this writer
/// prints the shortest text that reads back as the same number, so numbers
/// the app does not touch keep their text. Keys are sorted, two spaces indent
/// the levels, and slashes and non-ASCII letters are written as they are.
enum ConfigJSON {
    static func data(_ value: Any) -> Data {
        var text = ""
        write(value, indent: "", into: &text)
        return Data(text.utf8)
    }

    private static func write(_ value: Any, indent: String, into text: inout String) {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { text += "{}"; return }
            text += "{\n"
            for (index, key) in object.keys.sorted().enumerated() {
                text += inner
                writeString(key, into: &text)
                text += ": "
                write(object[key]!, indent: inner, into: &text)
                text += index == object.count - 1 ? "\n" : ",\n"
            }
            text += indent + "}"
        case let array as [Any]:
            guard !array.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (index, item) in array.enumerated() {
                text += inner
                write(item, indent: inner, into: &text)
                text += index == array.count - 1 ? "\n" : ",\n"
            }
            text += indent + "]"
        case let string as String:
            writeString(string, into: &text)
        case let number as NSNumber:
            text += numberText(number)
        case is NSNull:
            text += "null"
        default:
            text += "null"
        }
    }

    private static func numberText(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        if number is NSDecimalNumber { return number.description }
        switch String(cString: number.objCType) {
        case "d", "f":
            let double = number.doubleValue
            guard double.isFinite else { return "null" }
            return "\(double)"
        default:
            return number.description
        }
    }

    private static func writeString(_ string: String, into text: inout String) {
        text += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }
}
