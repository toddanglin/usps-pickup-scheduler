import SwiftUI

/// Failure screen: what went wrong, what to do about it, and a way out.
struct ErrorView: View {
    let error: USPSError
    let retryable: Bool

    @EnvironmentObject private var state: AppState

    private var suggestsSettings: Bool {
        switch error {
        case .forbidden, .addressNotEligible: return true
        default: return false
        }
    }

    /// True when the fix is in the USPS Developer Portal, not in PickupBar.
    private var suggestsPortal: Bool {
        if case .insufficientScope = error { return true }
        return false
    }

    var body: some View {
        VStack(spacing: Style.sectionSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.orange)

            VStack(spacing: 4) {
                Text(error.title)
                    .accessibilityIdentifier("error.title")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(error.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                if let hint = error.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            CopyButton(text: error.technicalDetails, title: "Copy details", style: .borderless)

            VStack(spacing: 6) {
                if suggestsPortal {
                    // Nothing in the app can grant the missing API product, so
                    // the portal is the only thing worth doing next.
                    Link(destination: USPSPortal.url) {
                        Text(USPSPortal.linkTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("Back") { state.retry() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("error.retry")
                } else if suggestsSettings {
                    // Nothing here is fixable on this screen, so Settings — not
                    // going back — is the thing to do next.
                    SettingsButton { Text("Open Settings").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button(retryable ? "Try again" : "Back") { state.retry() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("error.retry")
                } else {
                    PrimaryButton(retryable ? "Try again" : "Back") { state.retry() }
                        .accessibilityIdentifier("error.retry")
                }
            }
        }
        .padding(Style.outerPadding)
        .frame(maxWidth: .infinity)
    }
}
