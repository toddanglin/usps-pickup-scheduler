import SwiftUI

/// Settings › Address: the same form the onboarding step uses.
struct AddressSettingsTab: View {
    var body: some View {
        ScrollView {
            AddressSettingsContent()
        }
    }
}

struct AddressSettingsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            Text("Pickup address")
                .font(.headline)
            Text("Changes are re-verified with USPS before they're saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
            AddressFormView()
        }
        .padding(Style.outerPadding)
    }
}
