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
