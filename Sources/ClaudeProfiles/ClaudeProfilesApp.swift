import SwiftUI

/// The window of the app. The full interface arrives with the next commit.
@main
@MainActor
struct ClaudeProfilesApp: App {
    @State private var loc = Loc()

    var body: some Scene {
        WindowGroup {
            Text(loc.t("app.title"))
        }
    }
}
