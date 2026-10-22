import Foundation

/// Decides when the list of the models may be fetched.
///
/// The list and the check of the profiles both send requests to the provider,
/// so they do not run at the same time: the answers of one never mix with the
/// other, and the key of the profile is read once at a time.
public enum ModelFetchGate {
    /// `true` when the model list may be fetched.
    ///
    /// Not while another fetch is on its way: a second fetch would replace
    /// the answer of the first one. Not while the check of the profiles runs:
    /// the two of them would send their requests at the same time.
    ///
    /// - Parameters:
    ///   - isFetching: a model list is being fetched right now.
    ///   - isCheckingHealth: the check of the profiles is running right now.
    public static func canFetch(isFetching: Bool, isCheckingHealth: Bool) -> Bool {
        !isFetching && !isCheckingHealth
    }
}
