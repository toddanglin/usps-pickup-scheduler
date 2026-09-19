import SwiftUI

/// The Settings scene: four tabs, standard grouped forms.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "key.fill") }
            AddressSettingsTab()
                .tabItem { Label("Address", systemImage: "house.fill") }
            DefaultsSettingsTab()
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 460, height: 380)
    }
}
