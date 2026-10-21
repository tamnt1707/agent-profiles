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

    /// The editable command name of the edited profile.
    var command = CommandNameDraft()

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
        command = CommandNameDraft(profile: profile)
        keyInput = ""
        revealKey = false
        hasStoredKey = (try? store.keys.get(profile.slug)) != nil
        isConfirmingDelete = false
    }

    /// Starts a new, empty profile.
    func newProfile() {
        draft = Profile(isolate: true, shareFromDefault: true)
        draftIndex = nil
        command = CommandNameDraft()
        keyInput = ""
        revealKey = false
        hasStoredKey = false
        isConfirmingDelete = false
    }

    /// Applies a provider template. Only used while creating a profile.
    func apply(preset: ProviderPreset) {
        guard draft != nil else { return }
        if draft!.name.isEmpty, preset.fillsName {
            setName(preset.name)
        }
        draft!.baseURL = preset.baseURL
        draft!.auth = preset.auth
    }

    /// The name of the profile changed. In auto mode the command follows it.
    func setName(_ name: String) {
        draft?.name = name
        command.setName(name)
        syncSlug()
    }

    /// The user typed in the command field: the command becomes custom.
    func setCommandInput(_ input: String) {
        command.setInput(input)
        syncSlug()
    }

    /// "Reset to auto": the command follows the profile name again.
    func resetCommandToAuto() {
        command.resetToAuto()
        syncSlug()
    }

    /// Keeps the slug of the draft in sync with the command name.
    private func syncSlug() {
        draft?.slug = command.slug
    }

    /// `true` when the editor holds changes that are not saved yet.
    var hasUnsavedChanges: Bool {
        guard let draft else { return false }
        if !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return true }
        return data.profiles[index] != draft
    }

    // MARK: - The command name

    /// The profile as it is stored right now.
    var currentProfile: Profile? {
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return nil }
        return data.profiles[index]
    }

    /// The other profiles, the ones the edited one is compared with.
    var otherProfiles: [Profile] {
        data.profiles.enumerated()
            .filter { $0.offset != draftIndex }
            .map(\.element)
    }

    /// The problem with the current command name, if there is one.
    ///
    /// The check runs while the user types, so the editor can show the
    /// problem right away and block the save.
    var commandIssue: ProfileError? {
        let slug = command.slug
        guard !slug.isEmpty else { return nil }
        if let owner = command.duplicateOwner(among: otherProfiles) {
            return .duplicateCommand(slug, owner.name)
        }
        if let path = store.foreignCommandPath(for: slug, ownedBy: currentProfile?.slug) {
            return .foreignCommandExists(slug, path)
        }
        return nil
    }

    // MARK: - Saving

    /// Saves the profile. Returns `true` when everything worked.
    @discardableResult
    func save() -> Bool {
        guard var draft else { return false }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        command.name = draft.name
        if command.mode == .auto {
            command.input = Slug.slugify(draft.name)
        }
        draft.slug = command.slug

        do {
            let result = try store.saveProfile(
                draft,
                others: otherProfiles,
                previous: currentProfile,
                key: keyInput,
                strings: loc.scriptStrings
            )
            draft.slug = result.slug

            if let index = draftIndex {
                data.profiles[index] = draft
            } else {
                data.profiles.append(draft)
                draftIndex = data.profiles.count - 1
            }
            selectedSlug = draft.slug
            self.draft = draft
            command = CommandNameDraft(profile: draft)
            keyInput = ""
            hasStoredKey = (try? store.keys.get(draft.slug)) != nil

            do {
                try store.save(data)
            } catch {
                report(error)
                return false
            }

            status = Status(kind: .success, text: loc.t("status.saved", store.paths.command(for: draft.slug)))
            return true
        } catch {
            report(error)
            return false
        }
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

    /// Copies `claude-<slug>` to the clipboard. The command that is being
    /// edited is used, not the one of the saved profile.
    func copyCommand() {
        guard let draft else { return }
        let slug = command.slug.isEmpty ? draft.slug : command.slug
        let text = store.paths.command(for: slug)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = Status(kind: .success, text: loc.t("status.copied", text))
    }

    /// Shows the delete confirmation.
    func requestDelete() {
        guard draftIndex != nil else { return }
        isConfirmingDelete = true
    }

    /// The message of the delete confirmation. It names everything that goes
    /// away, so nothing is deleted by surprise.
    var deleteDialogMessage: String {
        let profile = draft
        let slug = profile?.slug ?? ""
        let items = [
            loc.t("delete.item.key"),
            loc.t("delete.item.command", store.paths.command(for: slug)),
            deleteFolderItem(for: slug),
        ]
        let list = items.map { "• \($0)" }.joined(separator: "\n")
        return loc.t("delete.dialog.intro", profile?.name ?? "")
            + "\n\n" + list + "\n\n" + loc.t("delete.dialog.warning")
    }

    /// The folder of a profile with its size, when that is cheap to compute.
    private func deleteFolderItem(for slug: String) -> String {
        let path = store.paths.home(for: slug).path
        guard let bytes = DirectorySize.measure(at: store.paths.home(for: slug)) else {
            return loc.t("delete.item.folder", path)
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return loc.t("delete.item.folderSize", path, size)
    }

    /// Removes the profile: the key, the command and the config folder go away.
    func deleteCurrent() {
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return }
        let profile = data.profiles[index]
        isConfirmingDelete = false

        let removal: RemovalReport
        do {
            removal = try store.remove(profile)
        } catch {
            // The path is not safe: nothing was deleted and the profile stays.
            report(error)
            return
        }

        // The entry always leaves the list and the data file.
        var failures = removal.failures
        data.profiles.remove(at: index)
        do {
            try store.save(data)
        } catch {
            failures.append(.dataFile)
        }

        status = Status(
            kind: failures.isEmpty ? .success : .failure,
            text: deleteStatusText(removal, failures, profile)
        )

        draft = nil
        draftIndex = nil
        command = CommandNameDraft()
        keyInput = ""
        hasStoredKey = false
        if let first = data.profiles.first {
            select(first)
        } else {
            selectedSlug = nil
        }
    }

    /// The message of the status bar after a delete: what went away and what
    /// is still on the disk.
    private func deleteStatusText(_ report: RemovalReport, _ failures: [RemovalFailure], _ profile: Profile) -> String {
        var removed: [String] = []
        if report.removedKey {
            removed.append(loc.t("delete.item.key"))
        }
        if report.removedScript {
            removed.append(loc.t("delete.item.command", store.paths.command(for: profile.slug)))
        }
        if report.removedHome {
            removed.append(loc.t("delete.item.folder", store.paths.home(for: profile.slug).path))
        }

        var text = loc.t("status.deleted", profile.name)
        if !removed.isEmpty {
            text += " " + loc.t("status.deletedItems", removed.joined(separator: ", "))
        }
        let leftovers = failures.map { failureText($0) }
        if !leftovers.isEmpty {
            text += " " + loc.t("status.deleteFailed", leftovers.joined(separator: ", "))
        }
        return text
    }

    /// What is left on the disk, in the language of the user.
    private func failureText(_ failure: RemovalFailure) -> String {
        switch failure {
        case .key(let account): return loc.t("delete.failure.key", account)
        case .script(let path): return loc.t("delete.failure.command", path)
        case .home(let path): return loc.t("delete.failure.folder", path)
        case .dataFile: return loc.t("delete.failure.dataFile")
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
        case .duplicateCommand(let slug, let name):
            return loc.t("error.duplicateCommand", slug, name)
        case .foreignCommandExists(let slug, let path):
            return loc.t("error.foreignCommand", slug, path)
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
        case .unsafeDeletePath(let path):
            return loc.t("error.unsafeDeletePath", path)
        }
    }
}
