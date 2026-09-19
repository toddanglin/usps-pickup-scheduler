import SwiftUI

/// Success screen: the confirmation number, the (parsed) pickup date, and a way
/// straight back into a new pickup.
struct ConfirmationView: View {
    let confirmation: PickupConfirmation

    @EnvironmentObject private var state: AppState
    @State private var didAppear = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Style.sectionSpacing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: didAppear)

            VStack(spacing: 2) {
                Text("Pickup scheduled")
                    .font(.headline)
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
                    Button(didCopy ? "Copied" : "Copy", action: copy)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("confirmation.copy")
                }
                .frame(maxWidth: .infinity)
            }

            Text("USPS emails a confirmation to the address on file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            PrimaryButton("Schedule another pickup") { state.scheduleAnother() }
                .accessibilityIdentifier("confirmation.another")
        }
        .padding(Style.outerPadding)
        .onAppear { didAppear = true }
        .onDisappear { copyResetTask?.cancel() }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(confirmation.confirmationNumber, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
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
