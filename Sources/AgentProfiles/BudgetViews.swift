import SwiftUI
import AgentProfilesCore

extension BudgetLevel {
    /// The color of a level: nothing special when it is fine.
    var color: Color {
        switch self {
        case .ok: return Color(nsColor: .labelColor)
        case .near: return Color(nsColor: .systemOrange)
        case .over: return Color(nsColor: .systemRed)
        }
    }

    /// A different shape for each level, so the level is not carried by color alone.
    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle"
        case .near: return "exclamationmark.triangle.fill"
        case .over: return "exclamationmark.octagon.fill"
        }
    }
}

extension Loc {
    /// The sentence of the badge of a profile in the sidebar.
    func budgetBadgeText(_ level: BudgetLevel) -> String {
        t(level == .over ? "sidebar.budget.over" : "sidebar.budget.near")
    }
}

/// The small badge of a profile that is near or over a cost limit.
struct BudgetBadge: View {
    let loc: Loc
    let level: BudgetLevel

    var body: some View {
        Image(systemName: level.symbolName)
            .font(.system(size: 11))
            .foregroundColor(level.color)
            .help(loc.budgetBadgeText(level))
            .accessibilityLabel(loc.budgetBadgeText(level))
    }
}
