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
        // A minimum rather than a fixed size: each tab's grouped Form
        // scrolls on its own, and a taller window simply shows more of it.
        .frame(minWidth: 460, minHeight: 380)
    }
}
