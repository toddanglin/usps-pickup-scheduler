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
                if settings.defaultLocation == .other,
                   settings.defaultInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Instructions are required when the location is Other")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Dog on premises", isOn: $settings.dogPresent)
                LabeledContent("Estimated weight") {
                    WeightField(weight: $settings.defaultWeight, minimum: 0.1)
                }
            } footer: {
                Text("New pickups start with these values. You can change them per pickup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
