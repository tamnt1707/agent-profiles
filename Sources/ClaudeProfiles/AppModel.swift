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

    /// The updater of the app: it checks the releases and installs them.
    let updater: UpdateController

    /// Set while the question about the unsaved changes is open.
    var isConfirmingUpdate: Bool = false

    /// A switch to another profile (or to a new one) that waits for the
    /// answer to the question about the unsaved changes.
    enum PendingSwitch: Equatable {
        case profile(String)
        case newProfile
        /// Reading `profiles.json` again, once the file reads.
        case reload
    }

    /// The answers to the question about the unsaved changes.
    enum SwitchChoice {
        case save
        case discard
        case cancel
    }

    /// The switch that waits for the answer, `nil` when nothing is pending.
    private(set) var pendingSwitch: PendingSwitch?

    /// Set while the question about switching the profile is open.
    var isConfirmingSwitch: Bool = false

    /// Why `profiles.json` could not be read. Shown until a save succeeds.
    private(set) var loadWarning: ProfileError?

    /// The task of the running update, so it can be stopped.
    private var updateTask: Task<Void, Never>?

    /// The request of "Test connection" that runs, if any.
    private var connectionTask: Task<Void, Never>?
    /// The request that loads the model list of the dropdowns, if any.
    private var modelListTask: Task<Void, Never>?
    /// Tells the finished check from the one that replaced it or was stopped.
    private var connectionToken = UUID()
    private var modelListToken = UUID()
    /// Makes the connection and model list requests of the editor.
    private let probe = ConnectionProbe()

    /// The result of "Test connection", shown under the button.
    private(set) var connectionReport: ProbeReport?
    /// `true` while the test request is on its way: the button is disabled.
    private(set) var isTestingConnection = false
    /// The last model list request. Shared by every model field of the profile.
    private(set) var modelListCache: ModelListCache?
    /// `true` while the model list is being fetched.
    private(set) var isFetchingModels = false

    /// The token usage counted for each profile, by slug. Counted on first show and on Refresh.
    private(set) var usageResults: [String: UsageResult] = [:]
    /// The slug whose usage is being counted, if any.
    private(set) var usageLoadingSlug: String?
    /// The count that is running, so that a newer one can replace it.
    private var usageTask: Task<Void, Never>?
    /// Reads the session files of the profiles. Its cache lives in the data folder.
    private let usageScanner: UsageScanner

    init(store: Store = Store(), loc: Loc? = nil, updater: UpdateController? = nil) {
        self.store = store
        self.usageScanner = UsageScanner(paths: store.paths)
        self.loc = loc ?? Loc()
        self.updater = updater ?? UpdateController()
        load()
        refreshPathStatus()
    }

    // MARK: - Loading

    /// Reads `profiles.json` and shows the first profile.
    func load() {
        applyLoaded(store.load())
        if let first = data.profiles.first {
            select(first)
        } else {
            draft = nil
            draftIndex = nil
            selectedSlug = nil
        }
    }

    /// Shows what was read from `profiles.json`: the settings, the warning and
    /// the status. The profiles and the editor are not touched here.
    private func applyLoaded(_ loaded: LoadedData) {
        data = loaded.data
        loc.language = loaded.data.language
        applyAppearance()
        loadWarning = loaded.warning
        if let warning = loaded.warning {
            status = Status(kind: .failure, text: warning.localizedMessage(loc))
        }
    }

    /// `true` while `profiles.json` is unread. Automatic saves are refused then.
    var dataFailed: Bool { store.loadFailed }

    /// The text of the warning about `profiles.json`, `nil` when there is none.
    /// While the file is unread it names the problem; after a recovering save it
    /// names the copy. It stays until the user dismisses it.
    var dataWarningText: String? {
        guard let loadWarning else { return nil }
        if store.loadFailed {
            return loadWarning.localizedMessage(loc)
        }
        if case .corruptFileBackedUp(let path) = loadWarning {
            return loc.t("banner.recovered", path)
        }
        return nil
    }

    /// Reads `profiles.json` again. The unsaved changes of the editor are asked
    /// about first, and a file that is still broken leaves the editor alone:
    /// only the warning is refreshed.
    func reloadData() {
        switch ReloadPolicy.decide(stillBroken: !store.isReadable(), hasUnsavedChanges: hasUnsavedChanges) {
        case .keepEditor:
            refreshDataWarning()
        case .askFirst:
            pendingSwitch = .reload
            isConfirmingSwitch = true
        case .loadNow:
            reloadFromDisk()
        }
    }

    /// Loads the file and shows its first profile, then says it was read again.
    private func reloadFromDisk() {
        load()
        if !store.loadFailed, loadWarning == nil {
            status = Status(kind: .success, text: loc.t("status.dataReloaded"))
        }
    }

    /// Reads a file that is still broken: the warning and the status are
    /// refreshed, the profiles, the draft and the typed key are not touched.
    private func refreshDataWarning() {
        let loaded = store.load()
        loadWarning = loaded.warning
        if let warning = loaded.warning {
            status = Status(kind: .failure, text: warning.localizedMessage(loc))
        }
    }

    /// Hides the warning about `profiles.json`.
    func dismissDataWarning() {
        loadWarning = nil
    }

    /// Shows the copy of the unreadable file in Finder, or the profiles folder
    /// when no copy exists.
    func revealBackup() {
        if case .corruptFileBackedUp(let path)? = loadWarning,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            revealFolder()
        }
    }

    // MARK: - Selection and editing

    /// Shows a profile in the editor.
    func select(_ profile: Profile) {
        guard let index = data.profiles.firstIndex(where: { $0.slug == profile.slug }) else { return }
        cancelConnectionChecks()
        selectedSlug = profile.slug
        draft = profile
        draftIndex = index
        command = CommandNameDraft(profile: profile)
        keyInput = ""
        revealKey = false
        hasStoredKey = (try? store.keys.hasKey(profile.slug)) ?? false
        isConfirmingDelete = false
    }

    /// The sidebar selection changed. The user may switch to another profile
    /// only after the unsaved changes are answered.
    func sidebarSelectionChanged(to slug: String?) {
        let editing = currentProfile?.slug
        guard slug != editing else { return }
        guard let slug, let profile = data.profiles.first(where: { $0.slug == slug }) else {
            // Nothing to show: the row of the edited profile is highlighted again.
            selectedSlug = editing
            return
        }
        guard hasUnsavedChanges else {
            select(profile)
            return
        }
        pendingSwitch = .profile(profile.slug)
        isConfirmingSwitch = true
    }

    /// The "+" button: a new profile, after the unsaved changes are answered.
    func requestNewProfile() {
        guard hasUnsavedChanges else {
            newProfile()
            return
        }
        pendingSwitch = .newProfile
        isConfirmingSwitch = true
    }

    /// Carries out the answer to the question about the unsaved changes.
    func resolveSwitch(_ choice: SwitchChoice) {
        isConfirmingSwitch = false
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        switch choice {
        case .cancel:
            selectedSlug = currentProfile?.slug
        case .save:
            if pending == .reload {
                saveIntoReloadedFile()
                return
            }
            guard save() else {
                // The save failed: stay on the edited profile, the status says why.
                selectedSlug = currentProfile?.slug
                return
            }
            perform(pending)
        case .discard:
            perform(pending)
        }
    }

    /// Saves the draft into the profile list as it reads now, so the fixes made
    /// in the file are not overwritten by a save of the old in-memory list. The
    /// saved profile stays open.
    private func saveIntoReloadedFile() {
        let edited = currentProfile?.slug
        applyLoaded(store.load())
        draftIndex = edited.flatMap { slug in data.profiles.firstIndex { $0.slug == slug } }
        if !save() {
            // The save failed: stay on the edited profile, the status says why.
            selectedSlug = currentProfile?.slug
        }
    }

    private func perform(_ pending: PendingSwitch) {
        switch pending {
        case .newProfile:
            newProfile()
        case .profile(let slug):
            if let profile = data.profiles.first(where: { $0.slug == slug }) {
                select(profile)
            } else {
                selectedSlug = currentProfile?.slug
            }
        case .reload:
            reloadFromDisk()
        }
    }

    /// Starts a new, empty profile.
    func newProfile() {
        cancelConnectionChecks()
        draft = DraftChanges.blankProfile
        draftIndex = nil
        command = CommandNameDraft()
        keyInput = ""
        revealKey = false
        hasStoredKey = false
        isConfirmingDelete = false
        selectedSlug = nil
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
        return DraftChanges.hasChanges(
            draft: draft,
            command: command,
            saved: currentProfile,
            typedKey: keyInput
        )
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
        let previousProfile = currentProfile
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
            hasStoredKey = (try? store.keys.hasKey(draft.slug)) ?? false
            forgetUsage(before: previousProfile, after: draft)

            do {
                try store.save(data)
            } catch {
                report(error)
                return false
            }

            // The warning stays: after a recovering save it names the copy until dismissed.
            status = Status(kind: .success, text: loc.t("status.saved", store.paths.command(for: draft.slug)))
            offerPathSetupIfNeeded(slug: draft.slug)
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: - Token usage

    /// Counts the usage of the saved profile, unless it was counted before.
    func loadUsageIfNeeded() {
        guard let slug = currentProfile?.slug, usageResults[slug] == nil else { return }
        loadUsage()
    }

    /// Counts the usage of the saved profile again. The files are read off the main thread.
    func loadUsage() {
        guard let profile = currentProfile else { return }
        usageTask?.cancel()
        usageLoadingSlug = profile.slug
        let scanner = usageScanner
        usageTask = Task {
            let outcome: Result<UsageResult, Error>
            do {
                outcome = .success(try await scanner.usage(for: profile))
            } catch {
                outcome = .failure(error)
            }
            // A newer count replaced this one, and that one owns the state now.
            guard !Task.isCancelled else { return }
            usageLoadingSlug = nil
            switch outcome {
            case .success(let result):
                usageResults[profile.slug] = result
            case .failure(let error):
                report(error)
            }
        }
    }

    /// A count stays valid while the folder of the profile and its isolation stay the same.
    private func forgetUsage(before previous: Profile?, after saved: Profile) {
        guard let previous else {
            usageResults[saved.slug] = nil
            return
        }
        guard previous.slug != saved.slug || previous.isolate != saved.isolate else { return }
        usageResults[previous.slug] = nil
        usageResults[saved.slug] = nil
    }

    // MARK: - Actions

    /// Saves the profile and opens a terminal running it.
    func openTerminal() {
        guard save() else { return }
        guard let draft else { return }
        let terminal = data.terminal
        let paths = store.paths
        // The terminal is started off the main thread, so the window keeps responding.
        Task {
            do {
                try await Launcher.launchInBackground(profile: draft, terminal: terminal, paths: paths)
                status = Status(kind: .success, text: loc.t("status.launched", terminal.rawValue, draft.name))
            } catch {
                report(error)
            }
        }
    }

    /// Copies `claude-<name>`: the short command, which works in any terminal
    /// once the `bin` folder is on the PATH (the Terminal commands setup does
    /// that). The command that is being edited is used, not the saved one.
    func copyCommand() {
        guard let draft else { return }
        copyToPasteboard(slug: command.slug.isEmpty ? draft.slug : command.slug)
    }

    /// Copies the command of a profile in the sidebar, the one that was clicked.
    func copyCommand(for profile: Profile) {
        copyToPasteboard(slug: profile.slug)
    }

    private func copyToPasteboard(slug: String) {
        let text = store.paths.command(for: slug)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        refreshPathStatus()
        // Without the PATH setup the short name would not run: say so.
        let onPath = loginShellStatus == .configured || loginShellStatus == .manual
            || loginShellStatus == .partlyConfigured
        status = Status(kind: onPath ? .success : .hint,
                        text: loc.t(onPath ? "status.copied" : "status.copiedNoPath", text))
    }

    /// Shows the delete confirmation.
    func requestDelete() {
        guard draftIndex != nil else { return }
        isConfirmingDelete = true
    }

    /// The message of the delete confirmation. It names everything that goes
    /// away, taken from the SAVED profile: a command name typed but not saved
    /// is not what gets deleted.
    var deleteDialogMessage: String {
        guard let target = DeleteTarget(index: draftIndex, in: data, paths: store.paths) else { return "" }
        let list = target.items.map { "• " + deleteItemText($0) }.joined(separator: "\n")
        return loc.t("delete.dialog.intro", target.name)
            + "\n\n" + list + "\n\n" + loc.t("delete.dialog.warning")
    }

    /// One line of the delete confirmation, in the language of the user.
    private func deleteItemText(_ item: DeleteTarget.Item) -> String {
        switch item {
        case .key:
            return loc.t("delete.item.key")
        case .command(let name):
            return loc.t("delete.item.command", name)
        case .folder(let path, let bytes):
            guard let bytes else { return loc.t("delete.item.folder", path) }
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return loc.t("delete.item.folderSize", path, size)
        }
    }

    /// Removes the profile: the key, the command and the config folder go away.
    func deleteCurrent() {
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return }
        let profile = data.profiles[index]
        let wasLast = data.profiles.count == 1
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
        usageResults[profile.slug] = nil
        do {
            try store.save(data)
        } catch {
            failures.append(.dataFile)
        }

        // Empty shared folders go too. Folders with content are kept.
        store.removeEmptySharedFolders()

        status = Status(
            kind: failures.isEmpty ? .success : .failure,
            text: deleteStatusText(removal, failures, profile)
        )

        // The last profile is gone: the PATH setup is no longer needed. Asked, never done silently.
        if wasLast {
            refreshPathStatus()
            if !pathSetup.managedFiles().isEmpty {
                isOfferingPathRemoval = true
            }
        }

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

    /// Shows the config folder of a profile in Finder, the one of the clicked
    /// row. A profile without a folder shows the folder of all profiles.
    func revealFolder(for profile: Profile) {
        let home = store.paths.home(for: profile.slug)
        guard FileManager.default.fileExists(atPath: home.path) else {
            revealFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([home])
    }

    // MARK: - Connection checks

    /// Sends one tiny request with the edited settings and shows the result.
    /// A second tap while the request runs does nothing.
    func testConnection() {
        guard let draft, !isTestingConnection else { return }
        let key: String
        do {
            key = try probeKey(for: draft)
        } catch {
            report(error)
            return
        }
        isTestingConnection = true
        connectionReport = nil
        let token = UUID()
        connectionToken = token
        connectionTask = Task { [weak self, probe] in
            let result = try? await probe.testConnection(profile: draft, key: key)
            guard let self, !Task.isCancelled, self.connectionToken == token else { return }
            self.isTestingConnection = false
            self.connectionReport = result
        }
    }

    /// The model list of the provider of the draft, when one is cached for its
    /// Base URL and auth kind. A changed Base URL or auth kind finds nothing here.
    var currentModelList: ModelListReport? {
        guard let draft, let cache = modelListCache,
              cache.key == ModelListCacheKey(baseURL: draft.baseURL, auth: draft.auth)
        else { return nil }
        return cache.report
    }

    /// Loads the model list for the dropdowns. A list cached for this provider is
    /// reused unless `refresh` is set. Only the user's open or refresh calls this:
    /// never typing, never the launch of the app.
    func loadModelList(refresh: Bool = false) {
        guard let draft, !isFetchingModels else { return }
        let key = ModelListCacheKey(baseURL: draft.baseURL, auth: draft.auth)
        if !refresh, let cache = modelListCache, cache.isReusable(for: key) { return }
        let apiKey: String
        do {
            apiKey = try probeKey(for: draft)
        } catch {
            report(error)
            return
        }
        isFetchingModels = true
        let token = UUID()
        modelListToken = token
        modelListTask = Task { [weak self, probe] in
            let result = try? await probe.fetchModels(profile: draft, key: apiKey)
            guard let self, !Task.isCancelled, self.modelListToken == token else { return }
            self.isFetchingModels = false
            if let result {
                self.modelListCache = ModelListCache(key: key, report: result)
            }
        }
    }

    /// Stops the requests that run and forgets their results. Called when another profile opens.
    func cancelConnectionChecks() {
        connectionTask?.cancel()
        connectionTask = nil
        modelListTask?.cancel()
        modelListTask = nil
        connectionToken = UUID()
        modelListToken = UUID()
        isTestingConnection = false
        isFetchingModels = false
        connectionReport = nil
        modelListCache = nil
    }

    /// The key of a request. The Keychain is read only now, at the click, and the
    /// key is kept only for the request.
    private func probeKey(for draft: Profile) throws -> String {
        try ConnectionProbe.key(
            typed: keyInput,
            auth: draft.auth,
            account: currentProfile?.slug ?? draft.slug,
            keys: store.keys
        )
    }

    // MARK: - Updates

    /// The version of the app as it is shown to the user.
    var currentVersionText: String {
        let version = updater.configuration.versionText
        return version.isEmpty ? "—" : version
    }

    /// When the last search for a new version was.
    var lastCheckedText: String {
        guard let last = data.lastUpdateCheck else { return loc.t("settings.updates.never") }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: last)
    }

    /// The repository the new versions are taken from, when the build knows it.
    var updateRepositoryText: String {
        let repo = updater.configuration.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.isEmpty ? "—" : repo
    }

    /// The automatic check of the launch: once a day, and never with an error.
    func checkForUpdatesAutomatically() async {
        guard data.autoCheckUpdates, updater.isEnabled else { return }
        if let last = data.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        await checkForUpdates(manual: false)
    }

    /// Looks for a new version.
    ///
    /// The automatic check never shows an error: it would only disturb the
    /// user without being able to do anything about it.
    func checkForUpdates(manual: Bool) async {
        guard updater.isEnabled else {
            if manual {
                status = Status(kind: .failure, text: loc.t("error.update.notConfigured"))
            }
            return
        }
        if manual {
            status = Status(kind: .hint, text: loc.t("status.updateChecking"))
        }
        do {
            let result = try await updater.check(silent: !manual)
            data.lastUpdateCheck = Date()
            // The automatic check does not replace the status with a save error.
            persistSettings(quietly: !manual)
            switch result {
            case .upToDate:
                if manual {
                    status = Status(kind: .success, text: loc.t("status.updateUpToDate", currentVersionText))
                }
            case .available(let info):
                if manual {
                    status = Status(kind: .success, text: loc.t("status.updateAvailable", info.version.description))
                }
            }
        } catch {
            if manual {
                report(error)
            } else {
                // The automatic check never shows an error.
                updater.state = .idle
            }
        }
    }

    /// Starts the update. Unsaved changes are asked about first.
    func updateNow() {
        guard updater.isEnabled else { return }
        if hasUnsavedChanges {
            isConfirmingUpdate = true
            return
        }
        startUpdate()
    }

    /// Saves the changes and starts the update.
    func saveAndUpdate() {
        isConfirmingUpdate = false
        guard save() else { return }
        startUpdate()
    }

    /// Throws the changes away and starts the update.
    func discardAndUpdate() {
        isConfirmingUpdate = false
        startUpdate()
    }

    /// The update itself: download, check, replace and quit.
    private func startUpdate() {
        // A second tap while the update is starting or running is refused here:
        // it neither cancels the first run nor starts another one.
        guard !updater.isBusy else { return }
        let info: UpdateInfo
        do {
            // Marks the updater busy before the task exists, so no second tap can pass.
            info = try updater.beginInstall()
        } catch {
            report(error)
            return
        }
        updateTask = Task { [weak self] in
            await self?.runUpdate(info)
        }
    }

    private func runUpdate(_ info: UpdateInfo) async {
        do {
            try await updater.runInstall(info)
            // The helper replaces the bundle as soon as this app has quit.
            status = Status(kind: .success, text: loc.t("status.updateInstalling"))
            NSApp.terminate(nil)
        } catch is CancellationError {
            updater.state = .idle
        } catch {
            if Task.isCancelled {
                updater.state = .idle
                return
            }
            report(error)
        }
    }

    /// Stops the download.
    func cancelUpdate() {
        updateTask?.cancel()
        updateTask = nil
        // The run stops reporting at once, so a late progress report cannot show it again.
        updater.cancelRun()
        status = Status(kind: .hint, text: loc.t("error.update.cancelled"))
    }

    /// Hides the banner without touching anything else.
    func dismissUpdateBanner() {
        updater.state = .idle
    }

    // MARK: - Terminal commands (PATH of the shells)

    /// The PATH setup of the shells, built from the current paths.
    private var pathSetup: ShellPathSetup { ShellPathSetup(paths: store.paths) }

    /// The shell of new terminal tabs. Read with `refreshPathStatus()`.
    private(set) var loginKind: ShellKind = ShellKind.from(loginShell: ShellPathSetup.currentLoginShell())
    /// The state of the login shell.
    private(set) var loginShellStatus: ShellStatus = .notConfigured
    /// The state of every supported shell. Read when needed, never while drawing.
    private(set) var shellStatuses: [ShellKind: ShellStatus] = [:]
    /// For a damaged shell: the file that is damaged, with `~`. Read with `refreshPathStatus()`.
    private(set) var shellDamagedFiles: [ShellKind: String] = [:]
    /// For a shell with a block in a file it does not read: those files, with `~`.
    private(set) var shellStrayFiles: [ShellKind: String] = [:]
    /// `true` when `ZDOTDIR` cannot be read but a zsh block the app wrote can still be removed.
    private(set) var zshRemovableWhileUnresolved = false
    /// Set while the question "Make the claude-<name> commands work…?" is open.
    var isOfferingPathSetup = false
    /// The profile slug shown in that question.
    private(set) var pathOfferSlug = ""
    /// Set when the question is about a shell that is only partly set up.
    private(set) var pathOfferPartly = false
    /// Set while the question about removing the PATH setup is open.
    var isOfferingPathRemoval = false
    /// The result of the last action of the Terminal commands section in Settings.
    var pathSetupMessage: Status?
    /// The question is asked at most once per launch: "Not now" holds until the app starts again.
    private var pathOfferAskedThisLaunch = false

    /// Reads the state of every shell.
    func refreshPathStatus() {
        let setup = pathSetup
        loginKind = setup.loginKind
        loginShellStatus = setup.loginStatus()
        shellStatuses = Dictionary(uniqueKeysWithValues: ShellKind.supported.map { ($0, setup.status(for: $0)) })
        shellDamagedFiles = [:]
        shellStrayFiles = [:]
        zshRemovableWhileUnresolved = setup.hasZshBlockWhileUnresolved()
        for shell in ShellKind.supported {
            if shellStatuses[shell] == .damaged, let file = setup.damagedFile(for: shell) ?? setup.targets(for: shell).first?.url {
                shellDamagedFiles[shell] = displayPath(file)
            }
            let strays = setup.strayFiles(for: shell)
            if !strays.isEmpty {
                shellStrayFiles[shell] = strays.map { displayPath($0) }.joined(separator: ", ")
            }
        }
    }

    /// The line the user copies when the app does not edit the login shell.
    var loginManualLine: String { pathSetup.manualLine(for: loginKind) }

    /// The zsh line the user adds by hand when `ZDOTDIR` cannot be read.
    var zshManualLine: String { pathSetup.manualLine(for: .zsh) }

    /// The files that carry the setup, for the question about removing it.
    var pathFilesText: String {
        pathSetup.managedFiles().map { displayPath($0) }.joined(separator: ", ")
    }

    /// A path with the home folder written as "~".
    func displayPath(_ url: URL) -> String {
        let home = store.paths.home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// After a successful save: asks once per launch, for the login shell only.
    /// A shell that is only partly set up is offered too, with a text that says so.
    private func offerPathSetupIfNeeded(slug: String) {
        refreshPathStatus()
        guard !data.pathPromptDeclined, !pathOfferAskedThisLaunch else { return }
        switch loginShellStatus {
        case .notConfigured: pathOfferPartly = false
        case .partlyConfigured:
            // A block in a file bash no longer reads is not offered: Remove comes first.
            guard shellStrayFiles[loginKind] == nil else { return }
            pathOfferPartly = true
        default: return
        }
        pathOfferAskedThisLaunch = true
        pathOfferSlug = slug
        isOfferingPathSetup = true
    }

    /// "Don't ask again", kept in profiles.json.
    func declinePathPromptForever() {
        data.pathPromptDeclined = true
        persistSettings()
    }

    /// Adds the setup to one shell and returns the message to show.
    @discardableResult
    func addPathSetup(for shell: ShellKind) -> Status {
        let message: Status
        do {
            switch try pathSetup.install(for: shell) {
            case .added(let files, _):
                let first = files.first.map { displayPath($0) } ?? ""
                // The shells that are already open do not read the file again:
                // put the command that does it on the clipboard.
                if let file = files.first {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("source \(ShellQuote.quote(file.path))", forType: .string)
                }
                message = Status(kind: .success, text: loc.t("pathSetup.done", first))
            case .alreadyConfigured:
                message = Status(kind: .hint, text: loc.t("pathSetup.alreadyDone"))
            }
        } catch {
            message = Status(kind: .failure, text: pathErrorText(error))
        }
        refreshPathStatus()
        return message
    }

    /// Removes the setup of one shell. Lines written by hand are never removed.
    func removePathSetup(for shell: ShellKind) -> Status {
        let message: Status
        do {
            message = removalMessage(try pathSetup.remove(for: shell))
        } catch {
            message = Status(kind: .failure, text: pathErrorText(error))
        }
        refreshPathStatus()
        return message
    }

    /// Removes the setup of every shell. Used when the last profile is deleted.
    /// A file that cannot be changed is left alone and named in the message.
    func removeAllPathSetup() -> Status {
        let report = pathSetup.removeEverything()
        let removed = removalMessage(report.changed)
        var message = removed
        if !report.skipped.isEmpty {
            let list = report.skipped
                .map { displayPath($0.url) + ": " + pathErrorText($0.reason) }
                .joined(separator: "\n")
            let leftAlone = loc.t("pathSetup.leftAlone", list)
            // Nothing removed: the skipped files are the whole answer.
            message = report.changed.isEmpty
                ? Status(kind: .failure, text: leftAlone)
                : Status(kind: .failure, text: removed.text + "\n" + leftAlone)
        }
        refreshPathStatus()
        return message
    }

    private func removalMessage(_ files: [URL]) -> Status {
        guard !files.isEmpty else {
            return Status(kind: .hint, text: loc.t("pathSetup.nothingToRemove"))
        }
        let list = files.map { displayPath($0) }.joined(separator: ", ")
        return Status(kind: .success, text: loc.t("pathSetup.removed", list))
    }

    private func pathErrorText(_ error: Error) -> String {
        guard let shellError = error as? ShellPathError else { return loc.t("error.generic") }
        switch shellError {
        case .damaged(let path):
            return loc.t("pathSetup.damaged", displayPath(URL(fileURLWithPath: path)))
        case .partial(let changed, let reason):
            let list = changed.map { displayPath(URL(fileURLWithPath: $0)) }.joined(separator: ", ")
            return pathErrorText(reason) + "\n" + loc.t("pathSetup.partial", list)
        case .blockElsewhere(let path):
            return loc.t("pathSetup.elsewhere", displayPath(URL(fileURLWithPath: path)))
        case .unsupported:
            return loc.t("pathSetup.unsupportedBar", loginKind.displayName, loginManualLine)
        case .ioFailed(let path):
            return loc.t("pathSetup.failed", displayPath(URL(fileURLWithPath: path)))
        case .brokenLink(let path):
            return loc.t("pathSetup.brokenLink", displayPath(URL(fileURLWithPath: path)))
        case .notWritable(let path):
            return loc.t("pathSetup.readOnly", displayPath(URL(fileURLWithPath: path)))
        case .changedWhileEditing:
            return loc.t("pathSetup.changedWhileEditing")
        case .changedButNotRecorded(let changed):
            let list = changed.map { displayPath(URL(fileURLWithPath: $0)) }.joined(separator: ", ")
            return loc.t("pathSetup.recordFailed", list)
        case .zdotdirUnresolved(let path):
            return loc.t("pathSetup.zdotdir", displayPath(URL(fileURLWithPath: path)), zshManualLine)
        }
    }

    /// Copies the line for the login shell, for a shell the app does not edit.
    func copyLoginLine() {
        let line = loginManualLine
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
        status = Status(kind: .success, text: loc.t("status.copied", line))
    }

    /// Shows ~/.zshrc in Finder, or the home folder when it does not exist.
    func revealZshrc() {
        let zshrc = store.paths.home.appendingPathComponent(".zshrc")
        let target = FileManager.default.fileExists(atPath: zshrc.path) ? zshrc : store.paths.home
        NSWorkspace.shared.activateFileViewerSelecting([target])
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

    /// Switches the automatic check of a new version on or off.
    func setAutoCheckUpdates(_ enabled: Bool) {
        data.autoCheckUpdates = enabled
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

    /// Writes `profiles.json`. While the file is unreadable the write is refused
    /// by the store, and the refusal is shown unless `quietly` is set.
    private func persistSettings(quietly: Bool = false) {
        do {
            try store.save(data)
        } catch {
            if !quietly {
                report(error)
            }
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
        } else if let storeError = error as? StoreError {
            status = Status(kind: .failure, text: storeError.localizedMessage(loc))
        } else if let updateError = error as? UpdateError {
            status = Status(kind: .failure, text: updateError.localizedMessage(loc))
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
            return loc.t("error.corruptFile", URL(fileURLWithPath: path).lastPathComponent)
        case .dataUnreadable:
            return loc.t("error.dataUnreadable")
        case .launcherFailed(let message):
            return loc.t("error.launcher", message)
        case .unsafeDeletePath(let path):
            return loc.t("error.unsafeDeletePath", path)
        case .invalidPrice:
            return loc.t("error.invalidPrice")
        }
    }
}

/// Turns a store error into a sentence in the language of the user.
@MainActor
extension StoreError {
    func localizedMessage(_ loc: Loc) -> String {
        switch self {
        case .dataFileNotLoaded:
            return loc.t("error.dataNotLoaded")
        case .dataFileUnreadable:
            return loc.t("error.dataNotLoadedNoCopy")
        case .unsafeSlug:
            return loc.t("error.unsafeSlug")
        case .targetHomeExists:
            return loc.t("error.targetHomeExists")
        case .noBackup:
            return loc.t("error.noBackup")
        }
    }
}

/// Turns an update error into a sentence in the language of the user.
@MainActor
extension UpdateError {
    func localizedMessage(_ loc: Loc) -> String {
        switch self {
        case .notConfigured:
            return loc.t("error.update.notConfigured")
        case .networkUnavailable:
            return loc.t("error.update.networkUnavailable")
        case .timedOut:
            return loc.t("error.update.timedOut")
        case .rateLimited:
            return loc.t("error.update.rateLimited")
        case .noReleases:
            return loc.t("error.update.noReleases")
        case .invalidResponse:
            return loc.t("error.update.invalidResponse")
        case .httpError(let code):
            return loc.t("error.update.httpError", code)
        case .downloadFailed:
            return loc.t("error.update.downloadFailed")
        case .fileTooLarge:
            return loc.t("error.update.fileTooLarge")
        case .cancelled:
            return loc.t("error.update.cancelled")
        case .disallowedHost(let host):
            return loc.t("error.update.disallowedHost", host)
        case .insecureURL:
            return loc.t("error.update.insecureURL")
        case .missingSignature:
            return loc.t("error.update.missingSignature")
        case .invalidSignature:
            return loc.t("error.update.invalidSignature")
        case .invalidPublicKey:
            return loc.t("error.update.invalidPublicKey")
        case .extractionFailed:
            return loc.t("error.update.extractionFailed")
        case .unexpectedBundle:
            return loc.t("error.update.unexpectedBundle")
        case .bundleMismatch:
            return loc.t("error.update.bundleMismatch")
        case .notNewer:
            return loc.t("error.update.notNewer")
        case .keyMismatch:
            return loc.t("error.update.keyMismatch")
        case .codesignFailed:
            return loc.t("error.update.codesignFailed")
        case .bundleNotWritable:
            return loc.t("error.update.bundleNotWritable")
        case .installFailed:
            return loc.t("error.update.installFailed")
        }
    }
}
