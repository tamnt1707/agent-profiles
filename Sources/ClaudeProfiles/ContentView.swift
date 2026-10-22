import AppKit
import SwiftUI
import ClaudeProfilesCore

/// The main window: the profile list on the left, the editor on the right.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        // The split view is the root of the window so the title bar, the
        // sidebar and the scrolling detail pane are laid out by the system.
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        // Shown whether or not a profile is open: an unreadable
                        // profiles.json leaves nothing to edit. It stays until a save succeeds.
                        if let warning = model.dataWarningText {
                            DataWarningView(model: model, text: warning)
                            Divider()
                        }
                        if model.updater.state != .idle && model.updater.state != .upToDate {
                            UpdateBannerView(model: model)
                            Divider()
                        }
                    }
                }
        }
        .navigationTitle(model.loc.t("app.title"))
        .onChange(of: model.selectedSlug) { _, slug in
            model.sidebarSelectionChanged(to: slug)
        }
        // The key presence is re-read when the app becomes active. The model
        // watches that itself, so it also happens without this window.
        .alert(model.loc.t("update.unsaved.title"), isPresented: $model.isConfirmingUpdate) {
            Button(model.loc.t("update.unsaved.save")) { model.saveAndUpdate() }
            Button(model.loc.t("update.unsaved.discard")) { model.discardAndUpdate() }
            Button(model.loc.t("actions.cancel"), role: .cancel) { model.isConfirmingUpdate = false }
        } message: {
            Text(model.loc.t("update.unsaved.message"))
        }
        .alert(model.loc.t("pathSetup.offer.title", model.pathOfferSlug), isPresented: $model.isOfferingPathSetup) {
            Button(model.loc.t("pathSetup.offer.add")) { model.status = model.addPathSetup(for: model.loginKind) }
            Button(model.loc.t("pathSetup.offer.later"), role: .cancel) {}
            Button(model.loc.t("pathSetup.offer.never")) { model.declinePathPromptForever() }
        } message: {
            Text(model.loc.t(model.pathOfferPartly ? "pathSetup.offer.partlyMessage" : "pathSetup.offer.message"))
        }
        .alert(model.loc.t("pathSetup.lastProfile.title"), isPresented: $model.isOfferingPathRemoval) {
            Button(model.loc.t("pathSetup.lastProfile.remove"), role: .destructive) {
                model.status = model.removeAllPathSetup()
            }
            Button(model.loc.t("pathSetup.keep"), role: .cancel) {}
        } message: {
            Text(model.loc.t("pathSetup.lastProfile.message", model.pathFilesText))
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedSlug) {
            ForEach(model.data.profiles, id: \.slug) { profile in
                ProfileRow(model: model, profile: profile)
                    .tag(profile.slug)
                    .contextMenu {
                        // The menu acts on the row that was clicked, not on the edited profile.
                        Button(model.loc.t("actions.copyCommand")) { model.copyCommand(for: profile) }
                        Button(model.loc.t("actions.reveal")) { model.revealFolder(for: profile) }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The bar is only there when there is something to check: no
            // disabled button over the empty state.
            if !model.data.profiles.isEmpty {
                CheckAllBar(model: model)
            }
        }
        // The question is asked before any request: one tiny request per provider.
        .alert(model.loc.t("sidebar.checkAll.confirm.title"), isPresented: $model.isConfirmingHealthCheck) {
            Button(model.loc.t("sidebar.checkAll.confirm.check")) { model.startHealthCheck() }
            Button(model.loc.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(model.loc.t("sidebar.checkAll.confirm.message"))
        }
        // The question about unsaved changes belongs to the sidebar, next to
        // the selection it protects. The update question stays on the window.
        .alert(model.loc.t("unsaved.switch.title"), isPresented: $model.isConfirmingSwitch) {
            Button(model.loc.t("unsaved.switch.save")) { model.resolveSwitch(.save) }
            Button(model.loc.t("unsaved.switch.discard"), role: .destructive) { model.resolveSwitch(.discard) }
            Button(model.loc.t("actions.cancel"), role: .cancel) { model.resolveSwitch(.cancel) }
        } message: {
            Text(model.loc.t("unsaved.switch.message"))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestNewProfile()
                } label: {
                    Label(model.loc.t("sidebar.add"), systemImage: "plus")
                }
                .help(model.loc.t("sidebar.add"))
            }
        }
        .overlay {
            if model.data.profiles.isEmpty {
                // A compact empty state: the sidebar is narrow, so the
                // title and the text use smaller styles than the default.
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(model.loc.t("sidebar.empty.title"))
                        .font(.headline)
                    Text(model.loc.t("sidebar.empty.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(model.loc.t("sidebar.add")) { model.requestNewProfile() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
                .padding(16)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if model.draft != nil {
            // Pin the editor to the space the window gives it: a plain
            // ProfileEditorView made the split view taller than the window.
            GeometryReader { geo in
                ProfileEditorView(model: model)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ContentUnavailableView {
                Label(model.loc.t("detail.empty.title"), systemImage: "sidebar.left")
            } description: {
                Text(model.loc.t("detail.empty.description"))
            }
        }
    }
}

/// The warning about a profiles.json that could not be read, or the copy that
/// was kept after a recovering save.
private struct DataWarningView: View {
    let model: AppModel
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if model.dataFailed {
                    Button(model.loc.t("banner.reload")) { model.reloadData() }
                }
                Button(model.loc.t("banner.showBackup")) { model.revealBackup() }
                if !model.dataFailed {
                    Button(model.loc.t("banner.dismiss")) { model.dismissDataWarning() }
                }
            }
            .controlSize(.small)
        }
        .font(.callout)
        .foregroundStyle(Color(nsColor: .systemRed))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// One profile in the sidebar, with its health dot at the leading edge.
private struct ProfileRow: View {
    let model: AppModel
    let profile: Profile

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // The minute tick only redraws the dot, so a test ages into "not tested" with no request.
            TimelineView(.everyMinute) { context in
                HealthDot(loc: model.loc, status: model.healthStatus(for: profile, now: context.date))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name.isEmpty ? profile.slug : profile.name)
                    .font(.body)
                Text("claude-\(profile.slug)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
