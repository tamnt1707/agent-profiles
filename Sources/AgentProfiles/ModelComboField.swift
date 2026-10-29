import SwiftUI
import AgentProfilesCore

/// A model name that is typed by hand or picked from the provider's list.
///
/// Typing never changes the text except by the user's own keys. The list comes
/// from `AppModel`, is shared by every field of the profile, and is fetched only
/// when the user opens the chevron or taps Refresh.
struct ModelComboField: View {
    let model: AppModel
    let title: String
    var prompt: String = ""
    @Binding var text: String

    /// What the popover shows: the filtered suggestions while typing, or the full list from the chevron.
    private enum Popover: Equatable {
        case suggestions
        case browse
    }

    @State private var popover: Popover?
    /// The last name picked from the list, so picking it does not reopen the suggestions.
    @State private var lastPicked: String?

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .help(model.loc.t("editor.models.choose"))
                .onChange(of: text) { _, newText in
                    suggestWhileTyping(newText)
                }
                // Return keeps the typed text as it is.
                .onSubmit {
                    popover = nil
                }

            Button {
                browse()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            // The list is not fetched while the check of the profiles runs.
            .disabled(!model.canFetchModelList)
            .help(model.loc.t("editor.models.choose"))
            .accessibilityLabel(model.loc.t("editor.models.choose"))
        }
        .popover(isPresented: isPresenting, arrowEdge: .bottom) {
            switch popover {
            case .suggestions?:
                ModelOptionsView(model: model, query: text, offersRefresh: false, onPick: pick)
            case .browse?:
                ModelOptionsView(model: model, query: "", offersRefresh: true, onPick: pick)
            case nil:
                EmptyView()
            }
        }
    }

    private var isPresenting: Binding<Bool> {
        Binding(
            get: { popover != nil },
            set: { shown in
                guard !shown, popover != nil else { return }
                popover = nil
            }
        )
    }

    /// The chevron: asks for the list the first time, then shows what is cached.
    private func browse() {
        if popover == .browse {
            popover = nil
            return
        }
        model.loadModelList()
        popover = .browse
    }

    /// While typing, only the list that is already cached is used. Nothing is fetched.
    private func suggestWhileTyping(_ typed: String) {
        guard popover != .browse, typed != lastPicked else { return }
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = ModelSuggestions.filter(query: query, in: model.currentModelList?.models ?? [], limit: 1)
        popover = query.isEmpty || matches.items.isEmpty ? nil : .suggestions
    }

    private func pick(_ id: String) {
        lastPicked = id
        text = id
        popover = nil
    }
}

/// The list inside the popover: the refresh item, the matching models and the note about the list.
struct ModelOptionsView: View {
    let model: AppModel
    let query: String
    let offersRefresh: Bool
    let onPick: (String) -> Void

    var body: some View {
        let result = ModelSuggestions.filter(query: query, in: model.currentModelList?.models ?? [])
        VStack(alignment: .leading, spacing: 8) {
            if offersRefresh {
                HStack(spacing: 8) {
                    Button(model.loc.t("editor.models.refresh")) {
                        model.loadModelList(refresh: true)
                    }
                    // The list is not fetched while the check of the profiles runs.
                    .disabled(!model.canFetchModelList)
                    if model.isFetchingModels {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.loc.t("editor.models.fetching"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !result.items.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(result.items, id: \.self) { id in
                            Button {
                                onPick(id)
                            } label: {
                                Text(id)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                        }
                    }
                }
                .frame(height: min(260, CGFloat(result.items.count) * 26))
            }

            if result.more {
                Text(model.loc.t("editor.models.more"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if offersRefresh {
                note
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(12)
    }

    /// Why there is no list, when there is none. Nothing while the list is loading or has worked.
    @ViewBuilder
    private var note: some View {
        if !model.isFetchingModels, let report = model.currentModelList {
            switch report.outcome {
            case .ok:
                EmptyView()
            case .unsupported:
                Text(model.loc.t("editor.models.noList"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .missingKey:
                Text(model.loc.t("editor.models.needKey"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                ProbeResultLine(loc: model.loc, outcome: report.outcome, providerMessage: report.providerMessage)
            }
        }
    }
}
