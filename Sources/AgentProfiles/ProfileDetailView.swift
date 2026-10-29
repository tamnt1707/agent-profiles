import SwiftUI
import AgentProfilesCore

/// The right side of the window for one profile: its settings, terminal, usage or orchestration.
///
/// The terminals of a profile keep running while another profile is shown, so
/// the switch says which profile has a process and the sidebar marks it.
struct ProfileDetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            // A profile that was never saved has no terminal to show.
            if let slug = model.currentProfile?.slug {
                tabBar(slug)
                Divider()
                switch model.detailTab(for: slug) {
                case .terminal:
                    TerminalPane(model: model, slug: slug)
                case let page:
                    ProfileEditorView(model: model, page: page)
                }
            } else {
                ProfileEditorView(model: model)
            }
        }
        // The pane is as big as the window gives it, and starts at the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func tabBar(_ slug: String) -> some View {
        let running = model.terminals.book.runningCount(for: slug) > 0
        return HStack {
            Picker("", selection: Binding(
                get: { model.detailTab(for: slug) },
                set: { model.setDetailTab($0, for: slug) }
            )) {
                Text(model.loc.t("terminal.tab.settings")).tag(AppModel.DetailTab.settings)
                Label(model.loc.t("terminal.tab.terminal"), systemImage: running ? "circle.fill" : "terminal")
                    .tag(AppModel.DetailTab.terminal)
                Text(model.loc.t("terminal.tab.usage")).tag(AppModel.DetailTab.usage)
                Text(model.loc.t("terminal.tab.orchestration")).tag(AppModel.DetailTab.orchestration)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The terminal tab: the tabs of the profile, the terminal and a bar under it.
struct TerminalPane: View {
    @Bindable var model: AppModel
    let slug: String

    var body: some View {
        content
            // The tab is open and nothing runs yet: run the profile.
            .task(id: slug) { model.startTerminalIfNeeded(of: slug) }
            .alert(confirmTitle, isPresented: $model.isConfirmingTerminalAction) {
                Button(model.loc.t(confirmButtonKey), role: .destructive) { model.confirmTerminalAction() }
                Button(model.loc.t("actions.cancel"), role: .cancel) { model.cancelTerminalAction() }
            } message: {
                Text(model.loc.t("terminal.confirm.message"))
            }
    }

    @ViewBuilder
    private var content: some View {
        // The views are not observed, the book is: reading it draws the pane
        // again when a tab starts, ends or goes away.
        let tabs = model.terminals.book.sessions(for: slug)
        if let active = model.activeSession(of: slug), let terminal = model.terminals.view(for: active.id) {
            VStack(spacing: 0) {
                sessionStrip(tabs, active: active)
                Divider()
                // One container for each tab: the terminal is put into it again.
                EmbeddedTerminalView(terminal: terminal)
                    .id(active.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                bar(for: active)
            }
        } else {
            ContentUnavailableView {
                Label(model.loc.t("terminal.empty.title"), systemImage: "terminal")
            } description: {
                Text(model.loc.t("terminal.empty.message"))
            } actions: {
                Button(model.loc.t("terminal.run")) { model.newSession(of: slug) }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - The tabs

    private func sessionStrip(_ tabs: [TerminalSession], active: TerminalSession) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        sessionTab(tab, isActive: tab.id == active.id)
                    }
                }
            }
            Button { model.newSession(of: slug) } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(model.loc.t("terminal.new"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func sessionTab(_ tab: TerminalSession, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.state == .running ? "circle.fill" : "stop.circle")
                .font(.system(size: 8))
                .foregroundColor(tab.state == .running ? Color(nsColor: .systemGreen) : Color.secondary)
            Text(model.loc.count("terminal.session.label", tab.number))
                .font(.callout)
            Button { model.requestClose(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(model.loc.t("terminal.closeSession"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.35) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectSession(tab.id, of: slug) }
    }

    // MARK: - The bar

    private func bar(for tab: TerminalSession) -> some View {
        HStack(spacing: 10) {
            Label(stateText(tab.state), systemImage: tab.state == .running ? "circle.fill" : "stop.circle")
                .font(.callout)
                .foregroundStyle(tab.state == .running ? Color(nsColor: .systemGreen) : .secondary)
            if let folder = model.terminals.folder(for: tab.id) {
                Text(model.loc.t("terminal.folder", folder))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(model.loc.t("terminal.restart")) { model.requestRestart(tab.id) }
            Button(model.loc.t("terminal.new")) { model.newSession(of: slug) }
            Button(model.loc.t("terminal.closeSession")) { model.requestClose(tab.id) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func stateText(_ state: TerminalSessionState) -> String {
        switch state {
        case .running: return model.loc.t("terminal.state.running")
        case .exited(let code?): return model.loc.count("terminal.state.exitedCode", Int(code))
        case .exited(nil): return model.loc.t("terminal.state.exited")
        }
    }

    private var confirmTitle: String {
        if case .close = model.pendingTerminalAction { return model.loc.t("terminal.confirm.close.title") }
        return model.loc.t("terminal.confirm.restart.title")
    }

    private var confirmButtonKey: String {
        if case .close = model.pendingTerminalAction { return "terminal.closeSession" }
        return "terminal.restart"
    }
}
