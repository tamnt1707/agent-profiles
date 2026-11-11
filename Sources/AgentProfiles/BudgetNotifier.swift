import Foundation
import UserNotifications

/// Shows the cost limit notifications of the system.
///
/// The notification center only exists for an app that runs from an `.app`
/// bundle: a build that is started from the command line has none, and asking
/// for it would crash. In that case nothing is shown.
enum BudgetNotifier {
    /// Shows a banner even while this app is the active one.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list])
        }
    }

    private static let delegate = Delegate()

    /// `true` when the app runs from an `.app` bundle.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private static var center: UNUserNotificationCenter? {
        guard isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        return center
    }

    /// Asks for the permission. The system asks the user only the first time.
    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows one notification, when the user allowed them.
    static func post(identifier: String, title: String, body: String) {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}
