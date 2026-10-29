import Foundation

/// Decides whether the profile editor holds changes that are not saved yet.
public enum DraftChanges {
    /// The draft of a new profile: the defaults of the editor.
    public static var blankProfile: Profile {
        Profile(isolate: true, shareFromDefault: true)
    }

    /// `true` when the editor differs from the saved profile.
    ///
    /// A new profile (`saved` is `nil`) is compared with `blankProfile` and an
    /// empty command name, so an untouched new draft is clean. A typed API key
    /// is a change; whitespace alone does not count.
    public static func hasChanges(
        draft: Profile,
        command: CommandNameDraft,
        saved: Profile?,
        typedKey: String
    ) -> Bool {
        if !typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let baseline = saved ?? blankProfile
        let baselineCommand = saved.map { CommandNameDraft(profile: $0) } ?? CommandNameDraft()
        return draft != baseline || command != baselineCommand
    }
}
