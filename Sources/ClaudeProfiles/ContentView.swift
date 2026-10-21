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
                    if model.updater.state != .idle && model.updater.state != .upToDate {
                        VStack(spacing: 0) {
                            UpdateBannerView(model: model)
                            Divider()
                        }
                    }
                }
        }
        .navigationTitle(model.loc.t("app.title"))
        .onChange(of: model.selectedSlug) { _, slug in
            guard let slug,
                  let profile = model.data.profiles.first(where: { $0.slug == slug }),
                  model.draft?.slug != profile.slug
            else { return }
            model.select(profile)
        }
        .alert(model.loc.t("update.unsaved.title"), isPresented: $model.isConfirmingUpdate) {
            Button(model.loc.t("update.unsaved.save")) { model.saveAndUpdate() }
            Button(model.loc.t("update.unsaved.discard")) { model.discardAndUpdate() }
            Button(model.loc.t("actions.cancel"), role: .cancel) { model.isConfirmingUpdate = false }
        } message: {
            Text(model.loc.t("update.unsaved.message"))
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selectedSlug) {
            ForEach(model.data.profiles, id: \.slug) { profile in
                ProfileRow(profile: profile)
                    .tag(profile.slug)
                    .contextMenu {
                        Button(model.loc.t("actions.copyCommand")) { model.copyCommand() }
                        Button(model.loc.t("actions.reveal")) { model.revealFolder() }
                    }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.newProfile()
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
                    Button(model.loc.t("sidebar.add")) { model.newProfile() }
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

/// One profile in the sidebar.
private struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name.isEmpty ? profile.slug : profile.name)
                .font(.body)
            Text("claude-\(profile.slug)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
