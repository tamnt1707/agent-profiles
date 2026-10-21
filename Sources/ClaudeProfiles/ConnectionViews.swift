import SwiftUI
import ClaudeProfilesCore

/// The sentences and colors of the connection check. The core decides the
/// outcome; this file only shows it.
extension Loc {
    /// The sentence of an outcome, with its numbers and names filled in.
    func probeText(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .ok(let latency, let model):
            if let model { return t("probe.ok.model", latency, model) }
            return t("probe.ok", latency)
        case .serverError(let code), .unexpectedStatus(let code):
            return t(outcome.messageKey, code)
        default:
            return t(outcome.messageKey)
        }
    }
}

extension ProbeSeverity {
    var symbolName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .error: return Color(nsColor: .systemRed)
        }
    }
}

/// One line under a button: the outcome and, when the provider gave one, its own words.
struct ProbeResultLine: View {
    let loc: Loc
    let outcome: ProbeOutcome
    let providerMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(loc.probeText(outcome), systemImage: outcome.severity.symbolName)
                .foregroundStyle(outcome.severity.color)
                .textSelection(.enabled)
            if let providerMessage {
                Text(loc.t("probe.providerSaid", providerMessage))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The list of fetched models. A search field appears when there are many.
struct ModelPickerView: View {
    let loc: Loc
    let models: [String]
    let onPick: (String) -> Void

    @State private var query = ""

    private var filtered: [String] {
        query.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("editor.models.pickTitle"))
                .font(.headline)
            if models.count > 12 {
                TextField(loc.t("editor.models.search"), text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            if filtered.isEmpty {
                Text(loc.t("editor.models.noMatch"))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.self) { id in
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
            .frame(width: 320, height: 300)
        }
        .padding(12)
    }
}
