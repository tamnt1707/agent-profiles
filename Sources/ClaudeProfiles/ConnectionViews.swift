import SwiftUI
import ClaudeProfilesCore

/// The sentences and colors of the connection check. The core decides the
/// outcome; this file only shows it.
extension Loc {
    /// The sentence of an outcome, with its numbers and names filled in.
    func probeText(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .ok(let latency, let model):
            if let model { return count("probe.ok.model", latency, model) }
            return count("probe.ok", latency)
        case .serverError(let code):
            return count("probe.serverError", code)
        case .unexpectedStatus(let code):
            return count("probe.unexpectedStatus", code)
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
            // Image and text are colored one by one: a Label in a grouped Form
            // takes the label color and ignores the one set on it.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: outcome.severity.symbolName)
                    .foregroundColor(outcome.severity.color)
                Text(loc.probeText(outcome))
                    .foregroundColor(outcome.severity.color)
                    .textSelection(.enabled)
            }
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
