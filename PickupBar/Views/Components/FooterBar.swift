import SwiftUI

/// The strip at the bottom of every popover screen: Settings on the left, the
/// active-environment note in the middle, Quit on the right.
struct FooterBar: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Open Settings")

                Spacer(minLength: 0)

                if settings.useTestEnvironment {
                    Text("USPS test environment")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .help("Quit PickupBar")
            }
            .padding(.horizontal, Style.outerPadding)
            .padding(.vertical, 8)
        }
    }
}
