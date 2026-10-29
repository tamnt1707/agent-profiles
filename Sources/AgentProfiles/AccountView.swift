import SwiftUI
import AgentProfilesCore

/// Shows which account a profile is signed in with: the answer of
/// `claude auth status`. It costs no tokens. Used for the default setup and for
/// a Claude subscription profile.
struct AccountView: View {
    @Bindable var model: AppModel
    let profile: Profile

    var body: some View {
        LabeledContent(model.loc.t("account.label")) {
            HStack(spacing: 8) {
                content
                Button {
                    model.refreshAccount(of: profile)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(model.loc.t("account.refresh"))
                .disabled(model.accounts[profile.slug] == .loading)
            }
        }
        // Asked when the page opens, not at launch.
        .task(id: profile.slug) {
            if model.accounts[profile.slug] == nil { model.refreshAccount(of: profile) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.accounts[profile.slug] {
        case .none, .loading:
            ProgressView().controlSize(.small)
        case .unavailable:
            Text(model.loc.t("account.unavailable")).foregroundStyle(.secondary)
        case .known(let info) where !info.loggedIn:
            Text(model.loc.t("account.notSignedIn")).foregroundColor(Color(nsColor: .systemOrange))
        case .known(let info):
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.email ?? model.loc.t("account.signedIn"))
                    .textSelection(.enabled)
                let detail = [info.subscription.map { $0.capitalized }, info.organization]
                    .compactMap { $0 }
                    .filter { $0 != info.email && !$0.hasSuffix("'s Organization") }
                    .joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
