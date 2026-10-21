import AppKit
import SwiftUI
import ClaudeProfilesCore

/// The form that edits one profile.
struct ProfileEditorView: View {
    @Bindable var model: AppModel
    @State private var presetID = ""

    var body: some View {
        Form {
            providerSection
            modelsSection
            environmentSection
            workspaceSection
            isolationSection
        }
        .formStyle(.grouped)
        // Without an explicit minimum the grouped form asks for the height of
        // all its sections, which grows the split view past the window.
        .frame(minHeight: 200, maxHeight: .infinity)
        // The bars live in a bottom safe-area inset, so the form is the only
        // part that scrolls and the bars stay pinned to the window bottom.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                actionBar
                StatusBar(model: model)
            }
            .background(.bar)
        }
        .alert(model.loc.t("actions.confirmDelete"), isPresented: $model.isConfirmingDelete) {
            Button(model.loc.t("delete.button"), role: .destructive) { model.deleteCurrent() }
            Button(model.loc.t("actions.cancel"), role: .cancel) { model.isConfirmingDelete = false }
        } message: {
            Text(verbatim: model.deleteDialogMessage)
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section(model.loc.t("editor.provider.section")) {
            if model.draftIndex == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(model.loc.t("editor.preset.label"), selection: $presetID) {
                        Text(model.loc.t("editor.preset.choose")).tag("")
                        ForEach(ProviderPreset.all) { preset in
                            Text(model.loc.t("preset.\(preset.id)")).tag(preset.id)
                        }
                    }
                    .onChange(of: presetID) { _, id in
                        guard let preset = ProviderPreset.all.first(where: { $0.id == id }) else { return }
                        model.apply(preset: preset)
                    }
                    Text(model.loc.t("editor.preset.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField(model.loc.t("editor.name.label"), text: nameBinding(), prompt: Text(model.loc.t("editor.name.hint")))
                    .textFieldStyle(.roundedBorder)
            }

            commandSection

            VStack(alignment: .leading, spacing: 4) {
                TextField(model.loc.t("editor.baseURL.label"), text: text(\.baseURL), prompt: Text(model.loc.t("editor.baseURL.hint")))
                    .textFieldStyle(.roundedBorder)
            }

            Picker(model.loc.t("editor.auth.label"), selection: authBinding()) {
                ForEach(AuthKind.allCases, id: \.self) { kind in
                    Text(authLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if model.draft?.auth != AuthKind.none {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent(model.loc.t("editor.apiKey.label")) {
                    HStack(spacing: 8) {
                        Group {
                            if model.revealKey {
                                TextField(model.loc.t("editor.apiKey.label"), text: $model.keyInput)
                            } else {
                                SecureField(model.loc.t("editor.apiKey.label"), text: $model.keyInput)
                            }
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)

                        Button {
                            model.revealKey.toggle()
                        } label: {
                            Image(systemName: model.revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(model.loc.t(model.revealKey ? "editor.apiKey.hide" : "editor.apiKey.show"))
                    }
                    }

                    if model.hasStoredKey {
                        Label(model.loc.t("editor.apiKey.stored"), systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.loc.t("editor.apiKey.hint"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button(model.isTestingConnection ? model.loc.t("editor.test.running") : model.loc.t("editor.test.button")) {
                        model.testConnection()
                    }
                    .disabled(model.isTestingConnection)
                    .help(model.loc.t("editor.test.help"))
                    if model.isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let report = model.connectionReport {
                    ProbeResultLine(loc: model.loc, outcome: report.outcome, providerMessage: report.providerMessage)
                }
            }
        }
    }

    // MARK: - Command name

    /// The editable command name: the fixed `claude-` prefix and the slug.
    @ViewBuilder
    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(model.loc.t("editor.command.label")) {
                HStack(spacing: 8) {
                    HStack(spacing: 0) {
                        Text("claude-")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                        TextField(model.loc.t("editor.command.label"), text: commandBinding(), prompt: Text(model.loc.t("editor.command.hint")))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            // Left aligned, so the text and its placeholder start right after "claude-".
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 6)
                    }
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                    if model.command.mode == .custom {
                        Button(model.loc.t("editor.command.reset")) {
                            model.resetCommandToAuto()
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Text(model.command.mode == .auto
                 ? model.loc.t("editor.command.auto")
                 : model.loc.t("editor.command.custom"))
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.command.hasNormalizedPreview {
                Text(model.loc.t("editor.command.normalized", model.command.normalizedInput))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let issue = model.commandIssue {
                Label(issue.localizedMessage(model.loc), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .textSelection(.enabled)
            }
        }
    }

    private var modelsSection: some View {
        Section(model.loc.t("editor.models.section")) {
            LabeledContent(model.loc.t("editor.model.label")) {
                ModelComboField(
                    model: model,
                    title: model.loc.t("editor.model.label"),
                    prompt: model.loc.t("editor.model.hint"),
                    text: text(\.model)
                )
            }

            DisclosureGroup(model.loc.t("editor.models.disclosure")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.loc.t("editor.models.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent(model.loc.t("editor.model.opus")) {
                        ModelComboField(model: model, title: model.loc.t("editor.model.opus"), text: text(\.opusModel))
                    }
                    LabeledContent(model.loc.t("editor.model.sonnet")) {
                        ModelComboField(model: model, title: model.loc.t("editor.model.sonnet"), text: text(\.sonnetModel))
                    }
                    LabeledContent(model.loc.t("editor.model.haiku")) {
                        ModelComboField(model: model, title: model.loc.t("editor.model.haiku"), text: text(\.haikuModel))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var environmentSection: some View {
        Section(model.loc.t("editor.env.section")) {
            DisclosureGroup(model.loc.t("editor.env.disclosure")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.loc.t("editor.env.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextEditor(text: text(\.extraEnv))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var workspaceSection: some View {
        Section(model.loc.t("editor.workspace.section")) {
            HStack(spacing: 8) {
                TextField(model.loc.t("editor.workdir.label"), text: text(\.workdir), prompt: Text(model.loc.t("editor.workdir.hint")))
                    .textFieldStyle(.roundedBorder)
                Button(model.loc.t("editor.workdir.choose")) {
                    chooseDirectory()
                }
            }
        }
    }

    private var isolationSection: some View {
        Section(model.loc.t("editor.isolation.section")) {
            Toggle(model.loc.t("editor.isolate.toggle"), isOn: bool(\.isolate))
                .help(model.loc.t("editor.isolate.help", isolationPath))

            Toggle(model.loc.t("editor.share.toggle"), isOn: bool(\.shareFromDefault))
                .disabled(model.draft?.isolate != true)

            Text(model.loc.t("editor.isolation.help"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(model.loc.t("actions.save")) { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.commandIssue != nil)

            Button(model.loc.t("actions.openTerminal")) { model.openTerminal() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.commandIssue != nil)

            Button(model.loc.t("actions.copyCommand")) { model.copyCommand() }
                .disabled(model.draft == nil)

            if model.hasUnsavedChanges {
                Label(model.loc.t("actions.unsaved"), systemImage: "circle.fill")
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Spacer()

            Button {
                model.revealFolder()
            } label: {
                Label(model.loc.t("actions.reveal"), systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help(model.loc.t("actions.reveal"))

            Button(role: .destructive) {
                model.requestDelete()
            } label: {
                Label(model.loc.t("actions.delete"), systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .help(model.loc.t("actions.delete"))
            .disabled(model.draftIndex == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    /// The folder of the profile, using the command name that is edited.
    private var isolationPath: String {
        let slug = model.command.slug.isEmpty ? (model.draft?.slug ?? "") : model.command.slug
        return model.store.paths.home(for: slug).path
    }

    private func authLabel(_ kind: AuthKind) -> String {
        switch kind {
        case .bearer: return model.loc.t("editor.auth.bearer")
        case .apiKey: return model.loc.t("editor.auth.apiKey")
        case .none: return model.loc.t("editor.auth.none")
        }
    }

    /// The name of the profile: in auto mode the command follows it.
    private func nameBinding() -> Binding<String> {
        Binding(
            get: { model.draft?.name ?? "" },
            set: { model.setName($0) }
        )
    }

    /// The slug of the command name.
    private func commandBinding() -> Binding<String> {
        Binding(
            get: { model.command.input },
            set: { model.setCommandInput($0) }
        )
    }

    private func text(_ keyPath: WritableKeyPath<Profile, String>) -> Binding<String> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? "" },
            set: { model.draft?[keyPath: keyPath] = $0 }
        )
    }

    private func bool(_ keyPath: WritableKeyPath<Profile, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? false },
            set: { model.draft?[keyPath: keyPath] = $0 }
        )
    }

    private func authBinding() -> Binding<AuthKind> {
        Binding(
            get: { model.draft?.auth ?? .bearer },
            set: { model.draft?.auth = $0 }
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.draft?.workdir ?? "")
        if panel.runModal() == .OK, let url = panel.url {
            model.draft?.workdir = url.path
        }
    }
}

/// The status line at the bottom of the window.
struct StatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var message: String {
        if let status = model.status {
            return status.text
        }
        return model.loc.t("status.pathHint", model.store.paths.binDir.path)
    }

    private var icon: String {
        switch model.status?.kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .hint: return "info.circle"
        case nil: return "info.circle"
        }
    }

    private var color: Color {
        switch model.status?.kind {
        case .success: return Color(nsColor: .systemGreen)
        case .failure: return Color(nsColor: .systemRed)
        case .hint: return Color(nsColor: .secondaryLabelColor)
        case nil: return Color(nsColor: .secondaryLabelColor)
        }
    }
}
