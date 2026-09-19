import SwiftUI
import ServiceManagement

/// Settings › General: launch at login, version, links, quit.
struct GeneralSettingsTab: View {
    // Starts false and is filled in from `onAppear`: reading
    // `SMAppService.status` while the view is being built would run on every
    // redraw, and the honest value is whatever the service says once we are on
    // screen.
    @State private var launchAtLogin = false
    @State private var loginItemStatus: SMAppService.Status = .notRegistered
    @State private var loginItemError: String?

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
                    .onChange(of: launchAtLogin) { _, newValue in apply(newValue) }

                if loginItemStatus == .requiresApproval {
                    Text("Approve PickupBar in System Settings › General › Login Items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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
        .onAppear(perform: refresh)
    }

    private func refresh() {
        loginItemStatus = LaunchAtLogin.status
        launchAtLogin = loginItemStatus == .enabled
    }

    private func apply(_ newValue: Bool) {
        guard newValue != (LaunchAtLogin.status == .enabled) else { return }
        do {
            loginItemError = nil
            try LaunchAtLogin.setEnabled(newValue)
        } catch {
            loginItemError = error.localizedDescription
        }
        // Re-read either way: registration can land in `.requiresApproval`
        // rather than `.enabled`, and the toggle should reflect reality.
        refresh()
    }
}
