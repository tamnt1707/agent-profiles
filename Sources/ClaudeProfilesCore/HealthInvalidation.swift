import Foundation

/// Decides when the last test of a profile stops describing it.
public enum HealthInvalidation {
    /// `true` when the last test of the profile does not describe its settings
    /// any more, so the result must be dropped.
    ///
    /// A typed key is a new key that is not stored yet: the old result says
    /// nothing about it. A new Base URL, a new auth kind or a new name make
    /// the old result describe another provider or another account. A profile
    /// that was never saved has no result of its own, but its slug may have
    /// been used before, so nothing is kept for it either.
    ///
    /// Whitespace alone is not a key, like everywhere else in the app: the
    /// stored key is the one the test would use.
    public static func shouldForget(old: Profile?, new: Profile, typedKey: String) -> Bool {
        if !typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let old else { return true }
        return old.baseURL != new.baseURL || old.auth != new.auth || old.slug != new.slug
    }
}

/// What the Keychain said about one key.
public enum KeyRead: Equatable, Sendable {
    /// The Keychain was read: the key is there, or it is not.
    case read(Bool)
    /// The Keychain could not be read. Nothing is known about the key.
    case failed
}

/// The presence of the stored keys, as the Keychain says it.
public enum KeyPresence {
    /// Reads which of the profiles have a key stored. Only the existence is
    /// asked for: no secret is read and no request is sent.
    ///
    /// The Keychain is asked off the main actor, so a long list of profiles
    /// does not freeze the window.
    ///
    /// - Returns: what the Keychain said, per slug.
    public static func read(slugs: [String], keys: KeyStore) async -> [String: KeyRead] {
        await Task.detached(priority: .utility) {
            var read: [String: KeyRead] = [:]
            for slug in slugs {
                do {
                    read[slug] = .read(try keys.hasKey(slug))
                } catch {
                    // A Keychain that cannot be read does not mean that the
                    // key is gone: the caller keeps what it knew.
                    read[slug] = .failed
                }
            }
            return read
        }.value
    }

    /// Merges what was read into what was known before.
    ///
    /// A read that failed keeps the value that was known before: a Keychain
    /// that cannot be read does not mean that the key is gone. A profile whose
    /// presence was never known stays out of the map: its presence is unknown,
    /// not missing.
    ///
    /// - Parameters:
    ///   - slugs: the profiles of the list, in order.
    ///   - previous: the presence that was known before, per slug.
    ///   - read: what the Keychain said now, per slug.
    public static func merge(slugs: [String], previous: [String: Bool], read: [String: KeyRead]) -> [String: Bool] {
        var merged: [String: Bool] = [:]
        for slug in slugs {
            if case .read(let value) = read[slug] {
                merged[slug] = value
            } else if let known = previous[slug] {
                merged[slug] = known
            }
        }
        return merged
    }
}
