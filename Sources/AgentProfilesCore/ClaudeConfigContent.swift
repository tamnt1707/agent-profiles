import Foundation

/// One name and value of an `env` or `headers` object, in the order the editor shows them.
public struct ConfigPair: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

/// A user-scope MCP server of `.claude.json`, as the editor shows it.
///
/// Claude Code knows `stdio` servers (`command`, `args`, `env`; an entry with no
/// `type` is one) and remote `http` and `sse` servers (`url`, `headers`). Any
/// other key of the entry (`oauth`, `timeout`, `headersHelper`, …) is kept as it
/// is when the server is saved. An entry the app cannot edit (another type, or
/// fields of an unexpected kind) is shown and can be removed, but not changed.
public struct McpServer: Equatable, Identifiable, Sendable {
    public enum Transport: String, CaseIterable, Sendable {
        case stdio
        case http
        case sse

        /// The transport a `type` value means. No `type` is a stdio server, and
        /// `streamable-http` is another name for `http`.
        init?(typeValue: Any?) {
            switch typeValue {
            case nil: self = .stdio
            case let text as String:
                switch text {
                case "stdio": self = .stdio
                case "http", "streamable-http": self = .http
                case "sse": self = .sse
                default: return nil
                }
            default: return nil
            }
        }
    }

    public let id: UUID
    public var name: String
    /// The name in the file when it was read, `nil` for a server added in the editor.
    public let originalName: String?
    public var transport: Transport
    public var command: String
    public var args: [String]
    public var env: [ConfigPair]
    public var url: String
    public var headers: [ConfigPair]
    /// Why the app cannot edit the entry (its `type`, or `?`), `nil` when it can.
    public let unsupportedType: String?

    public var isEditable: Bool { unsupportedType == nil }

    public init(
        id: UUID = UUID(),
        name: String,
        originalName: String? = nil,
        transport: Transport = .stdio,
        command: String = "",
        args: [String] = [],
        env: [ConfigPair] = [],
        url: String = "",
        headers: [ConfigPair] = [],
        unsupportedType: String? = nil
    ) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.unsupportedType = unsupportedType
    }
}

/// The MCP servers of `.claude.json`: reading them and putting them back.
public enum McpServers {
    /// The servers of the file, sorted by name. No `mcpServers` key is no server.
    public static func read(from document: ClaudeConfigDocument) throws -> [McpServer] {
        guard let value = document.root["mcpServers"] else { return [] }
        guard let servers = value as? [String: Any] else {
            throw ClaudeConfigError.unexpectedShape(path: document.url.path, key: "mcpServers")
        }
        return servers.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            server(named: name, entry: servers[name]!)
        }
    }

    private static func server(named name: String, entry: Any) -> McpServer {
        guard let entry = entry as? [String: Any] else {
            return McpServer(name: name, originalName: name, unsupportedType: "?")
        }
        guard let transport = McpServer.Transport(typeValue: entry["type"]) else {
            return McpServer(name: name, originalName: name, unsupportedType: (entry["type"] as? String) ?? "?")
        }
        let command = entry["command"].map { $0 as? String }
        let args = entry["args"].map { $0 as? [String] }
        let env = entry["env"].map { $0 as? [String: String] }
        let url = entry["url"].map { $0 as? String }
        let headers = entry["headers"].map { $0 as? [String: String] }
        // A field of another kind cannot be shown in the form without losing it.
        if command == .some(nil) || args == .some(nil) || env == .some(nil) || url == .some(nil) || headers == .some(nil) {
            return McpServer(name: name, originalName: name, unsupportedType: "?")
        }
        return McpServer(
            name: name,
            originalName: name,
            transport: transport,
            command: (command ?? nil) ?? "",
            args: (args ?? nil) ?? [],
            env: pairs((env ?? nil) ?? [:]),
            url: (url ?? nil) ?? "",
            headers: pairs((headers ?? nil) ?? [:])
        )
    }

    private static func pairs(_ object: [String: String]) -> [ConfigPair] {
        object.keys.sorted().map { ConfigPair(key: $0, value: object[$0]!) }
    }

    /// Checks the servers before anything is written: every name is set and
    /// used once, and every server has its command or its URL.
    public static func validate(_ servers: [McpServer]) throws {
        var seen = Set<String>()
        for server in servers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ClaudeConfigError.emptyServerName }
            guard seen.insert(name).inserted else { throw ClaudeConfigError.duplicateServerName(name) }
            guard server.isEditable else { continue }
            switch server.transport {
            case .stdio:
                if server.command.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ClaudeConfigError.incompleteServer(name)
                }
            case .http, .sse:
                if server.url.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw ClaudeConfigError.incompleteServer(name)
                }
            }
        }
    }

    /// Puts the servers into the document. A server of the file that is not in
    /// the list is removed; a server that is unchanged keeps its entry exactly;
    /// a changed server keeps the keys of its entry the editor does not know.
    public static func apply(_ servers: [McpServer], to document: inout ClaudeConfigDocument) throws {
        try validate(servers)
        let had = document.root["mcpServers"]
        if had != nil, !(had is [String: Any]) {
            throw ClaudeConfigError.unexpectedShape(path: document.url.path, key: "mcpServers")
        }
        let existing = had as? [String: Any] ?? [:]
        let before = (try? read(from: document)) ?? []

        var result: [String: Any] = [:]
        for server in servers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = server.originalName.flatMap { existing[$0] }
            if !server.isEditable {
                if let base { result[name] = base }
                continue
            }
            let old = server.originalName.flatMap { original in before.first { $0.originalName == original } }
            result[name] = entry(for: server, base: base as? [String: Any], old: old)
        }

        if had == nil, result.isEmpty { return }
        if NSDictionary(dictionary: existing).isEqual(to: result), had != nil { return }
        document.root["mcpServers"] = result
    }

    /// The entry of one server: the old entry with the fields the user changed.
    private static func entry(for server: McpServer, base: [String: Any]?, old: McpServer?) -> [String: Any] {
        var entry = base ?? [:]
        let oldTransport = old?.transport
        if base == nil {
            entry["type"] = server.transport.rawValue
        } else if oldTransport != server.transport {
            entry["type"] = server.transport.rawValue
            // The fields of the other transport mean nothing any more.
            for key in ["command", "args", "env", "url", "headers"] { entry.removeValue(forKey: key) }
        }
        let fresh = old == nil || oldTransport != server.transport
        switch server.transport {
        case .stdio:
            if fresh || old?.command != server.command { entry["command"] = server.command }
            if fresh || old?.args != server.args { setList(server.args, key: "args", in: &entry) }
            if fresh || !samePairs(old?.env ?? [], server.env) { setObject(server.env, key: "env", in: &entry) }
        case .http, .sse:
            if fresh || old?.url != server.url { entry["url"] = server.url.trimmingCharacters(in: .whitespaces) }
            if fresh || !samePairs(old?.headers ?? [], server.headers) { setObject(server.headers, key: "headers", in: &entry) }
        }
        return entry
    }

    private static func setList(_ list: [String], key: String, in entry: inout [String: Any]) {
        if list.isEmpty { entry.removeValue(forKey: key) } else { entry[key] = list }
    }

    private static func setObject(_ pairs: [ConfigPair], key: String, in entry: inout [String: Any]) {
        let object = dictionary(pairs)
        if object.isEmpty { entry.removeValue(forKey: key) } else { entry[key] = object }
    }

    /// The pairs as an object. A pair without a name is left out; of two pairs
    /// with the same name the last one wins.
    static func dictionary(_ pairs: [ConfigPair]) -> [String: String] {
        var object: [String: String] = [:]
        for pair in pairs {
            let key = pair.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            object[key] = pair.value
        }
        return object
    }

    private static func samePairs(_ a: [ConfigPair], _ b: [ConfigPair]) -> Bool {
        dictionary(a) == dictionary(b)
    }
}

/// The `allow`, `ask` and `deny` rule lists of `permissions` in `settings.json`.
public struct PermissionRules: Equatable, Sendable {
    public var allow: [String]
    public var ask: [String]
    public var deny: [String]

    public init(allow: [String] = [], ask: [String] = [], deny: [String] = []) {
        self.allow = allow
        self.ask = ask
        self.deny = deny
    }

    static let keys = ["allow", "ask", "deny"]

    private func list(_ key: String) -> [String] {
        switch key {
        case "allow": return allow
        case "ask": return ask
        default: return deny
        }
    }

    /// The rules of the file. A missing list is an empty one.
    public static func read(from document: ClaudeConfigDocument) throws -> PermissionRules {
        let permissions = try permissionsObject(document)
        var lists: [String: [String]] = [:]
        for key in keys {
            guard let value = permissions[key] else { continue }
            guard let rules = value as? [String] else {
                throw ClaudeConfigError.unexpectedShape(path: document.url.path, key: "permissions.\(key)")
            }
            lists[key] = rules
        }
        return PermissionRules(allow: lists["allow"] ?? [], ask: lists["ask"] ?? [], deny: lists["deny"] ?? [])
    }

    private static func permissionsObject(_ document: ClaudeConfigDocument) throws -> [String: Any] {
        guard let value = document.root["permissions"] else { return [:] }
        guard let object = value as? [String: Any] else {
            throw ClaudeConfigError.unexpectedShape(path: document.url.path, key: "permissions")
        }
        return object
    }

    /// Puts the rules into the document. Only a list that changed is written:
    /// the other keys of `permissions` (`defaultMode`, `additionalDirectories`, …)
    /// stay as they are. Blank rules are left out, and an emptied list is removed.
    public func apply(to document: inout ClaudeConfigDocument) throws {
        let current = try PermissionRules.read(from: document)
        var permissions = try PermissionRules.permissionsObject(document)
        var changed = false
        for key in PermissionRules.keys {
            let rules = list(key)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard rules != current.list(key) else { continue }
            changed = true
            if rules.isEmpty { permissions.removeValue(forKey: key) } else { permissions[key] = rules }
        }
        guard changed else { return }
        if document.root["permissions"] == nil, permissions.isEmpty { return }
        document.root["permissions"] = permissions
    }
}

/// Tells which `env` and `headers` values look like secrets, so the editor
/// shows them masked.
public enum SecretMask {
    private static let secretWords = [
        "token", "secret", "key", "password", "passwd", "auth", "bearer",
        "credential", "cookie", "session", "private", "signature",
    ]
    private static let secretPrefixes = ["bearer ", "basic ", "sk-", "ghp_", "gho_", "github_pat_", "xox", "glpat-", "AKIA"]

    /// `true` when the value should be masked: its name speaks of a secret, or
    /// the value starts like a known token. A value that only refers to an
    /// environment variable (`${API_KEY}`) is not a secret.
    public static func looksSecret(key: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if isVariableReference(trimmed) { return false }
        let name = key.lowercased()
        if secretWords.contains(where: { name.contains($0) }) { return true }
        let lower = trimmed.lowercased()
        return secretPrefixes.contains { lower.hasPrefix($0.lowercased()) }
    }

    /// The value with all but its last four characters hidden. A short value is hidden entirely.
    public static func masked(_ value: String) -> String {
        guard value.count >= 12 else { return String(repeating: "•", count: max(value.count, 4)) }
        return String(repeating: "•", count: 8) + value.suffix(4)
    }

    private static func isVariableReference(_ value: String) -> Bool {
        let pattern = #"^(Bearer\s+)?\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
