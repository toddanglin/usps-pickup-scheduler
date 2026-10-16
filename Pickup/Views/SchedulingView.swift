import SwiftUI

/// Shown while a USPS request is in flight: scheduling, loading, updating or
/// cancelling a pickup.
struct SchedulingView: View {
    /// e.g. "Scheduling your pickup…".
    var title: String
    var caption: String = "Talking to USPS"

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "envelope.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: isAnimating)

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityIdentifier("working.title")
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 260)
        .padding(Style.outerPadding)
        .onAppear { isAnimating = true }
    }
}
