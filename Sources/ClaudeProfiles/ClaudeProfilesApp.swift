import SwiftUI
import ClaudeProfilesCore

@main
@MainActor
struct ClaudeProfilesApp: App {
    @State private var model: AppModel

    init() {
        // A tiny diagnostic mode: it prints where the localized strings come
        // from and exits. Used by build-mac.sh to check the installed app.
        if CommandLine.arguments.contains("--self-test") {
            Self.runSelfTest()
        }
        _model = State(initialValue: AppModel())
    }

    private static func runSelfTest() -> Never {
        let english = Loc(language: .en)
        let vietnamese = Loc(language: .vi)
        print("resource bundle: \(ResourceLocator.bundle.bundlePath)")
        print("en.lproj: \(english.t("actions.save"))")
        print("vi.lproj: \(vietnamese.t("actions.save"))")
        print("script header: \(english.scriptStrings.headerTemplate)")
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(model.colorScheme)
                .onAppear { model.applyAppearance() }
        }
        .defaultSize(width: 920, height: 640)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.colorScheme)
                .onAppear { model.applyAppearance() }
        }
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

        CommandMenu(model.loc.t("menu.profile")) {
            Button(model.loc.t("actions.openTerminal")) { model.openTerminal() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.draft == nil)

            Button(model.loc.t("actions.copyCommand")) { model.copyCommand() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.draft == nil)

            Divider()

            Button(model.loc.t("actions.reveal")) { model.revealFolder() }

            Button(model.loc.t("actions.delete")) { model.requestDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.draftIndex == nil)
        }
    }
}
