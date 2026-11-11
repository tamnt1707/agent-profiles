import Foundation

/// The copy of a saved profile, made by "Duplicate".
///
/// The copy is a new draft: nothing is written until the user saves it. It
/// takes every setting of the profile. It never takes what belongs to the
/// profile's own folder (the Claude Code sign-in, the history, the sessions)
/// or what was measured for it (usage, health results).
public enum ProfileDuplicate {
    /// A new, unsaved profile with the settings of `source`.
    ///
    /// - Parameters:
    ///   - source: the profile as it is saved. Unsaved edits are not part of it.
    ///   - existing: every profile that exists, the default setup included.
    ///   - nameTemplate: the localized name of the copy, with one `%@` for the
    ///     name of the source, for example `%@ copy`.
    ///   - isTaken: `true` when a command name is already used by a launcher
    ///     file on disk, the same check a new profile goes through.
    public static func make(
        from source: Profile,
        existing: [Profile],
        nameTemplate: String,
        isTaken: (String) -> Bool
    ) -> Profile {
        let names = Set(existing.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let slugs = Set(existing.map(\.slug))
        let base = TemplateFormat.fill(nameTemplate, [source.name])

        var number = 1
        var name = base
        var slug = Slug.slugify(name)
        while names.contains(name.lowercased()) || slug.isEmpty || slugs.contains(slug) || isTaken(slug) {
            number += 1
            name = "\(base) \(number)"
            slug = Slug.slugify(name)
        }

        var copy = source
        copy.name = name
        copy.slug = slug
        // The copy of the default setup is a normal profile with a folder of its own.
        if source.isDefaultClaude {
            copy.isolate = true
        }
        // The folders the source was opened in are its own history.
        copy.recentDirs = []
        // The schedule is kept, but it does not start on its own: two profiles
        // must not start the same usage window by surprise.
        copy.heartbeat = Heartbeat(enabled: false, times: source.heartbeat.times, days: source.heartbeat.days)
        return copy
    }

    /// The key to store when the copy is saved.
    ///
    /// A key the user typed wins. Otherwise the key of the source is used, when
    /// there is one. `nil` means that nothing is typed and the source has none.
    public static func keyToStore(typed: String, sourceSlug: String?, keys: KeyStore) -> String? {
        let typedKey = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty { return typedKey }
        guard let sourceSlug, !sourceSlug.isEmpty else { return nil }
        guard let stored = try? keys.get(sourceSlug) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
