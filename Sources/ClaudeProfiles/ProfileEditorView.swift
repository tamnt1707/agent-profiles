import AppKit
import SwiftUI
import ClaudeProfilesCore

/// The form that edits one profile.
struct ProfileEditorView: View {
    @Bindable var model: AppModel
    @State private var presetID = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                providerSection
                modelsSection
                environmentSection
                workspaceSection
                isolationSection
            }
            .formStyle(.grouped)

            Divider()
            actionBar
            StatusBar(model: model)
        }
        .alert(model.loc.t("actions.confirmDelete"), isPresented: $model.isConfirmingDelete) {
            Button(model.loc.t("actions.delete"), role: .destructive) { model.deleteCurrent() }
            Button(model.loc.t("actions.cancel"), role: .cancel) { model.isConfirmingDelete = false }
        } message: {
            Text(model.loc.t("actions.deleteMessage", model.draft?.name ?? ""))
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
                TextField(model.loc.t("editor.name.label"), text: text(\.name), prompt: Text(model.loc.t("editor.name.hint")))
                    .textFieldStyle(.roundedBorder)
                let slug = Slug.slugify(model.draft?.name ?? "")
                if !slug.isEmpty {
                    Text(model.loc.t("editor.slug.hint", slug))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

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
                    HStack(spacing: 8) {
                        Group {
                            if model.revealKey {
                                TextField("", text: $model.keyInput)
                            } else {
                                SecureField("", text: $model.keyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            model.revealKey.toggle()
                        } label: {
                            Image(systemName: model.revealKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(model.loc.t(model.revealKey ? "editor.apiKey.hide" : "editor.apiKey.show"))
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
        }
    }

    private var modelsSection: some View {
        Section(model.loc.t("editor.models.section")) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(model.loc.t("editor.model.label"), text: text(\.model), prompt: Text(model.loc.t("editor.model.hint")))
                    .textFieldStyle(.roundedBorder)
            }

            DisclosureGroup(model.loc.t("editor.models.disclosure")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.loc.t("editor.models.help"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent(model.loc.t("editor.model.opus")) {
                        TextField("", text: text(\.opusModel))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(model.loc.t("editor.model.sonnet")) {
                        TextField("", text: text(\.sonnetModel))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(model.loc.t("editor.model.haiku")) {
                        TextField("", text: text(\.haikuModel))
                            .textFieldStyle(.roundedBorder)
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

            Button(model.loc.t("actions.openTerminal")) { model.openTerminal() }
                .keyboardShortcut("r", modifiers: .command)

            Button(model.loc.t("actions.copyCommand")) { model.copyCommand() }
                .disabled(model.draft == nil)

            if model.hasUnsavedChanges {
                Label(model.loc.t("actions.unsaved"), systemImage: "circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            Spacer()

            Button(model.loc.t("actions.reveal")) { model.revealFolder() }

            Button(role: .destructive) {
                model.requestDelete()
            } label: {
                Label(model.loc.t("actions.delete"), systemImage: "trash")
            }
            .disabled(model.draftIndex == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    private var isolationPath: String {
        let slug = Slug.slugify(model.draft?.name ?? "")
        return model.store.paths.home(for: slug).path
    }

    private func authLabel(_ kind: AuthKind) -> String {
        switch kind {
        case .bearer: return model.loc.t("editor.auth.bearer")
        case .apiKey: return model.loc.t("editor.auth.apiKey")
        case .none: return model.loc.t("editor.auth.none")
        }
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
