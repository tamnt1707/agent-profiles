import SwiftUI
import ClaudeProfilesCore

/// The strip at the top of the main window: a new version, the progress of
/// the download or the reason why the update did not work.
struct UpdateBannerView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.updater.state {
            case .available(let info):
                available(info)
            case .downloading:
                working(model.loc.t("update.downloading"))
            case .checking:
                working(model.loc.t("status.updateChecking"))
            case .verifying:
                working(model.loc.t("update.verifying"))
            case .installing:
                working(model.loc.t("update.installing"))
            case .failed(let error):
                failed(error)
            case .idle, .upToDate:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary)
    }

    // MARK: - The states

    private func available(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.loc.t("update.available", info.version.description))
                    .font(.headline)
                Spacer(minLength: 12)
                Button(model.loc.t("update.updateNow")) { model.updateNow() }
                    .buttonStyle(.borderedProminent)
                Button(model.loc.t("update.later")) { model.dismissUpdateBanner() }
            }

            if !model.updater.notes.isEmpty {
                DisclosureGroup(model.loc.t("update.releaseNotes")) {
                    Text(model.updater.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
            Spacer(minLength: 12)
            if case .downloading = model.updater.state {
                if let progress = model.updater.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                }
                Button(model.loc.t("update.cancel")) { model.cancelUpdate() }
            }
        }
    }

    private func failed(_ error: UpdateError) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(error.localizedMessage(model.loc))
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Button(model.loc.t("actions.close")) { model.dismissUpdateBanner() }
        }
    }
}
