import SwiftUI

/// Settings › Address: the same form the onboarding step uses, minus the
/// "Continue" button — there is nowhere to continue to from here, so a change
/// just leaves the verified-address banner on screen.
struct AddressSettingsTab: View {
    var body: some View {
        ScrollView {
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
}
