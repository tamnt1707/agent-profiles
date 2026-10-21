import SwiftUI
import ClaudeProfilesCore

/// The settings window (`Cmd+,`).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            general
                .tabItem {
                    Label(model.loc.t("settings.general"), systemImage: "gearshape")
                }
        }
        // The window is tall enough for every section, the updates one
        // included.
        .frame(width: 420, height: 560)
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

            Section(model.loc.t("settings.updates.section")) {
                LabeledContent(model.loc.t("settings.updates.currentVersion")) {
                    Text(model.currentVersionText)
                        .monospacedDigit()
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

    private var autoCheckBinding: Binding<Bool> {
        Binding(get: { model.data.autoCheckUpdates }, set: { model.setAutoCheckUpdates($0) })
    }
}
