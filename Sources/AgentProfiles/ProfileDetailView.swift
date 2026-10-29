import SwiftUI
import AgentProfilesCore

/// The right side of the window for one profile: its settings or its terminal.
///
/// The terminal of a profile keeps running while another profile is shown, so
/// the tab bar says which profile has a process and the sidebar marks it.
struct ProfileDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // A profile that was never saved has no terminal to show.
            if let slug = model.currentProfile?.slug {
                tabBar(slug)
                Divider()
                if model.detailTab(for: slug) == .terminal {
                    TerminalPane(model: model, slug: slug)
                } else {
                    ProfileEditorView(model: model)
                }
            } else {
                ProfileEditorView(model: model)
            }
        }
        // The pane is as big as the window gives it, and starts at the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tabBar(_ slug: String) -> some View {
        let state = model.terminals.book.state(for: slug)
        return HStack {
            Picker("", selection: Binding(
                get: { model.detailTab(for: slug) },
                set: { model.setDetailTab($0, for: slug) }
            )) {
                Text(model.loc.t("terminal.tab.settings")).tag(AppModel.DetailTab.settings)
                Label(model.loc.t("terminal.tab.terminal"), systemImage: state == .running ? "circle.fill" : "terminal")
                    .tag(AppModel.DetailTab.terminal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The terminal tab: the terminal of the profile with a bar under it.
struct TerminalPane: View {
    @Bindable var model: AppModel
    let slug: String

    var body: some View {
        content
            // The tab is open and nothing runs yet: run the profile.
            .task(id: slug) { model.startTerminalIfNeeded(of: slug) }
    }

    @ViewBuilder
    private var content: some View {
        // The views are not observed, the book is: reading it draws the pane
        // again when a session starts or ends.
        let _ = model.terminals.book.state(for: slug)
        if let terminal = model.terminals.view(for: slug) {
            VStack(spacing: 0) {
                // One container for each profile: the terminal is put into it again.
                EmbeddedTerminalView(terminal: terminal)
                    .id(slug)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bar
            }
        } else {
            ContentUnavailableView {
                Label(model.loc.t("terminal.empty.title"), systemImage: "terminal")
            } description: {
                Text(model.loc.t("terminal.empty.message"))
            } actions: {
                Button(model.loc.t("terminal.run")) { model.restartTerminal(of: slug) }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var bar: some View {
        let state = model.terminals.book.state(for: slug)
        return HStack(spacing: 10) {
            Label(stateText(state), systemImage: state == .running ? "circle.fill" : "stop.circle")
                .font(.callout)
                .foregroundStyle(state == .running ? Color(nsColor: .systemGreen) : .secondary)
            if let folder = model.terminals.folder(for: slug) {
                Text(model.loc.t("terminal.folder", folder))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if state == .running {
                Button(model.loc.t("terminal.stop")) { model.stopTerminal(of: slug) }
            } else {
                Button(model.loc.t("terminal.restart")) { model.restartTerminal(of: slug) }
            }
            Button(model.loc.t("terminal.close")) { model.closeTerminal(of: slug) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func stateText(_ state: TerminalSessionState?) -> String {
        switch state {
        case .running: return model.loc.t("terminal.state.running")
        case .exited(let code?): return model.loc.count("terminal.state.exitedCode", Int(code))
        case .exited(nil): return model.loc.t("terminal.state.exited")
        case nil: return ""
        }
    }
}
