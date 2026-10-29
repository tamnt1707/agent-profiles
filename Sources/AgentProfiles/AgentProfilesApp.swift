import SwiftUI
import AgentProfilesCore

/// Asks before the app quits while a profile still runs in its terminal.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once the model exists.
    static var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.terminals.runningCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.loc.t("quit.title")
        alert.informativeText = model.loc.count("quit.message", model.terminals.runningCount)
        alert.addButton(withTitle: model.loc.t("quit.confirm"))
        alert.addButton(withTitle: model.loc.t("actions.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        model.terminals.terminateAll()
        return .terminateNow
    }
}

@main
@MainActor
struct AgentProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        // A tiny diagnostic mode: it prints where the localized strings come
        // from and exits. Used by build-mac.sh to check the installed app.
        if CommandLine.arguments.contains("--self-test") {
            Self.runSelfTest()
        }
        let model = AppModel()
        AppDelegate.model = model
        _model = State(initialValue: model)
    }

    private static func runSelfTest() -> Never {
        let english = Loc(language: .en)
        let vietnamese = Loc(language: .vi)
        print("resource bundle: \(ResourceLocator.bundle.bundlePath)")
        print("en.lproj: \(english.t("actions.save"))")
        print("vi.lproj: \(vietnamese.t("actions.save"))")
        print("script header: \(english.scriptStrings.headerTemplate)")
        // What the updater knows about this build.
        let update = UpdateConfiguration.current()
        print("update repo: \(update.repo)")
        print("update version: \(update.versionText)")
        print("update enabled: \(update.isEnabled)")
        if let reason = update.disabledReason {
            print("update disabled: \(reason.rawValue)")
        }
        exit(0)
    }

    var body: some Scene {
        // A single window: opening it again brings the same window forward
        // instead of making a second one that would share the draft.
        Window(Text(model.loc.t("app.title")), id: MenuBarLauncherView.mainWindowID) {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 480)
                .preferredColorScheme(model.colorScheme)
                .onAppear { model.applyAppearance() }
                .task { await model.checkForUpdatesAutomatically() }
        }
        .defaultSize(width: 920, height: 640)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.colorScheme)
                .onAppear { model.applyAppearance() }
        }

        // The launcher in the menu bar. The "Show in the menu bar" setting inserts or removes it.
        MenuBarExtra(model.loc.t("app.title"), systemImage: "terminal", isInserted: menuBarBinding) {
            MenuBarLauncherView(model: model)
        }
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.data.showMenuBar }, set: { model.setShowMenuBar($0) })
    }
}

/// The menu bar commands.
struct AppCommands: Commands {
    @Bindable var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.loc.t("sidebar.add")) { model.newProfile() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button(model.loc.t("actions.save")) { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.draft == nil)
        }

        // The menu of the app itself: "Agent Profiles > Check for Updates…".
        CommandGroup(replacing: .appInfo) {
            Button(model.loc.t("menu.checkForUpdates")) {
                Task { await model.checkForUpdates(manual: true) }
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!model.updater.isEnabled || model.updater.isBusy)

            Divider()

            Button(model.loc.t("menu.about")) { NSApp.orderFrontStandardAboutPanel(nil) }
        }

        CommandMenu(model.loc.t("menu.profile")) {
            Button(model.loc.t("actions.openTerminal")) { model.openTerminal() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.draft == nil)

            Button(model.loc.t("actions.copyCommand")) { model.copyCommand() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.draft == nil)

            Divider()

            Button(model.loc.t("actions.reveal")) { model.revealFolder() }

            Divider()

            Button(model.loc.t("sidebar.checkAll.menu")) { model.requestHealthCheck() }
                .disabled(!model.canCheckAllConnections)

            Divider()

            Button(model.loc.t("actions.delete")) { model.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.draftIndex == nil)
        }
    }
}
