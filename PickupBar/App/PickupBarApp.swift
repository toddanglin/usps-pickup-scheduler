import SwiftUI

/// Owns the long-lived objects so `AppState` and the `SettingsStore` it holds
/// are the *same* instances the views see. A single `@StateObject` wrapper is
/// simpler than trying to build interdependent state objects inline.
@MainActor
final class AppContainer: ObservableObject {
    let state: AppState

    init() {
        // UI tests run the real app, so they need somewhere to write that is
        // not the user's own defaults or Keychain items. `PICKUPBAR_UITEST=1`
        // in the launch environment swaps both for throwaway, test-only
        // storage that is wiped at launch. Nothing here changes how a normally
        // launched app behaves.
        let settings: SettingsStore
        let keychain: KeychainStoring

        if UITestSupport.isActive {
            let suite = UITestSupport.storageName
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            settings = SettingsStore(defaults: defaults)
            settings.clear()
            let store = UITestCredentialStore(suiteName: suite)
            try? store.deleteCredentials()
            keychain = store
        } else {
            settings = SettingsStore()
            keychain = KeychainStore()
        }

        self.state = AppState(settings: settings,
                              keychain: keychain,
                              apiFactory: { LiveUSPSClient(baseURL: $0) },
                              notifier: UserNotifier())
    }
}

@main
struct PickupBarApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(container.state)
                .environmentObject(container.state.settings)
                .frame(width: 340)
        } label: {
            MenuBarLabel(needsAttention: container.state.needsAttention)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(container.state)
                .environmentObject(container.state.settings)
        }
    }
}

/// The status item glyph. Split out so the `needsAttention` change actually
/// re-renders the label.
private struct MenuBarLabel: View {
    let needsAttention: Bool

    var body: some View {
        if needsAttention {
            Image(systemName: "envelope.badge")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary, .red)
        } else {
            Image(systemName: "envelope")
        }
    }
}
