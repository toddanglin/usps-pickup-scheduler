import SwiftUI

/// The strip at the bottom of every popover screen: Settings on the left, the
/// active-environment note in the middle, Quit on the right.
struct FooterBar: View {
    @EnvironmentObject private var settings: SettingsStore

    /// The host actually in use, whenever it is not production USPS — the TEM
    /// toggle is only one of the ways that happens (`PICKUPBAR_BASE_URL` points
    /// the app at the mock server), and a footer that only knows about the
    /// toggle would quietly lie.
    private var nonProductionHost: String? {
        let url = BaseURL.resolve(useTestEnvironment: settings.useTestEnvironment)
        guard let host = url.host, host != BaseURL.production.host else { return nil }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                SettingsButton {
                    Label("Settings", systemImage: "gear")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open Settings")
                .accessibilityIdentifier("footer.settings")

                Spacer(minLength: 0)

                if let host = nonProductionHost {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("PickupBar is talking to \(host) instead of production USPS.")
                    Spacer(minLength: 0)
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .help("Quit PickupBar")
                .accessibilityIdentifier("footer.quit")
            }
            .padding(.horizontal, Style.outerPadding)
            .padding(.vertical, 8)
        }
    }
}
