import SwiftUI

/// Second onboarding step: the pickup address, verified against USPS.
struct AddressSetupView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            // Better to learn about a missing API product here than by having
            // Validate fail for a reason that is not about the address.
            if let warning = state.scopeWarning {
                ScopeWarningBanner(error: warning)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Where should we pick up?")
                    .font(.headline)
                Text("USPS will verify this address is eligible for carrier pickup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The verified-address banner is worth reading, so the flow waits
            // here until the user continues rather than jumping to the form.
            AddressFormView(continueAction: { state.finishAddressSetup() })
        }
        .padding(Style.outerPadding)
    }
}
