import AppKit
import Foundation
import Observation
import SwiftUI
import ClaudeProfilesCore

/// The state of the updater of the app.
///
/// The controller holds no text of its own: every sentence comes from the
/// string table, so the app can switch the language at any moment.
@MainActor
@Observable
final class UpdateController {
    /// What the updater is doing right now.
    enum State: Equatable {
        /// Nothing is going on.
        case idle
        /// The releases of the repository are being read.
        case checking
        /// The installed version is the newest one.
        case upToDate
        /// A newer version is waiting.
        case available(UpdateInfo)
        /// The archive is on its way.
        case downloading(received: Int64, expected: Int64?)
        /// The signature of the archive is being checked.
        case verifying
        /// The bundle is being replaced.
        case installing
        /// Something went wrong.
        case failed(UpdateError)
    }

    /// What the updater is doing.
    var state: State = .idle

    /// The notes of the release that is waiting.
    var notes: String = ""

    /// What the app knows about itself.
    let configuration: UpdateConfiguration

    private let checker: UpdateChecker?
    private let installer: UpdateInstaller?

    init(configuration: UpdateConfiguration = .current()) {
        self.configuration = configuration
        if configuration.isEnabled {
            checker = UpdateChecker(repo: configuration.repo)
            installer = UpdateInstaller(configuration: configuration)
        } else {
            checker = nil
            installer = nil
        }
    }

    /// `true` when the app may look for a new version.
    var isEnabled: Bool { configuration.isEnabled }

    /// Why the updater is turned off, when it is.
    var disabledReason: UpdateConfiguration.DisabledReason? { configuration.disabledReason }

    /// `true` while the updater is busy.
    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .verifying, .installing: return true
        default: return false
        }
    }

    /// The version that is waiting, when there is one.
    var availableVersion: SemVer? {
        if case .available(let info) = state { return info.version }
        return nil
    }

    /// How far the download is, between 0 and 1. `nil` when the size of the
    /// archive is unknown.
    var progress: Double? {
        guard case .downloading(let received, let expected) = state, let expected, expected > 0 else {
            return nil
        }
        return min(1, Double(received) / Double(expected))
    }

    /// Looks for a newer version.
    ///
    /// The automatic check of the launch is silent: it shows nothing, not
    /// even while it is running, and an error is not shown either.
    @discardableResult
    func check(silent: Bool = false) async throws -> UpdateCheckResult {
        guard let checker, let current = configuration.version else {
            throw UpdateError.notConfigured
        }
        if !silent { state = .checking }
        do {
            let result = try await checker.check(current: current)
            switch result {
            case .available(let info):
                notes = info.notes
                state = .available(info)
            case .upToDate:
                state = .upToDate
            }
            return result
        } catch {
            state = silent ? .idle : .failed(UpdateController.asUpdateError(error))
            throw error
        }
    }

    /// Downloads the new version, checks it and hands it to the helper.
    func install() async throws {
        // A second call while the update is running must not start another
        // download; it is refused and the running update keeps its state.
        switch state {
        case .downloading, .verifying, .installing:
            throw UpdateError.cancelled
        default:
            break
        }
        guard let installer, case .available(let info) = state else {
            throw UpdateError.notConfigured
        }
        do {
            try await installer.install(info) { [weak self] progress in
                // The progress comes from a background queue.
                Task { @MainActor [weak self] in
                    self?.apply(progress)
                }
            }
            state = .installing
        } catch {
            state = .failed(UpdateController.asUpdateError(error))
            throw error
        }
    }

    /// Remembers the version that is waiting, so the banner can show it again.
    func showAgain() {
        if case .available = state { return }
        state = .idle
    }

    /// Any error of the updater, as a case of the update error.
    static func asUpdateError(_ error: Error) -> UpdateError {
        if let updateError = error as? UpdateError { return updateError }
        if let urlError = error as? URLError { return UpdateChecker.map(urlError) }
        return .downloadFailed
    }

    private func apply(_ progress: UpdateInstaller.Progress) {
        switch progress {
        case .downloading(let received, let expected):
            state = .downloading(received: received, expected: expected)
        case .verifying:
            state = .verifying
        case .extracting:
            state = .verifying
        case .installing:
            state = .installing
        }
    }
}
