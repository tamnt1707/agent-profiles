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
                case .settings where model.currentProfile?.isDefaultClaude == true:
                    DefaultSettingsView(model: model)
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
            // Opening the tab starts nothing: the chooser asks how first.
            .alert(model.terminalActionText().title, isPresented: $model.isConfirmingTerminalAction) {
                // Starting a session ends nothing: only a restart or a close is a destructive button.
                Button(model.terminalActionText().button, role: model.terminalActionEndsSession ? .destructive : nil) {
                    model.confirmTerminalAction()
                }
                Button(model.loc.t("actions.cancel"), role: .cancel) { model.cancelTerminalAction() }
            } message: {
                Text(model.terminalActionText().message)
            }
    }

    @ViewBuilder
    private var content: some View {
        // The views are not observed, the book is: reading it draws the pane
        // again when a tab starts, ends or goes away.
        let tabs = model.terminals.book.sessions(for: slug)
        if tabs.isEmpty || model.launcherShown.contains(slug) {
            LaunchChooser(model: model, slug: slug, canCancel: !tabs.isEmpty)
        } else if let active = model.activeSession(of: slug), let terminal = model.terminals.view(for: active.id) {
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
            LaunchChooser(model: model, slug: slug, canCancel: false)
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
            Button { model.showLauncher(of: slug) } label: {
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
            if model.terminals.mode(for: tab.id) != .normal {
                Text(model.modeName(model.terminals.mode(for: tab.id)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            if model.terminals.mode(for: tab.id) != .normal {
                Label(model.modeName(model.terminals.mode(for: tab.id)), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(model.loc.t("terminal.restart")) { model.requestRestart(tab.id) }
            Button(model.loc.t("terminal.new")) { model.showLauncher(of: slug) }
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
}

/// The modes a tab can run in, in the order the menus show them.
enum TerminalModeChoice {
    static let all: [TerminalMode] = [.normal, .orchestrated(.sequential), .orchestrated(.queue)]
}

/// How a new tab starts: plain Claude, or Claude as the orchestrator of a workflow.
struct LaunchChooser: View {
    @Bindable var model: AppModel
    let slug: String
    let canCancel: Bool

    var body: some View {
        let choice = model.launchChoice(of: slug)
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(model.loc.t("terminal.empty.title")).font(.title3.bold())
            Picker("", selection: Binding(
                get: { model.launchChoice(of: slug) },
                set: { model.setLaunchChoice($0, of: slug) }
            )) {
                ForEach(TerminalModeChoice.all, id: \.self) { Text(model.modeName($0)).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(description(of: choice))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            if let note = agentsNote(for: choice) {
                Label(note.text, systemImage: note.icon)
                    .font(.callout)
                    .foregroundColor(note.warn ? Color(nsColor: .systemOrange) : .secondary)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if canCancel {
                    Button(model.loc.t("actions.cancel")) { model.hideLauncher(of: slug) }
                }
                Button(model.loc.t("terminal.run")) { model.startSession(of: slug, mode: choice) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func description(of mode: TerminalMode) -> String {
        switch mode {
        case .normal: return model.loc.t("terminal.mode.normal.hint")
        case .orchestrated(.sequential): return model.loc.t("terminal.mode.sequential.hint")
        case .orchestrated(.queue): return model.loc.t("terminal.mode.queue.hint")
        }
    }

    /// Whether the agents of the mode are there. Nothing for the normal mode.
    private func agentsNote(for mode: TerminalMode) -> (text: String, icon: String, warn: Bool)? {
        guard mode.workflow != nil, let profile = model.data.profiles.first(where: { $0.slug == slug }) else { return nil }
        if !profile.isolate { return (model.loc.t("orch.notIsolated"), "exclamationmark.triangle", true) }
        if model.needsAgents(mode, of: profile) {
            return (model.loc.t("terminal.agents.willInstall"), "arrow.down.circle", true)
        }
        return (model.loc.t("terminal.agents.ready"), "checkmark.circle", false)
    }
}
