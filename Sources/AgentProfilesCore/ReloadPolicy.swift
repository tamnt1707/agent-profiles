import Foundation

/// What a reload of `profiles.json` does to the editor.
public enum ReloadDecision: Equatable, Sendable {
    /// The file is still unreadable. Only the warning is refreshed: the draft,
    /// the selection and the typed key stay as they are.
    case keepEditor
    /// The file reads now and the editor holds unsaved changes. The user is
    /// asked first, because loading replaces the draft.
    case askFirst
    /// The file reads now and the editor is clean. The profiles are loaded and
    /// the first one is selected.
    case loadNow
}

/// Decides what a reload does, so that a reload never discards typed work silently.
public enum ReloadPolicy {
    /// - Parameters:
    ///   - stillBroken: `true` when the file cannot be read at the moment of the reload.
    ///   - hasUnsavedChanges: `true` when the editor differs from the saved profile.
    public static func decide(stillBroken: Bool, hasUnsavedChanges: Bool) -> ReloadDecision {
        if stillBroken { return .keepEditor }
        return hasUnsavedChanges ? .askFirst : .loadNow
    }
}
