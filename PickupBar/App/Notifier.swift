import Foundation
import UserNotifications

/// Posts PickupBar's local notifications through `UNUserNotificationCenter`.
///
/// Authorization is requested lazily, the first time something actually needs
/// to be posted, so a user who never hits a credential problem is never asked.
/// Every failure path (denied authorization, no bundle identifier, an
/// unavailable notification center) is swallowed: a notification is a courtesy,
/// never something worth crashing or interrupting the flow for.
final class UserNotifier: Notifying, @unchecked Sendable {
    private let center: UNUserNotificationCenter?

    init() {
        // `UNUserNotificationCenter.current()` traps in unbundled contexts
        // (command-line test runners, previews). An actual .app bundle is the
        // reliable signal: a test runner can carry a bundle identifier without
        // being one.
        self.center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func notifyCredentialsNeeded() {
        post(title: "PickupBar needs your USPS credentials",
             body: "Your Consumer Key or Secret was rejected. Open PickupBar to update it.",
             identifier: "credentials-needed")
    }

    // MARK: - Private

    private func post(title: String, body: String, identifier: String) {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier,
                                                content: content,
                                                trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
