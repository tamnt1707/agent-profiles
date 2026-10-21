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
        shareFromDefault: Bool = false
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

    public init(
        terminal: TerminalApp = .terminal,
        profiles: [Profile] = [],
        language: AppLanguage = .system,
        appearance: AppearanceMode = .system,
        autoCheckUpdates: Bool = true,
        lastUpdateCheck: Date? = nil
    ) {
        self.terminal = terminal
        self.profiles = profiles
        self.language = language
        self.appearance = appearance
        self.autoCheckUpdates = autoCheckUpdates
        self.lastUpdateCheck = lastUpdateCheck
    }

    private enum CodingKeys: String, CodingKey {
        case terminal
        case profiles
        case language
        case appearance
        case autoCheckUpdates = "auto_check_updates"
        case lastUpdateCheck = "last_update_check"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = (try? c.decode(TerminalApp.self, forKey: .terminal)) ?? .terminal
        // Strict: one malformed profile fails the whole file (it is backed up
        // and not overwritten) instead of silently dropping every profile.
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? .system
        appearance = (try? c.decode(AppearanceMode.self, forKey: .appearance)) ?? .system
        // Both are new: a file without them still loads, and the automatic
        // check is on when the file says nothing about it.
        autoCheckUpdates = (try? c.decode(Bool.self, forKey: .autoCheckUpdates)) ?? true
        lastUpdateCheck = (try? c.decode(String.self, forKey: .lastUpdateCheck)).flatMap(Timestamp.date(from:))
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
    }
}

/// A provider template. Only offered while creating a new profile.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let auth: AuthKind

    public init(id: String, name: String, baseURL: String, auth: AuthKind) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.auth = auth
    }

    /// The same list as `PRESETS` in the Rust `src/main.rs`.
    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "custom", name: "Custom", baseURL: "", auth: .bearer),
        ProviderPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api", auth: .bearer),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic", auth: .bearer),
        ProviderPreset(id: "kimi", name: "Kimi (Moonshot)", baseURL: "https://api.moonshot.ai/anthropic", auth: .bearer),
        ProviderPreset(id: "glm", name: "GLM (Z.ai)", baseURL: "https://api.z.ai/api/anthropic", auth: .bearer),
        ProviderPreset(id: "minimax", name: "MiniMax", baseURL: "https://api.minimax.io/anthropic", auth: .bearer),
        ProviderPreset(id: "local-proxy", name: "Local proxy (no key)", baseURL: "http://localhost:4000", auth: .none),
    ]

    /// `Custom` keeps the name empty; every other preset fills it in.
    public var fillsName: Bool { id != "custom" }
}
