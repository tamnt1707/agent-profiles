import Foundation

/// Whether a key is stored for a profile.
public enum KeyPresence: Equatable, Sendable {
    /// A key is stored.
    case present
    /// No key is stored.
    case absent
    /// The Keychain could not be read. It is not known whether a key is there.
    case unknown
}

/// Reads which profiles have a key, without reading the keys themselves.
public enum KeyPresenceReader {
    /// Reads the presence of a key for every slug.
    ///
    /// A Keychain that cannot be read is not the same as a profile without a
    /// key: the value that was known before is kept, and a profile that has no
    /// value yet stays unknown. Only the presence of a key is asked for, never
    /// the key itself.
    ///
    /// - Parameters:
    ///   - slugs: the profiles to look at.
    ///   - hasKey: asks the Keychain whether a key is stored. It throws when
    ///     the Keychain cannot be read.
    ///   - previous: what was known before, used when the read fails.
    public static func read(
        slugs: [String],
        hasKey: (String) throws -> Bool,
        previous: [String: KeyPresence] = [:]
    ) -> [String: KeyPresence] {
        var result: [String: KeyPresence] = [:]
        for slug in slugs {
            do {
                result[slug] = try hasKey(slug) ? .present : .absent
            } catch {
                // The Keychain could not be read: the old value is kept, and a
                // profile without one is unknown. Neither is "no key".
                result[slug] = previous[slug] ?? .unknown
            }
        }
        return result
    }
}
