import Foundation

/// What a click in the menu bar does.
///
/// The plan is built before the terminal is opened and says which folder the
/// profile is opened in. The recent folder is only remembered when the launch
/// worked: a folder that could not be opened is not a folder the user works in.
public struct MenuLaunchPlan: Equatable, Sendable {
    /// Where the folder of the launch comes from.
    public enum Source: Equatable, Sendable {
        /// The profile itself: it is opened in its own working directory.
        case profile
        /// A folder the user chose in the menu: it is remembered as a recent
        /// folder, but only after the launch worked.
        case chosenFolder
    }

    /// The profile that is launched.
    public var slug: String
    /// The folder it is opened in. `nil` means the folder of the profile.
    public var folder: String?
    /// Where the folder comes from.
    public var source: Source

    public init(slug: String, folder: String? = nil, source: Source = .profile) {
        self.slug = slug
        self.folder = folder
        self.source = source
    }

    /// The plan of a click on a profile itself: the profile is opened in its
    /// own working directory and no folder is remembered.
    public static func profile(_ slug: String) -> MenuLaunchPlan {
        MenuLaunchPlan(slug: slug, folder: nil, source: .profile)
    }

    /// The plan of a click on a folder: the profile is opened in that folder
    /// and the folder is remembered after the launch worked.
    public static func folder(_ slug: String, _ path: String) -> MenuLaunchPlan {
        MenuLaunchPlan(slug: slug, folder: path, source: .chosenFolder)
    }

    /// `true` when the folder has to be remembered after a successful launch.
    public var recordsRecentFolder: Bool {
        source == .chosenFolder && folder != nil
    }

    /// The recent folders of the profile after a launch that worked.
    ///
    /// A folder that was chosen in the menu moves to the front. A launch in the
    /// folder of the profile leaves the list alone.
    public func recentFoldersAfterSuccess(stored: [String]) -> [String] {
        guard recordsRecentFolder, let folder else { return stored }
        var recent = RecentFolders(stored)
        recent.add(folder)
        return recent.paths
    }

    /// Runs the launch and remembers the folder when it worked.
    ///
    /// The folder is remembered only after the launch worked: `remember` is
    /// not called at all when the launch fails. A folder of a terminal that
    /// never opened is therefore never remembered.
    public func run(
        stored: [String],
        launch: () async throws -> Void,
        remember: ([String]) -> Void
    ) async throws {
        try await launch()
        remember(recentFoldersAfterSuccess(stored: stored))
    }
}
