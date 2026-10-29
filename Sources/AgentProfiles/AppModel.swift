import AppKit
import Foundation
import Observation
import SwiftUI
import AgentProfilesCore

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
    private(set) var draftIndex: Int? {
        // The kit status belongs to the saved profile at this index.
        didSet { refreshOrchestration() }
    }

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

    /// The state of the delete confirmation: the items it lists and the
    /// measurement of the config folder that is still on its way.
    private(set) var deleteDialog = DeleteDialogState()

    /// The text of the delete confirmation.
    ///
    /// It is built when the question is asked and never while the window is
    /// drawn: the size of the config folder is measured away from the main
    /// thread, so asking for it while drawing would freeze the app.
    private(set) var deleteDialogText: String = ""

    /// What the orchestration kit has in the config folder of the saved profile,
    /// `nil` when no profile is open. Read when something changes, never while drawing.
    private(set) var orchestration: OrchestrationStatus?

    /// The shared item (a link to `~/.claude`) the user is asked to copy, if any.
    var orchestrationUnshare: OrchestrationItem?
    /// Set while the question about the copy is open.
    var isConfirmingUnshare: Bool = false

    /// Which command line agents are installed on this Mac. Read when the app
    /// starts and when a profile is created, never while drawing.
    private(set) var agentInstalls: [AgentKind: AgentInstall] = [:]
    /// `true` while the agents are being looked for.
    private(set) var isDetectingAgents = false

    /// Looks for the agents, off the main thread: the login shell may be slow.
    func refreshAgents() {
        guard !isDetectingAgents else { return }
        isDetectingAgents = true
        Task.detached(priority: .userInitiated) {
            let found = AgentDetector.detectAll()
            await MainActor.run {
                self.agentInstalls = found
                self.isDetectingAgents = false
            }
        }
    }

    /// The terminals inside the app, one per profile.
    let terminals = TerminalSessions()

    /// What the detail pane shows for each profile.
    enum DetailTab: Equatable {
        case settings
        case terminal
    }

    /// The tab of each profile. A profile that is not here shows its settings.
    private(set) var detailTabs: [String: DetailTab] = [:]

    /// The terminal tab that is shown for each profile.
    private(set) var selectedSessions: [String: Int] = [:]

    func detailTab(for slug: String) -> DetailTab {
        detailTabs[slug] ?? .settings
    }

    func setDetailTab(_ tab: DetailTab, for slug: String) {
        guard detailTabs[slug] != tab else { return }
        detailTabs[slug] = tab
    }

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

    /// `true` when the model list may be fetched: not while another fetch runs
    /// and not while the check of the profiles runs.
    var canFetchModelList: Bool {
        ModelFetchGate.canFetch(isFetching: isFetchingModels, isCheckingHealth: isCheckingHealth)
    }

    /// How far the running "Check all connections" has got.
    struct HealthProgress: Equatable {
        var done: Int
        var total: Int
    }

    /// The last test of each profile, kept for this session only.
    private(set) var health = HealthBook()
    /// What is known about the key of each profile: stored, missing, or the
    /// Keychain could not be read. A slug that is not in the map was never
    /// read: its presence is unknown.
    ///
    /// This is the one map of the stored keys: the health dot and the menu bar
    /// both read it, and there is only one read of the Keychain for it.
    private(set) var keyPresence = KeyPresenceBook()
    /// The check of all profiles while it runs.
    private var healthTask: Task<Void, Never>?
    /// The progress of the running check, `nil` when none runs.
    private(set) var healthProgress: HealthProgress?
    /// Set while the question "Check all connections?" is open.
    var isConfirmingHealthCheck = false

    /// `true` while "Check all connections" runs.
    var isCheckingHealth: Bool { healthTask != nil }

    /// The message of the last failed terminal launch. The menu bar shows it
    /// until the next launch attempt.
    private(set) var menuBarError: String?
    /// The recent folders of the menu, looked up when it opens. The menu
    /// itself never asks the file system while it is drawn.
    private(set) var menuBarFolders: [String: [String]] = [:]
    /// The state of the folders of the menu bar, with the number of the lookup
    /// that is running. A lookup that comes back late never replaces a newer
    /// answer.
    private var menuFolderState = MenuFolderState()
    /// The lookup of the recent folders that is running, so that it can be
    /// stopped.
    private var menuFolderLookup: Task<Void, Never>?
    /// The checks of the folders that took too long. They go on in the
    /// background, and the next opening of the menu uses their answer.
    private var slowFolderChecks: [String: SlowFolderCheck] = [:]
    /// The launches that are on their way. A second click on the same item of
    /// the menu is ignored while the first one is still running.
    private var launchGuard = LaunchGuard()

    /// The token usage counted for each profile, by slug. Counted on first show and on Refresh.
    private(set) var usageResults: [String: UsageResult] = [:]
    /// The state of the count of every profile: which ones are counted right
    /// now, and which ones were stopped. The numbers of a stopped count stay.
    private(set) var usageScanStates = UsageScanStates()
    /// A number per slug. Only the newest count of a slug is used, so a count
    /// that was replaced or stopped never shows its numbers.
    private var usageGenerations: [String: Int] = [:]
    /// The running count of every profile, so that it can be stopped.
    private var usageTasks: [String: Task<Void, Never>] = [:]
    /// Reads the session files of the profiles. Its cache lives in the data folder.
    private let usageScanner: UsageScanner
    /// The observer of the notification that tells the app that it is active
    /// again. It is removed when the model goes away.
    ///
    /// The token is not observed and not isolated: it is set when the model is
    /// made and read when it goes away, and the model has to let go of the
    /// observer from its own `deinit`.
    @ObservationIgnored
    nonisolated(unsafe) private var didBecomeActiveObserver: NSObjectProtocol?

    init(store: Store = Store(), loc: Loc? = nil, updater: UpdateController? = nil) {
        self.store = store
        self.usageScanner = UsageScanner(paths: store.paths)
        self.loc = loc ?? Loc()
        self.updater = updater ?? UpdateController()
        load()
        refreshPathStatus()
        observeDidBecomeActive()
    }

    deinit {
        // The observer must not keep the model alive.
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    /// Watches the app becoming active, so the keys are read again.
    ///
    /// The app can be used without its window: a key that was added outside of
    /// the app must be seen, even when the menu bar is the only thing that is
    /// open. The window does not watch this any more.
    private func observeDidBecomeActive() {
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification is delivered on the main queue, so the model is
            // used on its own actor.
            MainActor.assumeIsolated {
                self?.refreshStoredKeys()
            }
        }
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
        // The file was read again: the keys, the folders of the menu and the
        // last tests are looked at again, once each.
        refreshStoredKeys()
        refreshMenuBarFolders()
        health.profilesLoaded(data.profiles)
        // The profiles are read again: the name of the command is looked at
        // again, because another profile may own it now.
        refreshForeignCommandPath()
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
        // Another profile is shown: a measurement of the old one must not
        // come back and change the text of the next question.
        cancelDelete()
        // The name of the command of the new profile is looked at.
        refreshForeignCommandPath()
        refreshOrchestration()
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
        // The file was read again: the keys, the folders of the menu and the
        // last tests are looked at again by `applyLoaded`.
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
        refreshAgents()
        cancelConnectionChecks()
        draft = DraftChanges.blankProfile
        draftIndex = nil
        command = CommandNameDraft()
        keyInput = ""
        revealKey = false
        hasStoredKey = false
        cancelDelete()
        selectedSlug = nil
        // A new profile has no name yet: nothing takes it.
        refreshForeignCommandPath()
    }

    /// Applies a provider template. Only used while creating a profile.
    func apply(preset: ProviderPreset) {
        guard draft != nil else { return }
        if draft!.name.isEmpty, preset.fillsName {
            setName(preset.name)
        }
        draft!.baseURL = preset.baseURL
        draft!.auth = preset.auth
        if preset.isolate { draft!.isolate = true }
        if preset.auth == .none { keyInput = "" }
    }

    /// The name of the profile changed. In auto mode the command follows it.
    func setName(_ name: String) {
        guard SettingsChange.isDifferent(draft?.name, name) else { return }
        draft?.name = name
        command.setName(name)
        syncSlug()
    }

    /// The user typed in the command field: the command becomes custom.
    func setCommandInput(_ input: String) {
        guard SettingsChange.isDifferent(command.input, input) else { return }
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
        // The name of the command changed: the folder of the launchers is
        // looked at again, so the editor can tell right away that the name
        // is taken by a file that this app did not write.
        refreshForeignCommandPath()
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
        if let path = foreignCommandPath {
            return .foreignCommandExists(slug, path)
        }
        return nil
    }

    /// The file that took the name of the command, when a file that this app
    /// did not write has that name.
    ///
    /// The file system is not asked while the window is drawn: the answer
    /// comes from the last look, which is made when the name of the command
    /// changes and when the profiles are read, saved or deleted.
    private(set) var foreignCommandPath: String?

    /// Looks the name of the command up in the folder of the launchers.
    ///
    /// The name of a profile that is not written yet belongs to no one, so
    /// the launcher of that name may be there without being a problem.
    private func refreshForeignCommandPath() {
        foreignCommandPath = store.foreignCommandPath(for: command.slug, ownedBy: currentProfile?.slug)
    }

    // MARK: - Saving

    /// Saves the profile. Returns `true` when everything worked.
    @discardableResult
    func save() -> Bool {
        guard var draft else { return false }
        let previousProfile = currentProfile
        // The key the user typed, before the field is cleared by the save.
        // A Claude subscription profile has no address and no key: Claude Code signs in by itself.
        if ProviderEndpoint.usesCliLogin(draft) {
            draft.baseURL = ""
            keyInput = ""
        }
        let typedKey = keyInput
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
            if let old = result.renamedFrom {
                // The terminal and the tab of the profile follow its new name.
                terminals.rename(from: old, to: result.slug)
                if let tab = detailTabs[old] {
                    detailTabs[old] = nil
                    detailTabs[result.slug] = tab
                }
                if let tab = selectedSessions[old] {
                    selectedSessions[old] = nil
                    selectedSessions[result.slug] = tab
                }
            }

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
            // The config folder may have moved with a rename.
            refreshOrchestration()
            // The launcher of the profile was written: the name of the
            // command is looked at again, now that it belongs to this profile.
            refreshForeignCommandPath()
            // A typed key, a new Base URL or auth kind, or a new slug makes the last test describe something else.
            health.profileSaved(old: previousProfile, new: draft, typedKey: typedKey)
            // The key presence and the folders of the menu are looked at again,
            // with the one read of the Keychain that both of them use.
            refreshStoredKeys()
            refreshMenuBarFolders()
            // The counted tokens of the old settings are gone with them.
            forgetUsage(before: previousProfile, after: draft)
            // A profile that was renamed leaves nothing behind in the menu.
            if let previousProfile, previousProfile.slug != draft.slug {
                forgetMenuBarState(for: previousProfile.slug)
            }

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
        let slug = profile.slug
        usageTasks[slug]?.cancel()
        let generation = (usageGenerations[slug] ?? 0) + 1
        usageGenerations[slug] = generation
        usageScanStates.start(slug)
        let scanner = usageScanner
        // The profiles that exist: the entries of the cache of a profile that
        // is gone leave the cache at the start of the next count.
        let knownSlugs = Set(data.profiles.map(\.slug))
        usageTasks[slug] = Task {
            let outcome: Result<UsageResult, Error>
            do {
                outcome = .success(try await scanner.usage(for: profile, knownSlugs: knownSlugs))
            } catch {
                outcome = .failure(error)
            }
            // A newer count replaced this one, and that one owns the state now.
            guard !Task.isCancelled else { return }
            guard usageGenerations[slug] == generation else { return }
            usageScanStates.finish(slug)
            usageTasks[slug] = nil
            // The profile may be gone (deleted or renamed) while the count ran.
            guard data.profiles.contains(where: { $0.slug == slug }) else {
                usageResults[slug] = nil
                usageScanStates.forget(slug)
                return
            }
            switch outcome {
            case .success(let result):
                usageResults[slug] = result
            case .failure(let error):
                report(error)
            }
        }
    }

    /// Stops the count of the profile that is open.
    ///
    /// The numbers of the last count stay: a stopped count shows what it had,
    /// and a note that it was stopped.
    func stopUsage() {
        guard let slug = currentProfile?.slug else { return }
        cancelUsageTask(for: slug)
        usageScanStates.stop(slug)
    }

    /// `true` while the usage of the profile is being counted.
    func isUsageLoading(_ slug: String) -> Bool {
        usageScanStates.isRunning(slug)
    }

    /// `true` when the last count of the profile was stopped.
    func isUsageStopped(_ slug: String) -> Bool {
        usageScanStates.isStopped(slug)
    }

    /// Stops the count of a profile and forgets its numbers. A count that is
    /// stopped must not show its numbers later.
    private func cancelUsage(for slug: String) {
        cancelUsageTask(for: slug)
        usageResults[slug] = nil
        usageScanStates.forget(slug)
    }

    /// Stops the count of a profile without touching its numbers.
    private func cancelUsageTask(for slug: String) {
        usageTasks[slug]?.cancel()
        usageTasks[slug] = nil
        usageGenerations[slug] = (usageGenerations[slug] ?? 0) + 1
        usageScanStates.finish(slug)
    }

    /// A count stays valid while the folder of the profile and its isolation stay the same.
    private func forgetUsage(before previous: Profile?, after saved: Profile) {
        guard let previous else {
            usageResults[saved.slug] = nil
            return
        }
        guard previous.slug != saved.slug || previous.isolate != saved.isolate else { return }
        cancelUsage(for: previous.slug)
        usageResults[saved.slug] = nil
    }

    // MARK: - Actions

    /// Saves the profile and opens a terminal running it.
    func openTerminal() {
        guard save() else { return }
        guard let draft else { return }
        launch(draft, MenuLaunchPlan.profile(draft.slug))
    }

    // MARK: - Orchestration kit

    /// Reads what the kit has in the config folder of the saved profile.
    func refreshOrchestration() {
        guard let profile = currentProfile else {
            orchestration = nil
            return
        }
        orchestration = store.orchestrationStatus(for: profile)
    }

    /// Installs (or updates) the agents and the instructions into the saved profile.
    func installOrchestration() {
        guard let profile = currentProfile else { return }
        do {
            let result = try store.installOrchestration(for: profile)
            status = Status(kind: .success, text: orchestrationText(result, removing: false))
        } catch {
            reportOrchestration(error)
        }
        refreshOrchestration()
    }

    /// Takes the agents and the instructions out of the saved profile.
    func removeOrchestration() {
        guard let profile = currentProfile else { return }
        do {
            let result = try store.removeOrchestration(for: profile)
            status = Status(kind: .success, text: orchestrationText(result, removing: true))
        } catch {
            reportOrchestration(error)
        }
        refreshOrchestration()
    }

    /// Asks before a link to `~/.claude` is replaced with a copy.
    func requestUnshare(_ item: OrchestrationItem) {
        orchestrationUnshare = item
        isConfirmingUnshare = true
    }

    /// Replaces the link with a copy, then installs the kit.
    func confirmUnshare() {
        isConfirmingUnshare = false
        guard let item = orchestrationUnshare, let profile = currentProfile else { return }
        orchestrationUnshare = nil
        do {
            try store.unshareOrchestrationItem(item, for: profile)
        } catch {
            reportOrchestration(error)
            refreshOrchestration()
            return
        }
        installOrchestration()
    }

    func cancelUnshare() {
        isConfirmingUnshare = false
        orchestrationUnshare = nil
    }

    private func orchestrationText(_ result: OrchestrationReport, removing: Bool) -> String {
        switch (result.agents, result.claudeMd) {
        case (.refused, .refused):
            return loc.t("orch.result.nothing")
        case (.done, .refused):
            return loc.t(removing ? "orch.result.removedAgentsOnly" : "orch.result.installedAgentsOnly")
        case (.refused, .done):
            return loc.t(removing ? "orch.result.removedBlockOnly" : "orch.result.installedBlockOnly")
        case (.done, .done):
            return loc.t(removing ? "orch.result.removed" : "orch.result.installed")
        }
    }

    private func reportOrchestration(_ error: Error) {
        switch error as? OrchestrationError {
        case .notIsolated:
            status = Status(kind: .failure, text: loc.t("orch.error.notIsolated"))
        case .homeNotAFolder(let path), .ioFailed(let path):
            status = Status(kind: .failure, text: loc.t("orch.error.io", path))
        case nil:
            report(error)
        }
    }

    // MARK: - Menu bar launcher

    /// Opens a terminal with a saved profile from the menu bar.
    ///
    /// Without a `folder` the profile is opened in its own working directory.
    /// With one it is opened there, and the folder is remembered after the
    /// launch worked.
    func openFromMenu(slug: String, folder: String?) {
        guard let index = data.profiles.firstIndex(where: { $0.slug == slug }) else { return }
        let profile = data.profiles[index]
        let plan: MenuLaunchPlan
        if let folder {
            // A folder with a control character is refused before anything
            // starts: a terminal would act on it before the shell reads the
            // quotes.
            guard FolderPathSafety.isSafe(folder) else {
                reportUnsafeFolder(folder)
                return
            }
            plan = MenuLaunchPlan.folder(slug, folder)
        } else {
            plan = MenuLaunchPlan.profile(slug)
        }
        launch(profile, plan)
    }

    /// Opens the terminal for a plan and remembers the folder when it worked.
    private func launch(_ profile: Profile, _ plan: MenuLaunchPlan) {
        if data.embeddedTerminal {
            launchEmbedded(profile, plan)
            return
        }
        // A second click on the same item is ignored while the first one is
        // still on its way: one click opens one terminal.
        let key = plan.launchKey
        guard launchGuard.begin(key) else { return }
        menuBarError = nil
        let terminal = data.terminal
        let paths = store.paths
        // The command is the one that "Copy command" copies, when it runs from
        // any terminal; without the PATH setup the full path of the launcher is typed.
        refreshPathStatus()
        let shortName = isCommandOnPath
        // The terminal is started off the main thread, so the window keeps responding.
        Task {
            defer { launchGuard.end(key) }
            do {
                try await plan.run(
                    launch: {
                        try await Launcher.launchInBackground(
                            profile: profile,
                            terminal: terminal,
                            paths: paths,
                            workdirOverride: plan.folder,
                            useShortName: shortName
                        )
                    },
                    remember: { folder in
                        // The folder is remembered only now, after the launch
                        // worked. The list is read again here, so that two
                        // launches that overlap keep both folders.
                        remember(folder, for: plan.slug)
                    }
                )
                status = Status(kind: .success, text: loc.t("status.launched", terminal.rawValue, profile.name))
            } catch {
                menuBarError = (error as? ProfileError)?.localizedMessage(loc) ?? loc.t("error.generic")
                report(error)
            }
        }
    }

    /// Runs the profile in the terminal inside the app and shows it.
    ///
    /// Without a folder the profile is shown as it is, and a first tab is
    /// opened when it has none. With a folder (from the menu bar) the tab that
    /// already runs there is shown, or a new tab is opened in that folder.
    private func launchEmbedded(_ profile: Profile, _ plan: MenuLaunchPlan) {
        menuBarError = nil
        let slug = profile.slug
        let tabs = terminals.book.sessions(for: slug)
        do {
            if let folder = plan.folder {
                if let same = tabs.first(where: { $0.state == .running && terminals.folder(for: $0.id) == folder }) {
                    selectedSessions[slug] = same.id
                } else {
                    selectedSessions[slug] = try terminals.open(profile, paths: store.paths, folder: folder)
                    remember(folder, for: slug)
                }
            } else if tabs.isEmpty {
                selectedSessions[slug] = try terminals.open(profile, paths: store.paths, folder: nil)
            }
            showTerminal(of: slug)
            status = Status(kind: .success, text: loc.t("status.embeddedRunning", profile.name))
        } catch {
            menuBarError = (error as? ProfileError)?.localizedMessage(loc) ?? loc.t("error.generic")
            report(error)
        }
    }

    /// Shows the terminal tab of a profile, and the profile itself.
    func showTerminal(of slug: String) {
        setDetailTab(.terminal, for: slug)
        if selectedSlug != slug { selectedSlug = slug }
    }

    // MARK: - Terminal tabs

    /// The tab of a profile that is shown: the one that was chosen, or the first.
    func activeSession(of slug: String) -> TerminalSession? {
        let tabs = terminals.book.sessions(for: slug)
        if let id = selectedSessions[slug], let tab = tabs.first(where: { $0.id == id }) { return tab }
        return tabs.first
    }

    func selectSession(_ id: Int, of slug: String) {
        guard selectedSessions[slug] != id else { return }
        selectedSessions[slug] = id
    }

    /// Opens the first tab when the terminal tab of a profile is shown and it
    /// has none: opening the tab is enough, there is no button to press.
    func startTerminalIfNeeded(of slug: String) {
        guard terminals.book.sessions(for: slug).isEmpty else { return }
        newSession(of: slug)
    }

    /// Opens a new tab for the profile, in the folder of the profile.
    func newSession(of slug: String) {
        guard let profile = data.profiles.first(where: { $0.slug == slug }) else { return }
        do {
            selectedSessions[slug] = try terminals.open(profile, paths: store.paths, folder: nil)
            status = Status(kind: .success, text: loc.t("status.embeddedRunning", profile.name))
        } catch {
            report(error)
        }
    }

    /// What a question about a running tab is for.
    enum TerminalAction: Equatable {
        case restart(Int)
        case close(Int)
    }

    /// The action that waits for the answer of the question about a running process.
    var pendingTerminalAction: TerminalAction?
    var isConfirmingTerminalAction: Bool = false

    /// Starts a tab again. A process that runs is ended, so the question comes first.
    func requestRestart(_ id: Int) {
        ask(.restart(id), running: terminals.book.session(id)?.state == .running)
    }

    /// Closes a tab. A process that runs is ended, so the question comes first.
    func requestClose(_ id: Int) {
        ask(.close(id), running: terminals.book.session(id)?.state == .running)
    }

    private func ask(_ action: TerminalAction, running: Bool) {
        if running {
            pendingTerminalAction = action
            isConfirmingTerminalAction = true
        } else {
            perform(action)
        }
    }

    func confirmTerminalAction() {
        isConfirmingTerminalAction = false
        guard let action = pendingTerminalAction else { return }
        pendingTerminalAction = nil
        perform(action)
    }

    func cancelTerminalAction() {
        isConfirmingTerminalAction = false
        pendingTerminalAction = nil
    }

    private func perform(_ action: TerminalAction) {
        switch action {
        case .restart(let id):
            guard let slug = terminals.book.slug(of: id),
                  let profile = data.profiles.first(where: { $0.slug == slug }) else { return }
            do {
                try terminals.restart(id, profile: profile, paths: store.paths)
            } catch {
                report(error)
            }
        case .close(let id):
            guard let slug = terminals.book.slug(of: id) else { return }
            terminals.close(id)
            if selectedSessions[slug] == id { selectedSessions[slug] = nil }
            // The last tab is closed: back to the settings of the profile.
            if terminals.book.sessions(for: slug).isEmpty {
                setDetailTab(.settings, for: slug)
            }
        }
    }

    /// Puts the folder of a launch that worked into the list of the profile.
    ///
    /// The list of the profile is read again now and not before the launch
    /// started: two launches that overlap both keep their folder.
    private func remember(_ folder: String, for slug: String) {
        guard let index = data.profiles.firstIndex(where: { $0.slug == slug }) else { return }
        var recent = RecentFolders(data.profiles[index].recentDirs)
        recent.add(folder)
        let folders = recent.paths
        guard data.profiles[index].recentDirs != folders else { return }
        data.profiles[index].recentDirs = folders
        // The editor keeps its own copy: update it too, so it does not show as changed.
        if draftIndex == index {
            draft?.recentDirs = folders
        }
        // A failed write is not shown: the recent folders are a convenience.
        try? store.save(data)
        // The menu shows the folder right away, without waiting for the next
        // opening.
        refreshMenuBarFolders()
    }

    /// Shows that a folder was refused, in the status bar and in the menu.
    func reportUnsafeFolder(_ path: String) {
        let error = ProfileError.unsafeFolderToOpen(path)
        menuBarError = error.localizedMessage(loc)
        report(error)
    }

    /// Forgets what the menu bar knows about a profile that is gone.
    ///
    /// A profile that was deleted or renamed leaves nothing behind: the check
    /// of its folders is of a profile that does not exist any more, and its
    /// answer must not be used for a profile that has the same name later.
    private func forgetMenuBarState(for slug: String) {
        slowFolderChecks[slug] = nil
        menuBarFolders[slug] = nil
        menuFolderState.forget(slug: slug)
    }

    /// The entries of the menu bar menu, built from the saved profiles.
    func menuBarEntries() -> [MenuBarModel.Entry] {
        MenuBarModel.entries(
            profiles: data.profiles,
            paths: store.paths,
            keyPresence: { self.keyPresence.state(for: $0) },
            recentFolders: menuBarFolders,
            folderTitle: loc.t("menubar.openInFolder"),
            lastError: menuBarError
        )
    }

    /// Looks up what the menu needs, when the menu opens.
    ///
    /// The folders that still exist and the keys of the profiles are asked for
    /// off the main thread and kept until the next opening, so the menu is
    /// drawn without asking the file system or the Keychain.
    func prepareMenuBar() {
        refreshStoredKeys()
        refreshMenuBarFolders()
    }

    /// Looks up the recent folders that still exist, off the main thread.
    ///
    /// The menu is drawn from the result, never from the file system. A folder
    /// on a volume that does not answer must not hold the menu: the check of
    /// such a profile gets a second, and the folders are shown as they are
    /// until the check is done. The check that took too long goes on in the
    /// background, and the next opening of the menu uses its answer.
    func refreshMenuBarFolders() {
        let profiles = data.profiles
        let known = Set(profiles.map(\.slug))
        // The number of this lookup. The answer of an older lookup is dropped.
        let generation = menuFolderState.begin()
        // The lookup that is running is stopped: its answer is older anyway.
        menuFolderLookup?.cancel()
        menuFolderLookup = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.menuFolderBudget)
            var entries: [String: MenuFolderState.Entry] = [:]
            for profile in profiles {
                if Task.isCancelled { return }
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else {
                    // The budget of the menu is used up: the folders of this
                    // profile are shown as they are.
                    entries[profile.slug] = .unchecked
                    continue
                }
                entries[profile.slug] = await self.checkFolders(of: profile, budget: left)
            }
            if Task.isCancelled { return }
            let lookup = MenuFolderState.Lookup(generation: generation, entries: entries)
            self.menuFolderState.accept(lookup, known: known)
            self.menuBarFolders = self.menuFolderState.folders
        }
    }

    /// The time the menu waits for the folders of the profiles.
    private static let menuFolderBudget: TimeInterval = 1

    /// A check of the folders of one profile that did not finish in time.
    private struct SlowFolderCheck {
        var paths: [String]
        var task: Task<[String], Never>
    }

    /// Checks the folders of one profile, with a budget of time.
    ///
    /// A volume that does not answer must not hold the menu. When the check is
    /// not done in time, the folders are shown as they are, and the check goes
    /// on in the background: the next opening of the menu uses its answer.
    private func checkFolders(of profile: Profile, budget: TimeInterval) async -> MenuFolderState.Entry {
        let paths = RecentFolders(profile.recentDirs).paths
        guard !paths.isEmpty else { return .checked([]) }
        // A check that took too long is kept, so that the next opening of the
        // menu uses its answer right away.
        let work: Task<[String], Never>
        if let slow = slowFolderChecks[profile.slug], slow.paths == paths {
            work = slow.task
        } else {
            slowFolderChecks[profile.slug] = nil
            work = Task.detached(priority: .userInitiated) {
                // The rule of which folders are kept lives in the core.
                var recent = RecentFolders(paths)
                recent.prune(exists: { AppModel.folderExists($0) })
                return recent.paths
            }
        }
        switch await AppModel.withBudget(budget) { await work.value } {
        case .value(let folders):
            slowFolderChecks[profile.slug] = nil
            return .checked(folders)
        case .timeout:
            slowFolderChecks[profile.slug] = SlowFolderCheck(paths: paths, task: work)
            return .unchecked
        }
    }

    /// The answer of a piece of work that had a budget of time.
    private enum Budget<T: Sendable> {
        /// The work is done.
        case value(T)
        /// The budget was over before the work was done.
        case timeout
    }

    /// Waits for the work, but not longer than the budget.
    ///
    /// The work is not waited for when the budget is over: a check of the file
    /// system cannot be stopped, and the menu must not wait for it. The first
    /// answer wins: a late answer is dropped.
    nonisolated private static func withBudget<T: Sendable>(
        _ budget: TimeInterval,
        work: @escaping @Sendable () async -> T
    ) async -> Budget<T> {
        let answer = OneAnswer<T>()
        return await withCheckedContinuation { continuation in
            answer.hold(continuation)
            Task.detached(priority: .userInitiated) {
                answer.finish(.value(await work()))
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                answer.finish(.timeout)
            }
        }
    }

    /// Holds the answer of a piece of work with a budget. The first answer
    /// wins: a late answer is dropped.
    private final class OneAnswer<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Budget<T>, Never>?

        func hold(_ continuation: CheckedContinuation<Budget<T>, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ answer: Budget<T>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: answer)
        }
    }

    /// Whether a folder exists. Recent folders that were removed are left out of the menu.
    nonisolated static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
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

    /// `true` when the short command of a profile runs in a new terminal:
    /// the PATH setup is done (by the app or by hand). Read after `refreshPathStatus()`.
    private var isCommandOnPath: Bool {
        loginShellStatus == .configured || loginShellStatus == .manual
            || loginShellStatus == .partlyConfigured
    }

    private func copyToPasteboard(slug: String) {
        let text = store.paths.command(for: slug)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        refreshPathStatus()
        // Without the PATH setup the short name would not run: say so.
        let onPath = isCommandOnPath
        status = Status(kind: onPath ? .success : .hint,
                        text: loc.t(onPath ? "status.copied" : "status.copiedNoPath", text))
    }

    /// Shows the delete confirmation.
    ///
    /// The text is there right away: it names everything that goes away,
    /// taken from the SAVED profile, because a command name typed but not
    /// saved is not what gets deleted. The size of the config folder is not
    /// asked for here: it is measured away from the main thread, so the
    /// window is never blocked by a folder with many files in it.
    func requestDelete() {
        guard let slug = currentProfile?.slug else { return }
        guard let target = DeleteTarget(index: draftIndex, in: data, paths: store.paths, measure: { _ in nil }) else { return }
        let token = deleteDialog.begin(slug: slug, items: target.items)
        deleteDialogText = DeleteDialogText.message(
            name: target.name,
            items: target.items,
            strings: loc.deleteDialogStrings
        )
        isConfirmingDelete = true
        measureFolderSize(for: token)
    }

    /// Measures the config folder of the profile, away from the main thread.
    ///
    /// The answer is used only when it still belongs to the open question.
    private func measureFolderSize(for token: DeleteDialogState.Token) {
        let url = store.paths.home(for: token.slug)
        Task.detached(priority: .userInitiated) {
            let bytes = DirectorySize.measure(at: url)
            await MainActor.run { self.applyFolderSize(bytes, for: token) }
        }
    }

    /// Puts the size of the config folder into the text of the question.
    ///
    /// A late answer is dropped: the question may be about another profile
    /// now, or it may be closed already. Only the text of the message
    /// changes, never the buttons under it.
    private func applyFolderSize(_ bytes: Int?, for token: DeleteDialogState.Token) {
        guard deleteDialog.apply(bytes: bytes, for: token) else { return }
        guard let name = deleteDialogName else { return }
        deleteDialogText = DeleteDialogText.message(
            name: name,
            items: deleteDialog.items,
            strings: loc.deleteDialogStrings
        )
    }

    /// The name of the profile the confirmation is about.
    private var deleteDialogName: String? {
        guard let slug = deleteDialog.slug else { return nil }
        return data.profiles.first { $0.slug == slug }?.name
    }

    /// Closes the delete confirmation.
    ///
    /// A measurement that is still on its way is dropped: its answer belongs
    /// to a question that is not open any more.
    func cancelDelete() {
        isConfirmingDelete = false
        deleteDialog.cancel()
    }

    /// Removes the profile: the key, the command and the config folder go away.
    func deleteCurrent() {
        guard let index = draftIndex, data.profiles.indices.contains(index) else { return }
        let profile = data.profiles[index]
        let wasLast = data.profiles.count == 1
        // The question is closed: a measurement of it must not come back.
        cancelDelete()

        // The process of the profile ends before its folder goes away.
        terminals.closeAll(profile.slug)
        detailTabs[profile.slug] = nil
        selectedSessions[profile.slug] = nil

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
        // The name of the command may belong to another profile now.
        refreshForeignCommandPath()
        // The profile is gone: an answer of a running check must not come back
        // for it, not even when a profile with the same name is added again.
        health.profileDeleted(slug: profile.slug)
        // The numbers of a profile that is gone are gone with it: a profile
        // that is added again with the same name starts at zero.
        cancelUsage(for: profile.slug)
        do {
            try store.save(data)
        } catch {
            failures.append(.dataFile)
        }
        refreshStoredKeys()

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
        // The profile is gone: the menu must not show it any more. The keys
        // were looked at again above, with the one read of the Keychain.
        forgetMenuBarState(for: profile.slug)
        refreshMenuBarFolders()
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
        guard let draft, !isTestingConnection, !isCheckingHealth else { return }
        let key: String
        do {
            key = try probeKey(for: draft)
        } catch {
            report(error)
            return
        }
        // The settings of the test are the ones of this moment: the answer
        // belongs to them and to no other.
        let saved = currentProfile
        let typedKey = keyInput
        let generation = health.generation(for: draft.slug)
        isTestingConnection = true
        connectionReport = nil
        let token = UUID()
        connectionToken = token
        connectionTask = Task { [weak self, probe] in
            let result = try? await probe.testConnection(profile: draft, key: key)
            guard let self, !Task.isCancelled, self.connectionToken == token else { return }
            self.isTestingConnection = false
            self.connectionReport = result
            // The result also updates the dot of the profile, when it is in the
            // list and the test was made with the saved settings: a typed, not
            // yet stored key says nothing about the saved one.
            if let result,
               HealthBook.canRecordEditorTest(draft: draft, saved: saved, typedKey: typedKey) {
                self.health.record(result.outcome, at: Date(), for: draft, generation: generation)
            }
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
        guard let draft else { return }
        // The list and the check of the profiles do not run at the same time.
        guard canFetchModelList else { return }
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

    // MARK: - Health of the profiles

    /// Reads the stored keys of the profiles, off the main thread.
    ///
    /// The Keychain is asked once for the whole app: the health dot and the
    /// menu bar both read the one map this fills, so the two features never
    /// ask the Keychain twice at the same time.
    ///
    /// Only the existence of a key is asked for: no secret is read and no
    /// request is sent.
    ///
    /// The Keychain is read off the main actor, so a long list of profiles does
    /// not freeze the window. Every read gets a number: a read that comes back
    /// late after a newer one is dropped, so it cannot overwrite the newer one.
    func refreshStoredKeys() {
        let slugs = data.profiles.map(\.slug)
        let keys = store.keys
        let sequence = keyPresence.nextSequence()
        Task { [weak self] in
            let read = await KeyPresence.read(slugs: slugs, keys: keys)
            guard let self else { return }
            // The profiles of this moment: a profile that is gone is not kept.
            self.keyPresence.merge(
                slugs: self.data.profiles.map(\.slug),
                read: read,
                sequence: sequence
            )
        }
    }

    /// The health of a profile at `now`, from its stored key and its last test in this session.
    func healthStatus(for profile: Profile, now: Date) -> HealthStatus {
        // The Keychain could not be read: the dot says so, instead of showing
        // a key that is missing or a key that is there.
        return ProfileHealth.evaluate(
            profile: profile,
            key: keyPresence.state(for: profile.slug),
            lastTest: health.lastTest(for: profile),
            now: now
        )
    }

    /// The state of the dot of a saved profile, for the menu bar.
    func healthState(forSlug slug: String) -> HealthState? {
        guard let profile = data.profiles.first(where: { $0.slug == slug }) else { return nil }
        return healthStatus(for: profile, now: Date()).state
    }

    /// "Delete" in the menu of a row of the sidebar: the profile of the row is
    /// shown, then the same question as the button of the editor is asked.
    func requestDelete(of profile: Profile) {
        if currentProfile?.slug != profile.slug {
            // Unsaved changes of another profile are answered first, as for any switch.
            guard !hasUnsavedChanges else {
                sidebarSelectionChanged(to: profile.slug)
                return
            }
            select(profile)
        }
        requestDelete()
    }

    /// `true` when "Check all connections" can start. The same rule for the
    /// button of the sidebar and for the item of the Profile menu.
    var canCheckAllConnections: Bool {
        !data.profiles.isEmpty && !isCheckingHealth && !isTestingConnection && !isFetchingModels
    }

    /// Asks before the first request of "Check all connections".
    func requestHealthCheck() {
        guard canCheckAllConnections else { return }
        isConfirmingHealthCheck = true
    }

    /// Tests every profile one at a time with its stored key. Only runs after the user confirmed.
    func startHealthCheck() {
        // The check of the profiles and the fetch of the model list do not run
        // at the same time.
        guard healthTask == nil, !isTestingConnection, !isFetchingModels else { return }
        let profiles = data.profiles
        let checker = HealthChecker(keys: store.keys)
        healthProgress = HealthProgress(done: 0, total: profiles.count)
        healthTask = Task { [weak self] in
            guard let self else { return }
            // The generations of the run: an answer of an older setting is
            // refused instead of landing in the dot of the new one.
            let captured = Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.slug, self.health.generation(for: $0.slug))
            })
            await checker.run(
                profiles: profiles,
                currentProfile: { [weak self] slug in
                    self?.data.profiles.first { $0.slug == slug }
                },
                generation: { [weak self] slug in
                    self?.health.generation(for: slug) ?? 0
                }
            ) { step in
                self.applyHealthStep(step, captured: captured)
            }
            self.finishHealthCheck()
        }
    }

    /// Stops the check: the request in flight is cancelled and no further one is sent.
    func stopHealthCheck() {
        healthTask?.cancel()
    }

    private func applyHealthStep(_ step: HealthCheckStep, captured: [String: Int]) {
        switch step {
        case .tested(let slug, let outcome, let at):
            // The profile must still be there and its settings must be the
            // ones the answer was made for: an answer of an older key or of
            // an older URL never reaches the dot of the new settings.
            if let profile = data.profiles.first(where: { $0.slug == slug }),
               let generation = captured[slug] {
                health.record(outcome, at: at, for: profile, generation: generation)
            }
        case .skipped:
            break
        }
        if let progress = healthProgress {
            healthProgress = HealthProgress(done: progress.done + 1, total: progress.total)
        }
    }

    private func finishHealthCheck() {
        healthTask = nil
        healthProgress = nil
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
    /// The files that carry the setup, for the question about removing it.
    /// Read with `refreshPathStatus()`, never while drawing: the question is
    /// part of the window, and reading the files of the shells there would
    /// ask the file system on every pass of the window.
    private(set) var pathFilesText: String = ""
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
        // The files that carry the setup are read here as well: the question
        // about removing them is part of the window, and it must not ask the
        // file system while the window is drawn.
        pathFilesText = setup.managedFiles().map { displayPath($0) }.joined(separator: ", ")
    }

    /// The line the user copies when the app does not edit the login shell.
    var loginManualLine: String { pathSetup.manualLine(for: loginKind) }

    /// The zsh line the user adds by hand when `ZDOTDIR` cannot be read.
    var zshManualLine: String { pathSetup.manualLine(for: .zsh) }

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
    ///
    /// A value that is already the stored one is left alone: SwiftUI writes a
    /// binding back with the value it already has, and writing it again would
    /// change the model, rewrite the scripts and ask for another pass.
    func setLanguage(_ language: AppLanguage) {
        guard SettingsChange.isDifferent(data.language, language) else { return }
        loc.language = language
        data.language = language
        persistSettings()
        regenerateScripts()
    }

    /// Switches the appearance.
    func setAppearance(_ appearance: AppearanceMode) {
        guard SettingsChange.isDifferent(data.appearance, appearance) else { return }
        data.appearance = appearance
        applyAppearance()
        persistSettings()
    }

    /// Switches the terminal application.
    func setTerminal(_ terminal: TerminalApp) {
        guard SettingsChange.isDifferent(data.terminal, terminal) else { return }
        data.terminal = terminal
        persistSettings()
    }

    /// Switches the automatic check of a new version on or off.
    func setAutoCheckUpdates(_ enabled: Bool) {
        guard SettingsChange.isDifferent(data.autoCheckUpdates, enabled) else { return }
        data.autoCheckUpdates = enabled
        persistSettings()
    }

    /// Shows or hides the launcher in the menu bar.
    ///
    /// The launcher is inserted in the menu bar by a binding, so SwiftUI asks
    /// for the value on every pass of the scene. Writing the value that is
    /// already there would save `profiles.json` again and again, and the app
    /// would burn its CPU while the window is open.
    func setShowMenuBar(_ show: Bool) {
        guard SettingsChange.isDifferent(data.showMenuBar, show) else { return }
        data.showMenuBar = show
        persistSettings()
    }

    /// Opens profiles in the terminal inside the app, or in Terminal or iTerm2.
    func setEmbeddedTerminal(_ embedded: Bool) {
        guard SettingsChange.isDifferent(data.embeddedTerminal, embedded) else { return }
        data.embeddedTerminal = embedded
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
            return loc.count("error.envMissingEquals", line, text)
        case .invalidEnvName(let line, let name):
            return loc.count("error.invalidEnvName", line, name)
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
        case .unsafeFolderToOpen(let path):
            // The path is shown with its control characters written out, so
            // that the message cannot act on the terminal that shows it.
            return loc.t("error.unsafeFolder.open", FolderPathSafety.visible(path))
        case .unsafeFolderToSave(let path):
            return loc.t("error.unsafeFolder.save", FolderPathSafety.visible(path))
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
            return loc.count("error.update.httpError", code)
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
