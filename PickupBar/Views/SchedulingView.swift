import SwiftUI

/// Shown while the schedule request is in flight.
struct SchedulingView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            Image(systemName: "envelope.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, isActive: isAnimating)

            VStack(spacing: 4) {
                Text("Scheduling your pickup…")
                    .font(.headline)
                Text("Talking to USPS")
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
