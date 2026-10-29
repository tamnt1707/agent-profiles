import SwiftUI
import AgentProfilesCore

/// The settings page of the default setup (`~/.claude`). It has nothing to edit:
/// Claude Code keeps its own settings. The page shows where it lives and tests
/// that the CLI answers.
struct DefaultSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section(model.loc.t("default.section")) {
                Text(model.loc.t("default.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent(model.loc.t("default.folder")) {
                    Text(model.store.paths.defaultClaudeDir.path)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                AccountView(model: model, profile: .defaultClaude)
                HStack(spacing: 12) {
                    Button(model.loc.t("actions.reveal")) { model.revealFolder(for: .defaultClaude) }
                    Button(model.loc.t("default.test")) { model.checkDefaultConnection() }
                        .disabled(model.isCheckingHealth || model.isTestingConnection)
                    if model.isCheckingHealth {
                        ProgressView().controlSize(.small)
                    }
                }
                if let record = model.health.lastTest(for: .defaultClaude) {
                    ProbeResultLine(loc: model.loc, outcome: record.outcome, providerMessage: nil)
                }
            }
            HeartbeatSection(model: model)
        }
        .formStyle(.grouped)
        .frame(minHeight: 200, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button(model.loc.t("actions.save")) { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasUnsavedChanges)
                    Spacer()
                }
                .padding(10)
                StatusBar(model: model)
            }
            .background(.bar)
        }
    }
}
