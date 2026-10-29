import AppKit
import SwiftUI
import AgentProfilesCore

/// The sentences of the health dots. The core decides the state and the reason;
/// this file only shows them.
extension Loc {
    /// The sentence of a reason, with its numbers and the text of the outcome filled in.
    func healthReasonText(_ reason: HealthReason) -> String {
        switch reason {
        case .noKeyStored:
            return t("sidebar.health.noKey")
        case .connected(let minutes):
            if minutes == 0 { return t("sidebar.health.connectedNow") }
            if minutes == 1 { return t("sidebar.health.connectedOne") }
            // The result is kept on disk, so it can be old: say it in the unit that reads best.
            if minutes < 60 { return count("sidebar.health.connectedMany", minutes) }
            if minutes < 60 * 48 { return count("sidebar.health.connectedHours", minutes / 60) }
            return count("sidebar.health.connectedDays", minutes / (60 * 24))
        case .notTested:
            return t("sidebar.health.notTested")
        case .keychainUnreadable:
            return t("sidebar.health.keychainUnreadable")
        case .testWarning(let outcome):
            return t("sidebar.health.warning", probeText(outcome))
        case .testFailed(let outcome):
            return t("sidebar.health.failed", probeText(outcome))
        }
    }

    /// The name of a state, for the accessibility label.
    func healthStateText(_ state: HealthState) -> String {
        switch state {
        case .ready: return t("sidebar.health.stateReady")
        case .untested: return t("sidebar.health.stateUntested")
        case .attention: return t("sidebar.health.stateAttention")
        case .problem: return t("sidebar.health.stateProblem")
        }
    }
}

extension HealthState {
    /// A different shape for each state, so the state is not carried by color alone.
    var symbolName: String {
        switch self {
        case .ready: return "circle.fill"
        case .untested: return "circle"
        case .attention: return "triangle.fill"
        case .problem: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Color(nsColor: .systemGreen)
        case .untested: return Color(nsColor: .secondaryLabelColor)
        case .attention: return Color(nsColor: .systemOrange)
        case .problem: return Color(nsColor: .systemRed)
        }
    }
}

/// The dot of a state as an image for a menu. A menu draws a symbol in one
/// color (a template), so the color is baked into the image.
enum HealthDotImage {
    @MainActor
    static func image(for state: HealthState) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(state.color)]))
        let symbol = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        symbol.isTemplate = false
        return symbol
    }
}

/// The dot at the leading edge of a profile row. The tooltip and the
/// accessibility label give the reason in words.
struct HealthDot: View {
    let loc: Loc
    let status: HealthStatus

    var body: some View {
        let reason = loc.healthReasonText(status.reason)
        Image(systemName: status.state.symbolName)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(status.state.color)
            .frame(width: 12, height: 14)
            .help(reason)
            .accessibilityLabel(loc.t("sidebar.health.a11y", loc.healthStateText(status.state), reason))
    }
}

/// The bar at the bottom of the sidebar: "Check all connections", or its progress and Stop.
struct CheckAllBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let progress = model.healthProgress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .controlSize(.small)
                Text(model.loc.count("sidebar.checkAll.progress", progress.done, progress.total))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                Button(model.loc.t("sidebar.checkAll.stop")) { model.stopHealthCheck() }
            } else {
                Button(model.loc.t("sidebar.checkAll")) { model.requestHealthCheck() }
                    .disabled(!model.canCheckAllConnections)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
