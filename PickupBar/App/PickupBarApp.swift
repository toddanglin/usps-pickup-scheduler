import SwiftUI

@main
struct PickupBarApp: App {
    /// Held directly rather than behind a container object: the `MenuBarExtra`
    /// label reads `state.needsAttention`, and only a `@StateObject` on the
    /// `App` itself makes the Scene re-render when that changes.
    @StateObject private var state: AppState

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

        _state = StateObject(wrappedValue: AppState(settings: settings,
                                                    keychain: keychain,
                                                    apiFactory: { LiveUSPSClient(baseURL: $0) },
                                                    notifier: UserNotifier()))
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .frame(width: 340)
        } label: {
            MenuBarLabel(needsAttention: state.needsAttention)
                // The label exists from launch, while the popover's content
                // does not, so this is what makes the launch-time credential
                // check (and its badge + notification) actually run.
                .task { state.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.settings)
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
