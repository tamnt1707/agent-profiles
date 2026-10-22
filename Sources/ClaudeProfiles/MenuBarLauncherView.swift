import AppKit
import SwiftUI
import ClaudeProfilesCore

/// The menu of the menu bar launcher. The entries come from `MenuBarModel`;
/// this view only draws them and passes the clicks on to `AppModel`.
struct MenuBarLauncherView: View {
    /// The id of the main window, so that the menu can bring it back.
    static let mainWindowID = "main"

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let entries = model.menuBarEntries()
        Group {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                entryView(entry)
            }
            Divider()
            Button(model.loc.t("menubar.openApp")) {
                NSApp.activate()
                openWindow(id: Self.mainWindowID)
            }
            Button(model.loc.t("menubar.settings")) {
                NSApp.activate()
                openSettings()
            }
            Divider()
            Button(model.loc.t("menubar.quit")) {
                NSApp.terminate(nil)
            }
        }
        // The keys and the folders are looked up here, once per opening of the
        // menu, and not while the menu is drawn.
        .onAppear { model.prepareMenuBar() }
    }

    @ViewBuilder
    private func entryView(_ entry: MenuBarModel.Entry) -> some View {
        switch entry {
        case .profile(let profile):
            // One click: the profile is opened in its own working directory.
            Button {
                model.openFromMenu(slug: profile.slug, folder: nil)
            } label: {
                profileLabel(profile)
            }
            .disabled(!profile.isEnabled)

        case .openInFolder(let menu):
            // The submenu with the profiles and their folders is a group of
            // its own.
            Divider()
            Menu {
                ForEach(menu.profiles, id: \.slug) { profile in
                    Menu {
                        Section(model.loc.t("menubar.recentFolders")) {
                            ForEach(profile.recentFolders, id: \.path) { folder in
                                Button {
                                    model.openFromMenu(slug: profile.slug, folder: folder.path)
                                } label: {
                                    Text(verbatim: folder.display)
                                }
                            }
                        }
                        Button(model.loc.t("menubar.chooseFolder")) {
                            chooseFolder(for: profile.slug)
                        }
                    } label: {
                        Text(profile.name)
                    }
                    .disabled(!profile.isEnabled)
                }
            } label: {
                Text(menu.title)
            }

        case .noProfiles:
            Button(model.loc.t("sidebar.empty.title")) {}
                .disabled(true)

        case .lastError(let message):
            Button(message) {}
                .disabled(true)
        }
    }

    /// The name, then the command in secondary style. A profile without its key
    /// gets the "no key" hint.
    private func profileLabel(_ profile: MenuBarModel.ProfileEntry) -> Text {
        var label = Text(profile.name) + Text(verbatim: "  \(profile.command)").foregroundStyle(.secondary)
        if profile.hint == .noKey {
            label = label + Text(verbatim: "  — \(model.loc.t("menubar.noKey"))").foregroundStyle(.secondary)
        }
        return label
    }

    /// Asks for a folder and opens the profile in it.
    private func chooseFolder(for slug: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = model.loc.t("menubar.panel.message")
        panel.prompt = model.loc.t("menubar.panel.prompt")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A folder with a control character is refused: the terminal would act
        // on it before the shell reads the quotes.
        guard FolderPathSafety.isSafe(url.path) else {
            model.reportUnsafeFolder(url.path)
            return
        }
        model.openFromMenu(slug: slug, folder: url.path)
    }
}
