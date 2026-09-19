import SwiftUI

/// Settings › General: launch at login, version, links, quit.
struct GeneralSettingsTab: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        default: return "—"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.isEnabled = newValue
                        // Re-read: registration can quietly fail on unsigned
                        // builds, and the toggle should reflect reality.
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
            }

            Section {
                LabeledContent("Version", value: version)
                Link("PickupBar on GitHub",
                     destination: URL(string: "https://github.com/toddanglin/macos-usps-utility")!)
            }

            Section {
                Button("Quit PickupBar") { NSApplication.shared.terminate(nil) }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
