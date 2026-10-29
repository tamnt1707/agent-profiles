import Foundation

/// Lets one update run at a time.
///
/// `begin()` changes the state at once, so a second start made while the first
/// one is still getting ready is refused. `end()` opens the gate again when the
/// run has completed or failed.
public struct UpdateRunGate: Equatable, Sendable {
    /// `true` from a successful `begin()` until `end()`.
    public private(set) var isRunning = false

    public init() {}

    /// Starts a run. Returns `false`, and changes nothing, while a run is going on.
    public mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// Ends the run, so the next `begin()` succeeds.
    public mutating func end() {
        isRunning = false
    }
}
