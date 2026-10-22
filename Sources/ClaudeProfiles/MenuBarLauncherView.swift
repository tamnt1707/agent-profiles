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
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: Self.mainWindowID)
            }
            Button(model.loc.t("menubar.settings")) {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            Button(model.loc.t("menubar.quit")) {
                NSApp.terminate(nil)
            }
        }
        // The key lookup happens here, once per opening of the menu.
        .onAppear { model.refreshProfilesWithKey() }
    }

    @ViewBuilder
    private func entryView(_ entry: MenuBarModel.Entry) -> some View {
        switch entry {
        case .profile(let profile):
            Menu {
                Button(model.loc.t("actions.openTerminal")) {
                    model.openFromMenu(slug: profile.slug, folder: nil)
                }
                if !profile.recentFolders.isEmpty {
                    Section(model.loc.t("menubar.recentFolders")) {
                        ForEach(profile.recentFolders, id: \.path) { folder in
                            Button(folder.display) {
                                model.openFromMenu(slug: profile.slug, folder: folder.path)
                            }
                        }
                    }
                }
                Button(model.loc.t("menubar.openInFolder")) {
                    chooseFolder(for: profile.slug)
                }
            } label: {
                profileLabel(profile)
            }
            .disabled(!profile.isEnabled)

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
        var label = Text(profile.name) + Text("  \(profile.command)").foregroundStyle(.secondary)
        if profile.hint == .noKey {
            label = label + Text("  — \(model.loc.t("menubar.noKey"))").foregroundStyle(.secondary)
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
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.openFromMenu(slug: slug, folder: url.path)
    }
}
