import Foundation

/// How the command name of a profile came to be.
public enum SlugMode: String, Equatable, Sendable {
    /// The slug follows the profile name.
    case auto
    /// The user typed the slug by hand.
    case custom
}

/// The editable command name of a profile: the fixed `claude-` prefix plus a
/// slug that either follows the profile name (auto) or was typed by hand
/// (custom).
///
/// In auto mode the slug is `slugify(name)` and follows every keystroke of the
/// name field. The first manual edit of the slug field switches the draft to
/// custom; from then on the name no longer changes the command.
public struct CommandNameDraft: Equatable, Sendable {
    /// The name of the profile.
    public var name: String
    /// What the user sees in the slug field.
    public var input: String
    /// Whether the slug follows the name or was typed by hand.
    public var mode: SlugMode

    public init(name: String = "", input: String = "", mode: SlugMode = .auto) {
        self.name = name
        self.input = input
        self.mode = mode
    }

    /// The draft of a new profile: the slug follows the name.
    public init() {
        self.init(name: "", input: "", mode: .auto)
    }

    /// The draft of an existing profile.
    ///
    /// A saved slug that differs from the slug of the name was typed by hand,
    /// so the draft stays custom; everything else follows the name.
    public init(profile: Profile) {
        self.name = profile.name
        self.input = profile.slug
        self.mode = profile.slug == Slug.slugify(profile.name) ? .auto : .custom
    }

    /// The slug as it is stored: the typed value normalized with `slugify`.
    ///
    /// A value that normalizes to nothing falls back to the slug of the name.
    /// When that is empty too the profile has no command at all, which the
    /// validation reports as an error.
    public var slug: String {
        let normalized = normalizedInput
        if !normalized.isEmpty { return normalized }
        return Slug.slugify(name)
    }

    /// The normalized value of the field.
    public var normalizedInput: String { Slug.slugify(input) }

    /// `true` when the field is saved as something else than what is typed.
    public var hasNormalizedPreview: Bool {
        let normalized = normalizedInput
        return !normalized.isEmpty && normalized != input
    }

    /// The profile that already uses this command name.
    public func duplicateOwner(among profiles: [Profile]) -> Profile? {
        let slug = self.slug
        guard !slug.isEmpty else { return nil }
        return profiles.first { $0.slug == slug }
    }

    /// The name of the profile changed. In auto mode the slug follows.
    public mutating func setName(_ name: String) {
        self.name = name
        if mode == .auto {
            input = Slug.slugify(name)
        }
    }

    /// The user typed in the slug field: the draft becomes custom.
    public mutating func setInput(_ input: String) {
        guard input != self.input else { return }
        mode = .custom
        self.input = input
    }

    /// "Reset to auto": the slug follows the name again.
    public mutating func resetToAuto() {
        mode = .auto
        input = Slug.slugify(name)
    }
}
