import Foundation

/// Picks the models that match what the user typed in a model field.
///
/// Pure rules, so the tests can check them without a window: the typed text is
/// never changed here, only the list is ordered and cut.
public enum ModelSuggestions {
    /// The suggestions of one query.
    public struct Result: Equatable, Sendable {
        /// The first `limit` matches, in order.
        public var items: [String]
        /// `true` when more models match than `items` shows.
        public var more: Bool

        public init(items: [String], more: Bool) {
            self.items = items
            self.more = more
        }
    }

    /// How many suggestions are shown at most by default.
    public static let defaultLimit = 50

    /// Matches `query` against `models`.
    ///
    /// The query is trimmed of spaces and compared without case. The order is:
    /// the exact match, then the names that start with the query, then the names
    /// that contain it. Each group is sorted alphabetically. Duplicates are
    /// dropped. An empty query matches every model, sorted.
    public static func filter(query: String, in models: [String], limit: Int = defaultLimit) -> Result {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var exact: [String] = []
        var prefix: [String] = []
        var inside: [String] = []

        for model in models where seen.insert(model).inserted {
            let lowered = model.lowercased()
            if lowered == needle {
                exact.append(model)
            } else if lowered.hasPrefix(needle) {
                prefix.append(model)
            } else if lowered.contains(needle) {
                inside.append(model)
            }
        }

        let ordered = exact.sorted() + prefix.sorted() + inside.sorted()
        let cap = max(0, limit)
        return Result(items: Array(ordered.prefix(cap)), more: ordered.count > cap)
    }
}
