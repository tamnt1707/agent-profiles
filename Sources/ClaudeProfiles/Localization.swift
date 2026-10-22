import Foundation
import Observation
import ClaudeProfilesCore

/// Finds the SwiftPM resource bundle, no matter whether the app runs from
/// `swift run`, from the `.build` folder or from the installed `.app` bundle.
enum ResourceLocator {
    /// Name of the bundle SwiftPM generates for the executable target.
    static let bundleName = "ClaudeProfiles_ClaudeProfiles.bundle"

    static let bundle: Bundle = {
        var candidates: [URL] = []
        // Installed app: the bundle sits in Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(bundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        // The binary of an app that is started directly from the terminal.
        if let contents = Bundle.main.executableURL?
            .deletingLastPathComponent()      // Contents/MacOS
            .deletingLastPathComponent()      // Contents
            .appendingPathComponent("Resources", isDirectory: true) {
            candidates.append(contents.appendingPathComponent(bundleName))
        }
        for candidate in candidates {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return Bundle.module
    }()
}

/// The languages the app ships with.
enum ResolvedLanguage: String {
    case en
    case vi

    /// "System" resolves to Vietnamese when the system asks for Vietnamese.
    static func resolve(_ language: AppLanguage) -> ResolvedLanguage {
        switch language {
        case .en: return .en
        case .vi: return .vi
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("vi") ? .vi : .en
        }
    }
}

/// Runtime language switching. Every visible string of the app comes from here.
@MainActor
@Observable
final class Loc {
    /// The language the user picked in the settings.
    var language: AppLanguage = .system {
        didSet { reload() }
    }

    /// The language that is actually used right now.
    private(set) var resolved: ResolvedLanguage = .en

    /// The locale of the language that is used right now. The numbers and the
    /// money of the app are written the way this locale writes them, not the
    /// way the system of the user writes them.
    var locale: Locale {
        switch resolved {
        case .en: return Locale(identifier: "en")
        case .vi: return Locale(identifier: "vi")
        }
    }

    /// The strings of the current language.
    private(set) var table: [String: String] = [:]

    /// The English strings, used whenever a key is missing.
    private(set) var fallback: [String: String] = [:]

    private let bundle: Bundle

    init(language: AppLanguage = .system, bundle: Bundle = ResourceLocator.bundle) {
        self.bundle = bundle
        self.language = language
        reload()
    }

    private func reload() {
        resolved = ResolvedLanguage.resolve(language)
        table = load(resolved)
        if fallback.isEmpty {
            fallback = load(.en)
        }
    }

    private func load(_ language: ResolvedLanguage) -> [String: String] {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let contents = NSDictionary(contentsOfFile: path + "/Localizable.strings") as? [String: String]
        else { return [:] }
        return contents
    }

    /// The text of a key. Falls back to English and then to the key itself.
    func t(_ key: String) -> String {
        if let value = table[key] { return value }
        if let value = fallback[key] { return value }
        return key
    }

    /// The text of a key with `%@` / `%d` placeholders filled in.
    func t(_ key: String, _ arguments: CVarArg...) -> String {
        let template = t(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, arguments: arguments)
    }

    /// The sentences that end up inside the launcher scripts.
    var scriptStrings: ScriptStrings {
        ScriptStrings(
            headerTemplate: t("script.header"),
            unsetComment: t("script.unset"),
            missingKeyTemplate: t("script.missingKey"),
            accessDeniedTemplate: t("script.accessDenied")
        )
    }
}
