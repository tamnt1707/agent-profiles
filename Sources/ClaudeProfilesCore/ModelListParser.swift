import Foundation

/// Reads the model ids out of a provider's model list.
///
/// Understands `{"data":[{"id":…}]}` (Anthropic, OpenAI style, OpenRouter) and
/// `{"models":[{"id"|"name":…}]}`, and a bare list of the same items.
public enum ModelListParser {
    /// One page of the list.
    public struct Page: Equatable, Sendable {
        /// The ids of the page: trimmed, de-duplicated and sorted.
        public var ids: [String]
        /// `true` when the provider has more pages (Anthropic's `has_more`).
        public var hasMore: Bool
        /// The cursor of the next page (Anthropic's `last_id`).
        public var lastID: String?

        public init(ids: [String], hasMore: Bool = false, lastID: String? = nil) {
            self.ids = ids
            self.hasMore = hasMore
            self.lastID = lastID
        }
    }

    /// Ids longer than this are dropped: no real model name is that long.
    public static let maxIDLength = 200

    /// The page of a model list, or `nil` when the body is not a list of models.
    public static func parse(_ data: Data) -> Page? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let items: [Any]
        var hasMore = false
        var lastID: String?
        if let array = json as? [Any] {
            items = array
        } else if let object = json as? [String: Any],
                  let list = (object["data"] as? [Any]) ?? (object["models"] as? [Any]) {
            items = list
            hasMore = (object["has_more"] as? Bool) ?? false
            lastID = object["last_id"] as? String
        } else {
            return nil
        }

        let ids = items.compactMap(identifier(of:))
        return Page(ids: normalize(ids), hasMore: hasMore, lastID: lastID)
    }

    /// Trims, drops empty and oversized ids, removes duplicates and sorts.
    public static func normalize(_ ids: [String]) -> [String] {
        let cleaned = ids.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= maxIDLength else { return nil }
            guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return nil
            }
            return value
        }
        return Array(Set(cleaned)).sorted()
    }

    /// The id of one item: an object's `id` or `name`, or the item itself when it is a string.
    private static func identifier(of item: Any) -> String? {
        if let text = item as? String { return text }
        guard let object = item as? [String: Any] else { return nil }
        return (object["id"] as? String) ?? (object["name"] as? String)
    }
}
