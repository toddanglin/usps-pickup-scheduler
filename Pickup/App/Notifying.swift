import Foundation

/// Posts the user-facing alerts `AppState` raises. The real
/// `UNUserNotificationCenter`-backed implementation lives in a later task.
protocol Notifying: Sendable {
    func notifyCredentialsNeeded()
}
