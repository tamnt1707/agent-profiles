import Foundation

/// How the provider credential is passed to Claude Code.
public enum AuthKind: String, Codable, CaseIterable, Sendable {
    /// `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer …`
    case bearer = "Bearer"
    /// `ANTHROPIC_API_KEY` → `x-api-key: …`
    case apiKey = "ApiKey"
    /// No credential at all (e.g. a local proxy).
    case none = "None"

    /// Environment variable the launcher script exports, if any.
    public var envVarName: String? {
        switch self {
        case .bearer: return "ANTHROPIC_AUTH_TOKEN"
        case .apiKey: return "ANTHROPIC_API_KEY"
        case .none: return nil
        }
    }
}

/// Terminal application used by "Open terminal with this profile".
public enum TerminalApp: String, Codable, CaseIterable, Sendable {
    case terminal = "Terminal"
    case iTerm = "ITerm"
}

/// UI language of the app. `system` follows `Locale.preferredLanguages`.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case en
    case vi
}

/// Appearance of the app window. `system` follows the macOS setting.
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

/// One provider profile. The property names are camelCase in Swift but the
/// on-disk keys are snake_case, exactly like the Rust implementation wrote them.
public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var baseURL: String
    public var auth: AuthKind
    public var model: String
    public var opusModel: String
    public var sonnetModel: String
    public var haikuModel: String
    /// Extra `KEY=VALUE` lines, one per line.
    public var extraEnv: String
    public var workdir: String
    /// Give this profile its own `CLAUDE_CONFIG_DIR` (recommended).
    public var isolate: Bool
    /// When isolated, symlink `CLAUDE.md` / `skills` / `commands` / `agents` from `~/.claude`.
    public var shareFromDefault: Bool
    /// Folders this profile was opened in from the menu bar, newest first, absolute.
    /// Optional on disk: an empty list is not written.
    public var recentDirs: [String]
    /// Estimated cost: USD per million input tokens. `nil` when not set.
    public var priceInputPerMillion: Double?
    /// Estimated cost: USD per million output tokens. `nil` when not set.
    public var priceOutputPerMillion: Double?
    /// The command line agent this profile runs. Written only when it is not Claude Code.
    public var agent: AgentKind

    public init(
        name: String = "",
        slug: String = "",
        baseURL: String = "",
        auth: AuthKind = .bearer,
        model: String = "",
        opusModel: String = "",
        sonnetModel: String = "",
        haikuModel: String = "",
        extraEnv: String = "",
        workdir: String = "",
        isolate: Bool = false,
        shareFromDefault: Bool = false,
        recentDirs: [String] = [],
        priceInputPerMillion: Double? = nil,
        priceOutputPerMillion: Double? = nil,
        agent: AgentKind = .default
    ) {
        self.name = name
        self.slug = slug
        self.baseURL = baseURL
        self.auth = auth
        self.model = model
        self.opusModel = opusModel
        self.sonnetModel = sonnetModel
        self.haikuModel = haikuModel
        self.extraEnv = extraEnv
        self.workdir = workdir
        self.isolate = isolate
        self.shareFromDefault = shareFromDefault
        self.recentDirs = recentDirs
        self.priceInputPerMillion = priceInputPerMillion
        self.priceOutputPerMillion = priceOutputPerMillion
        self.agent = agent
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case slug
        case baseURL = "base_url"
        case auth
        case model
        case opusModel = "opus_model"
        case sonnetModel = "sonnet_model"
        case haikuModel = "haiku_model"
        case extraEnv = "extra_env"
        case workdir
        case isolate
        case shareFromDefault = "share_from_default"
        case recentDirs = "recent_dirs"
        case priceInputPerMillion = "price_input_per_million"
        case priceOutputPerMillion = "price_output_per_million"
        case agent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field is optional on disk: a missing key falls back to the default
        // (same as `#[serde(default)]` in the Rust version).
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        // A malformed value is an error, never a silent default: the file is
        // saved again later, so a silent default would change the user's data.
        auth = try c.decodeIfPresent(AuthKind.self, forKey: .auth) ?? .bearer
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        opusModel = try c.decodeIfPresent(String.self, forKey: .opusModel) ?? ""
        sonnetModel = try c.decodeIfPresent(String.self, forKey: .sonnetModel) ?? ""
        haikuModel = try c.decodeIfPresent(String.self, forKey: .haikuModel) ?? ""
        extraEnv = try c.decodeIfPresent(String.self, forKey: .extraEnv) ?? ""
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir) ?? ""
        isolate = try c.decodeIfPresent(Bool.self, forKey: .isolate) ?? false
        shareFromDefault = try c.decodeIfPresent(Bool.self, forKey: .shareFromDefault) ?? false
        // Lenient: the list is a convenience, so a malformed value is dropped
        // instead of failing the whole profile list.
        //
        // The list is normalized while it is read: entries that are not
        // absolute, that hold a control character, or that are duplicates are
        // dropped, and the list is cut to the five newest folders. A hand
        // edited file can therefore not keep an endless list in memory, and a
        // list the app wrote stays byte identical when it is saved again.
        recentDirs = RecentFolders(
            (try? c.decodeIfPresent([String].self, forKey: .recentDirs)) ?? []
        ).paths
        // Optional: a file written before prices existed has no such keys. A
        // price that is broken is dropped instead of making the whole list of
        // profiles unreadable: the next save writes the file without it.
        priceInputPerMillion = Self.lenientPrice(c, forKey: .priceInputPerMillion)
        priceOutputPerMillion = Self.lenientPrice(c, forKey: .priceOutputPerMillion)
        // A file written before agents existed has no key: the profile runs Claude Code.
        agent = (try? c.decode(AgentKind.self, forKey: .agent)) ?? .default
    }

    /// The price of the file, or `nil` when it is not there or is broken.
    ///
    /// A price that is not a number, that is not finite or that is negative is
    /// dropped. The price of a profile is a convenience: it must not make the
    /// list of the profiles unreadable and it must not stop the saves.
    private static func lenientPrice(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        guard let value = try? container.decode(Double.self, forKey: key) else { return nil }
        return UsageCost.isValidPrice(value) ? value : nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(slug, forKey: .slug)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(auth, forKey: .auth)
        try c.encode(model, forKey: .model)
        try c.encode(opusModel, forKey: .opusModel)
        try c.encode(sonnetModel, forKey: .sonnetModel)
        try c.encode(haikuModel, forKey: .haikuModel)
        try c.encode(extraEnv, forKey: .extraEnv)
        try c.encode(workdir, forKey: .workdir)
        try c.encode(isolate, forKey: .isolate)
        try c.encode(shareFromDefault, forKey: .shareFromDefault)
        // Written only when there is something, so an old file stays as it was.
        if !recentDirs.isEmpty {
            try c.encode(recentDirs, forKey: .recentDirs)
        }
        // The price keys are written only when set, so a profile without them is
        // written exactly as the older app wrote it.
        try c.encodeIfPresent(priceInputPerMillion, forKey: .priceInputPerMillion)
        try c.encodeIfPresent(priceOutputPerMillion, forKey: .priceOutputPerMillion)
        // Written only when it is not the default, so a file stays as the older app wrote it.
        if agent != .default {
            try c.encode(agent, forKey: .agent)
        }
    }
}

/// The whole `profiles.json` file: the profile list plus the app settings.
public struct AppData: Codable, Equatable, Sendable {
    public var terminal: TerminalApp
    public var profiles: [Profile]
    /// Added by the Swift app; unknown to the Rust app, which ignores it.
    public var language: AppLanguage
    /// Added by the Swift app; unknown to the Rust app, which ignores it.
    public var appearance: AppearanceMode
    /// Look for a new version once a day, without asking. On by default.
    public var autoCheckUpdates: Bool
    /// When the last search for a new version was.
    public var lastUpdateCheck: Date?
    /// The user chose "Don't ask again" for the PATH setup of the shell.
    public var pathPromptDeclined: Bool
    /// Show the launcher in the menu bar. On by default; only written when off.
    public var showMenuBar: Bool
    /// Open a profile in the terminal inside the app. On by default; only written when off.
    public var embeddedTerminal: Bool
    /// Test the profiles that have no result when the app starts. On by default; only written when off.
    public var autoCheckConnections: Bool

    public init(
        terminal: TerminalApp = .terminal,
        profiles: [Profile] = [],
        language: AppLanguage = .system,
        appearance: AppearanceMode = .system,
        autoCheckUpdates: Bool = true,
        lastUpdateCheck: Date? = nil,
        pathPromptDeclined: Bool = false,
        showMenuBar: Bool = true,
        embeddedTerminal: Bool = true,
        autoCheckConnections: Bool = true
    ) {
        self.terminal = terminal
        self.profiles = profiles
        self.language = language
        self.appearance = appearance
        self.autoCheckUpdates = autoCheckUpdates
        self.lastUpdateCheck = lastUpdateCheck
        self.pathPromptDeclined = pathPromptDeclined
        self.showMenuBar = showMenuBar
        self.embeddedTerminal = embeddedTerminal
        self.autoCheckConnections = autoCheckConnections
    }

    private enum CodingKeys: String, CodingKey {
        case terminal
        case profiles
        case language
        case appearance
        case autoCheckUpdates = "auto_check_updates"
        case lastUpdateCheck = "last_update_check"
        case pathPromptDeclined = "path_prompt_declined"
        case showMenuBar = "show_menu_bar"
        case embeddedTerminal = "embedded_terminal"
        case autoCheckConnections = "auto_check_connections"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Strict: one malformed profile fails the whole file (it is backed up
        // and not overwritten) instead of silently dropping every profile.
        let profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        self.init(settings: c, profiles: profiles)
    }

    /// The settings, read leniently: a malformed setting falls back to its default.
    private init(settings c: KeyedDecodingContainer<CodingKeys>, profiles: [Profile]) {
        terminal = (try? c.decode(TerminalApp.self, forKey: .terminal)) ?? .terminal
        self.profiles = profiles
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? .system
        appearance = (try? c.decode(AppearanceMode.self, forKey: .appearance)) ?? .system
        // Both are new: a file without them still loads, and the automatic
        // check is on when the file says nothing about it.
        autoCheckUpdates = (try? c.decode(Bool.self, forKey: .autoCheckUpdates)) ?? true
        lastUpdateCheck = (try? c.decode(String.self, forKey: .lastUpdateCheck)).flatMap(Timestamp.date(from:))
        pathPromptDeclined = (try? c.decode(Bool.self, forKey: .pathPromptDeclined)) ?? false
        showMenuBar = MenuBarSetting.value(stored: try? c.decode(Bool.self, forKey: .showMenuBar))
        embeddedTerminal = (try? c.decode(Bool.self, forKey: .embeddedTerminal)) ?? true
        autoCheckConnections = (try? c.decode(Bool.self, forKey: .autoCheckConnections)) ?? true
    }

    /// The settings of a file whose profile list cannot be read. The profile
    /// list is left empty; the defaults are returned when not even the
    /// settings can be read.
    public static func settingsOnly(from bytes: Data) -> AppData {
        guard let reader = try? JSONDecoder().decode(SettingsReader.self, from: bytes) else {
            return AppData()
        }
        return reader.settings
    }

    /// Reads the settings of a whole file and ignores its profiles.
    private struct SettingsReader: Decodable {
        let settings: AppData

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = AppData(settings: c, profiles: [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(terminal, forKey: .terminal)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(language, forKey: .language)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(autoCheckUpdates, forKey: .autoCheckUpdates)
        if let lastUpdateCheck {
            try c.encode(Timestamp.string(from: lastUpdateCheck), forKey: .lastUpdateCheck)
        }
        // Written only when set, so a file without it stays as the old app wrote it.
        if pathPromptDeclined {
            try c.encode(true, forKey: .pathPromptDeclined)
        }
        if !showMenuBar {
            try c.encode(false, forKey: .showMenuBar)
        }
        if !embeddedTerminal {
            try c.encode(false, forKey: .embeddedTerminal)
        }
        if !autoCheckConnections {
            try c.encode(false, forKey: .autoCheckConnections)
        }
    }
}

/// A provider template. Only offered while creating a new profile.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let auth: AuthKind
    /// Whether the profile gets its own config folder, so its login is its own.
    public let isolate: Bool

    public init(id: String, name: String, baseURL: String, auth: AuthKind, isolate: Bool = false) {
        self.isolate = isolate
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.auth = auth
    }

    /// The same list as `PRESETS` in the Rust `src/main.rs`.
    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "claude", name: "Claude subscription", baseURL: "", auth: .none, isolate: true),
        ProviderPreset(id: "custom", name: "Custom", baseURL: "", auth: .bearer),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api", auth: .bearer),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", auth: .bearer),
        ProviderPreset(id: "kimi", name: "Kimi (Moonshot)", baseURL: "https://api.moonshot.ai/anthropic", auth: .bearer),
        ProviderPreset(id: "glm", name: "GLM (Z.ai)", baseURL: "https://api.z.ai/api/anthropic", auth: .bearer),
        ProviderPreset(id: "minimax", name: "MiniMax", baseURL: "https://api.minimax.io/anthropic", auth: .bearer),
        ProviderPreset(id: "mimo", name: "Xiaomi MiMo", baseURL: "https://api.xiaomimimo.com/anthropic", auth: .bearer),
        ProviderPreset(id: "local-proxy", name: "Local proxy (no key)", baseURL: "http://localhost:4000", auth: .none),
    ]

    /// `Custom` keeps the name empty; every other preset fills it in.
    public var fillsName: Bool { id != "custom" }
}
