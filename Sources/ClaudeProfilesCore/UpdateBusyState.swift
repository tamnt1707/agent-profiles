import Foundation

/// The busy rule of the updater.
///
/// One run goes on at a time. The updater is busy from the moment `begin()`
/// returns, before any progress is reported. Progress of a run that was
/// cancelled or ended is ignored, so a late report cannot bring the state back.
public struct UpdateBusyState: Equatable {
    /// Closed by `begin()`, opened by `end()`.
    private var gate = UpdateRunGate()

    /// The progress of the current run. `nil` when no run is reporting: before
    /// `begin()`, after `cancel()` and after `end()`.
    public private(set) var progress: UpdateInstaller.Progress?

    public init() {}

    /// `true` from a successful `begin()` until `end()`, also after `cancel()`.
    public var isBusy: Bool { gate.isRunning }

    /// Starts a run. The run begins as a download before the first byte arrives.
    /// Returns `false`, and changes nothing, while a run is going on.
    public mutating func begin() -> Bool {
        guard gate.begin() else { return false }
        progress = .downloading(received: 0, expected: nil)
        return true
    }

    /// Records the progress of the run. Ignored when no run is reporting.
    public mutating func report(_ next: UpdateInstaller.Progress) {
        guard progress != nil else { return }
        progress = next
    }

    /// The user stopped the run. Its late reports are ignored. The gate stays
    /// closed until `end()`, so a second run cannot start while the first one unwinds.
    public mutating func cancel() {
        progress = nil
    }

    /// The run is over, completed or failed. The next `begin()` succeeds.
    public mutating func end() {
        gate.end()
        progress = nil
    }
}
