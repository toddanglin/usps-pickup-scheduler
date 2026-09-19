import SwiftUI

/// The USPS Developer Portal, where the Carrier Pickup product is added.
enum USPSPortal {
    static let url = URL(string: "https://developers.usps.com")!
    static let linkTitle = "Open USPS Developer Portal"
}

/// Yellow banner shown while the stored credentials belong to a USPS app
/// without the Carrier Pickup product: scheduling will fail, and the fix lives
/// in the developer portal rather than in PickupBar.
///
/// `compact` drops the hint, for screens that only have room for a nudge.
struct ScopeWarningBanner: View {
    let error: USPSError
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.title)
                    .font(.callout.weight(.medium))
                if !compact, let hint = error.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link(USPSPortal.linkTitle, destination: USPSPortal.url)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("scope.warning")
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                .fill(Color.yellow.opacity(0.15))
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
