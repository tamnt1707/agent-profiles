import SwiftUI
import AgentProfilesCore

/// The settings window (`Cmd+,`).
struct SettingsView: View {
    @Bindable var model: AppModel
    /// The shell whose setup waits for the confirmation of its removal.
    @State private var shellToRemove: ShellKind?

    var body: some View {
        TabView {
            general
                .tabItem {
                    Label(model.loc.t("settings.general"), systemImage: "gearshape")
                }
        }
        // The window is tall enough for every section, the updates one
        // included.
        .frame(width: 420, height: 700)
    }

    private var general: some View {
        Form {
            Section(model.loc.t("settings.language.section")) {
                Picker(model.loc.t("settings.language"), selection: languageBinding) {
                    Text(model.loc.t("settings.language.system")).tag(AppLanguage.system)
                    Text(model.loc.t("settings.language.en")).tag(AppLanguage.en)
                    Text(model.loc.t("settings.language.vi")).tag(AppLanguage.vi)
                }
                .pickerStyle(.radioGroup)
            }

            Section(model.loc.t("settings.appearance.section")) {
                Picker(model.loc.t("settings.appearance"), selection: appearanceBinding) {
                    Text(model.loc.t("settings.appearance.system")).tag(AppearanceMode.system)
                    Text(model.loc.t("settings.appearance.light")).tag(AppearanceMode.light)
                    Text(model.loc.t("settings.appearance.dark")).tag(AppearanceMode.dark)
                }
                .pickerStyle(.radioGroup)
            }

            Section(model.loc.t("settings.terminal.section")) {
                Picker(model.loc.t("settings.terminal"), selection: terminalBinding) {
                    Text(model.loc.t("settings.terminal.terminal")).tag(TerminalApp.terminal)
                    Text(model.loc.t("settings.terminal.iterm")).tag(TerminalApp.iTerm)
                }
                .pickerStyle(.radioGroup)
            }

            Section(model.loc.t("menubar.section")) {
                Toggle(model.loc.t("menubar.show"), isOn: menuBarBinding)
            }

            Section(model.loc.t("pathSetup.section")) {
                ForEach(ShellKind.supported, id: \.self) { shell in
                    shellRow(shell)
                }
                if !model.loginKind.isSupported {
                    Text(model.loc.t("pathSetup.unsupportedBar", model.loginKind.displayName, model.loginManualLine))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.loc.t("pathSetup.copyLine")) { model.copyLoginLine() }
                }
                if let message = model.pathSetupMessage {
                    Text(message.text)
                        .font(.footnote)
                        .foregroundStyle(message.kind == .failure ? Color(nsColor: .systemRed) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(model.loc.t("pathSetup.showZshrc")) { model.revealZshrc() }
            }

            Section(model.loc.t("settings.updates.section")) {
                LabeledContent(model.loc.t("settings.updates.currentVersion")) {
                    Text(model.currentVersionText)
                        .monospacedDigit()
                }
                // The repository is only known when the updater may run, so the
                // row appears together with the button that uses it.
                if model.updater.isEnabled {
                    LabeledContent(model.loc.t("settings.updates.repository")) {
                        Text(model.updateRepositoryText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                LabeledContent(model.loc.t("settings.updates.lastChecked")) {
                    Text(model.lastCheckedText)
                }
                Toggle(model.loc.t("settings.updates.autoCheck"), isOn: autoCheckBinding)
                Button(model.loc.t("settings.updates.checkNow")) {
                    Task { await model.checkForUpdates(manual: true) }
                }
                .disabled(!model.updater.isEnabled || model.updater.isBusy)

                if let reason = model.updater.disabledReason {
                    Text(model.loc.t(disabledKey(for: reason)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPathStatus() }
        .alert(
            model.loc.t("pathSetup.remove.title", shellToRemove?.displayName ?? ""),
            isPresented: Binding(
                get: { shellToRemove != nil },
                set: { shown in
                    guard !shown, shellToRemove != nil else { return }
                    shellToRemove = nil
                }
            )
        ) {
            Button(model.loc.t("pathSetup.remove"), role: .destructive) {
                if let shell = shellToRemove {
                    model.pathSetupMessage = model.removePathSetup(for: shell)
                }
                shellToRemove = nil
            }
            Button(model.loc.t("actions.cancel"), role: .cancel) { shellToRemove = nil }
        } message: {
            Text(model.loc.t("pathSetup.remove.message"))
        }
    }

    /// One shell of the Terminal commands section: its state and its buttons.
    @ViewBuilder
    private func shellRow(_ shell: ShellKind) -> some View {
        let status = model.shellStatuses[shell] ?? .notConfigured
        LabeledContent(shell.displayName) {
            HStack(spacing: 8) {
                Text(statusText(status, shell))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                if status == .notConfigured || status == .partlyConfigured {
                    Button(model.loc.t("pathSetup.add")) {
                        model.pathSetupMessage = model.addPathSetup(for: shell)
                    }
                    .controlSize(.small)
                }
                let removable = status == .configured || status == .partlyConfigured
                    || (status == .unresolvedZdotdir && model.zshRemovableWhileUnresolved)
                if removable {
                    Button(model.loc.t("pathSetup.remove")) { shellToRemove = shell }
                        .controlSize(.small)
                }
            }
        }
    }

    private func statusText(_ status: ShellStatus, _ shell: ShellKind) -> String {
        switch status {
        case .configured: return model.loc.t("pathSetup.status.configured")
        case .partlyConfigured:
            if let stray = model.shellStrayFiles[shell] {
                return model.loc.t("pathSetup.status.stray", stray)
            }
            return model.loc.t("pathSetup.status.partly")
        case .manual: return model.loc.t("pathSetup.status.manual")
        case .notConfigured: return model.loc.t("pathSetup.status.notConfigured")
        case .damaged: return model.loc.t("pathSetup.status.damaged", model.shellDamagedFiles[shell] ?? "")
        case .unsupported: return model.loc.t("pathSetup.status.unsupported")
        case .unresolvedZdotdir: return model.loc.t("pathSetup.status.zdotdir", model.zshManualLine)
        }
    }

    /// The sentence that explains why the updater is turned off.
    private func disabledKey(for reason: UpdateConfiguration.DisabledReason) -> String {
        switch reason {
        case .noVersion: return "update.disabled.version"
        case .noRepo: return "update.disabled.repo"
        case .noPublicKey: return "update.disabled.key"
        }
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { model.data.language }, set: { model.setLanguage($0) })
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(get: { model.data.appearance }, set: { model.setAppearance($0) })
    }

    private var terminalBinding: Binding<TerminalApp> {
        Binding(get: { model.data.terminal }, set: { model.setTerminal($0) })
    }

    private var menuBarBinding: Binding<Bool> {
        Binding(get: { model.data.showMenuBar }, set: { model.setShowMenuBar($0) })
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(get: { model.data.autoCheckUpdates }, set: { model.setAutoCheckUpdates($0) })
    }
}
