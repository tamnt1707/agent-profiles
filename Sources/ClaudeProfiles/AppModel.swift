import AppKit
import Foundation
import Observation
import SwiftUI
import ClaudeProfilesCore

/// The state of the whole app: the profiles, the editor draft and the status line.
@MainActor
@Observable
final class AppModel {
    /// A message in the status bar.
    struct Status {
        enum Kind {
            case success
            case failure
            case hint
        }

        var kind: Kind
        var text: String
    }

    let loc: Loc
    let store: Store

    /// The content of `profiles.json`.
    var data: AppData = AppData()

    /// The profile shown in the sidebar.
    var selectedSlug: String?

    /// The profile being edited. `nil` when nothing is selected.
    var draft: Profile?

    /// Index of the edited profile in `data.profiles`, `nil` for a new profile.
    private(set) var draftIndex: Int?

    /// The key the user typed. Empty means "keep the stored key".
    var keyInput: String = ""

    /// Whether a key is already stored in the Keychain for this profile.
    var hasStoredKey: Bool = false

    /// Whether the API key field shows the plain text.
    var revealKey: Bool = false

    /// The message of the status bar.
    var status: Status?

    /// Set while the delete confirmation is open.
    var isConfirmingDelete: Bool = false

    init(store: Store = Store(), loc: Loc? = nil) {
        self.store = store
        self.loc = loc ?? Loc()
        load()
    }

    // MARK: - Loading

    /// Reads `profiles.json` and shows the first profile.
    func load() {
        let loaded = store.load()
        data = loaded.data
        loc.language = loaded.data.language
        applyAppearance()
        if let warning = loaded.warning {
            status = Status(kind: .failure, text: warning.localizedMessage(loc))
        }
        if let first = data.profiles.first {
            select(first)
        } else {
            draft = nil
            draftIndex = nil
            selectedSlug = nil
        }
    }

    // MARK: - Selection and editing

    /// Shows a profile in the editor.
    func select(_ profile: Profile) {
        guard let index = data.profiles.firstIndex(where: { $0.slug == profile.slug }) else { return }
        selectedSlug = profile.slug
        draft = profile
        draftIndex = index
        keyInput = ""
        revealKey = false
        hasStoredKey = (try? store.keys.get(profile.slug)) != nil
        isConfirmingDelete = false
    }

    /// Starts a new, empty profile.
    func newProfile() {
        draft = Profile(isolate: true, shareFromDefault: true)
        draftIndex = nil
        keyInput = ""
        revealKey = false
        hasStoredKey = false
        isConfirmingDelete = false
    }

    /// Applies a provider template. Only used while creating a profile.
    func apply(preset: ProviderPreset) {
        guard draft != nil else { return }
        if draft!.name.isEmpty, preset.fillsName {
            draft!.name = preset.name
        }
        draft!.baseURL = preset.baseURL
        draft!.auth = preset.auth
    }

    /// `true` when the editor holds changes that are not saved yet.
    var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        if !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return true }
        return data.profiles[index] != draft
    }

    // MARK: - Saving

    /// Saves the profile. Returns `true` when everything worked.
    @discardableResult
    func save() -> Bool {
        guard var draft else { return false }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.slug = Slug.slugify(draft.name)

        let others = data.profiles.enumerated()
            .filter { $0.offset != draftIndex }
            .map(\.element)

        do {
            try store.validate(draft, others: others)
        } catch {
            report(error)
            return false
        }

        if let index = draftIndex {
            do {
                try store.migrateSlug(from: data.profiles[index].slug, to: draft.slug)
            } catch {
                report(error)
                return false
            }
        }

        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            do {
                try store.keys.set(draft.slug, key: key)
            } catch {
                report(error)
                return false
            }
            hasStoredKey = true
            keyInput = ""
        }

        if draft.auth != .none, !hasStoredKey {
            status = Status(kind: .failure, text: ProfileError.missingAPIKey.localizedMessage(loc))
            return false
        }

        do {
            try store.materialize(draft, strings: loc.scriptStrings)
        } catch {
            report(error)
            return false
        }

        if let index = draftIndex {
            data.profiles[index] = draft
        } else {
            data.profiles.append(draft)
            draftIndex = data.profiles.count - 1
        }
        selectedSlug = draft.slug
        self.draft = draft

        do {
            try store.save(data)
        } catch {
            report(error)
            return false
        }

        status = Status(kind: .success, text: loc.t("status.saved", store.paths.command(for: draft.slug)))
        return true
    }

    // MARK: - Actions

    /// Saves the profile and opens a terminal running it.
    func openTerminal() {
        guard save() else { return }
        guard let draft else { return }
        do {
            try Launcher.launch(profile: draft, terminal: data.terminal, paths: store.paths)
            status = Status(kind: .success, text: loc.t("status.launched", data.terminal.rawValue, draft.name))
        } catch {
            report(error)
        }
    }

    /// Copies `claude-<slug>` to the clipboard.
    func copyCommand() {
        guard let draft else { return }
        let command = store.paths.command(for: draft.slug)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        status = Status(kind: .success, text: loc.t("status.copied", command))
    }

    /// Shows the delete confirmation.
    func requestDelete() {
        guard draftIndex != nil else { return }
        isConfirmingDelete = true
    }

    /// Removes the profile: the command and the key go away, the history stays.
    func deleteCurrent() {
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return }
        let profile = data.profiles.remove(at: index)
        isConfirmingDelete = false
        do {
            try store.remove(profile)
            try store.save(data)
            status = Status(kind: .success, text: loc.t("status.deleted", profile.name, store.paths.home(for: profile.slug).path))
        } catch {
            report(error)
        }
        draft = nil
        draftIndex = nil
        keyInput = ""
        hasStoredKey = false
        if let first = data.profiles.first {
            select(first)
        } else {
            selectedSlug = nil
        }
    }

    /// Opens the folder that holds the profiles in Finder.
    func revealFolder() {
        let manager = FileManager.default
        try? manager.createDirectory(at: store.paths.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.paths.root])
    }

    // MARK: - Settings

    /// Switches the language and rewrites every launcher script.
    func setLanguage(_ language: AppLanguage) {
        loc.language = language
        data.language = language
        persistSettings()
        regenerateScripts()
    }

    /// Switches the appearance.
    func setAppearance(_ appearance: AppearanceMode) {
        data.appearance = appearance
        applyAppearance()
        persistSettings()
    }

    /// Switches the terminal application.
    func setTerminal(_ terminal: TerminalApp) {
        data.terminal = terminal
        persistSettings()
    }

    /// The color scheme the window should use.
    var colorScheme: ColorScheme? {
        switch data.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Keeps the alerts and panels in the chosen appearance as well.
    func applyAppearance() {
        // `NSApp` does not exist yet while the model is created.
        guard let app = NSApp else { return }
        switch data.appearance {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func persistSettings() {
        do {
            try store.save(data)
        } catch {
            report(error)
        }
    }

    /// Rewrites every launcher script so the text inside matches the language.
    private func regenerateScripts() {
        var failures: [String] = []
        for profile in data.profiles {
            do {
                try store.materialize(profile, strings: loc.scriptStrings)
            } catch {
                failures.append(profile.name)
            }
        }
        if failures.isEmpty {
            status = Status(kind: .success, text: loc.t("status.scriptsUpdated"))
        } else {
            status = Status(kind: .failure, text: loc.t("status.scriptsFailed", failures.joined(separator: ", ")))
        }
    }

    private func report(_ error: Error) {
        if let profileError = error as? ProfileError {
            status = Status(kind: .failure, text: profileError.localizedMessage(loc))
        } else {
            status = Status(kind: .failure, text: loc.t("error.generic"))
        }
    }
}

/// Turns a core error into a sentence in the language of the user.
@MainActor
extension ProfileError {
    func localizedMessage(_ loc: Loc) -> String {
        switch self {
        case .emptyName:
            return loc.t("error.emptyName")
        case .emptySlug:
            return loc.t("error.emptySlug")
        case .duplicateSlug(let slug):
            return loc.t("error.duplicateSlug", slug)
        case .invalidBaseURL:
            return loc.t("error.invalidBaseURL")
        case .envMissingEquals(let line, let text):
            return loc.t("error.envMissingEquals", line, text)
        case .invalidEnvName(let line, let name):
            return loc.t("error.invalidEnvName", line, name)
        case .missingAPIKey:
            return loc.t("error.missingAPIKey")
        case .keychainReadFailed:
            return loc.t("error.keychainRead")
        case .keychainWriteFailed:
            return loc.t("error.keychainWrite")
        case .keychainDeleteFailed:
            return loc.t("error.keychainDelete")
        case .ioFailed(let path):
            return loc.t("error.io", path)
        case .corruptFileBackedUp(let path):
            return loc.t("error.corruptFile", path)
        case .launcherFailed(let message):
            return loc.t("error.launcher", message)
        }
    }
}
