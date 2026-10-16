import SwiftUI

/// Success screen: the confirmation number, the (parsed) pickup date, and a way
/// straight back into a new pickup. After "Modify…" it says "Pickup updated"
/// and leads back to the history instead.
struct ConfirmationView: View {
    let confirmation: PickupConfirmation
    var mode: ConfirmationMode = .scheduled

    @EnvironmentObject private var state: AppState
    @State private var didAppear = false

    var body: some View {
        VStack(spacing: Style.sectionSpacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: didAppear)

            VStack(spacing: 2) {
                Text(mode == .updated ? "Pickup updated" : "Pickup scheduled")
                    .font(.headline)
                    .accessibilityIdentifier("confirmation.title")
                Text(Self.displayDate(confirmation.pickupDate))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Card {
                VStack(spacing: 6) {
                    Text("Confirmation number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(confirmation.confirmationNumber)
                        .accessibilityIdentifier("confirmation.number")
                        .font(.title2.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    CopyButton(text: confirmation.confirmationNumber)
                        .accessibilityIdentifier("confirmation.copy")
                }
                .frame(maxWidth: .infinity)
            }

            Text("USPS emails a confirmation to the address on file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                if mode == .updated {
                    PrimaryButton("Done") { state.showHistory() }
                        .accessibilityIdentifier("confirmation.done")
                    Button("Schedule another pickup") { state.scheduleAnother() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("confirmation.another")
                } else {
                    PrimaryButton("Schedule another pickup") { state.scheduleAnother() }
                        .accessibilityIdentifier("confirmation.another")
                    Button("View scheduled pickups") { state.showHistory() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("confirmation.history")
                }
            }
        }
        .padding(Style.outerPadding)
        .onAppear { didAppear = true }
    }

    /// USPS sends back "yyyy-MM-dd"; show it in long form, falling back to the
    /// raw string if it is ever something else.
    static func displayDate(_ raw: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = PickupDateCalculator.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: raw) else { return raw }
        return PickupDateCalculator.longDisplay(date)
    }
}
