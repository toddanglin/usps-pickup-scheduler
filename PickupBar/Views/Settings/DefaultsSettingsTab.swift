import SwiftUI

/// Settings › Defaults: what a fresh pickup form starts out with.
struct DefaultsSettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Package location", selection: $settings.defaultLocation) {
                    ForEach(PackageLocation.allCases, id: \.self) { location in
                        Text(location.displayName).tag(location)
                    }
                }
                TextField("Special instructions", text: $settings.defaultInstructions)
                Toggle("Dog on premises", isOn: $settings.dogPresent)
                TextField("Estimated weight (lb)",
                          value: $settings.defaultWeight,
                          format: .number)
            } footer: {
                Text("New pickups start with these values. You can change them per pickup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
