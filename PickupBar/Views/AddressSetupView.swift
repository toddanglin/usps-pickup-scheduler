import SwiftUI

/// Second onboarding step: the pickup address, verified against USPS.
struct AddressSetupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Where should we pick up?")
                    .font(.headline)
                Text("USPS will verify this address is eligible for carrier pickup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AddressFormView()
        }
        .padding(Style.outerPadding)
    }
}
