import SwiftUI

/// The USPS pages PickupBar links to.
enum USPSLinks {
    /// The USPS Developer Portal, where apps are registered and the Carrier
    /// Pickup product is added.
    static let developerPortal = URL(string: "https://developers.usps.com")!
    static let developerPortalTitle = "Open USPS Developer Portal"
    /// The Terms of Use the Carrier Pickup API spec itself links.
    static let termsOfUse = URL(string: "https://about.usps.com/termsofuse.htm")!
    /// Publication 52, Hazardous, Restricted, and Perishable Mail.
    static let publication52 = URL(string: "https://pe.usps.com/text/pub52/welcome.htm")!
}

/// A small secondary caption with one phrase linked, e.g. the terms note under
/// "Verify & Save". The rest of the sentence stays plain text.
struct LinkedCaption: View {
    let before: String
    let linkText: String
    let url: URL
    let after: String
    var alignment: TextAlignment = .leading

    var body: some View {
        Text(attributed)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var link = AttributedString(linkText)
        link.link = url
        return AttributedString(before) + link + AttributedString(after)
    }
}

extension LinkedCaption {
    /// "By connecting, you agree to use PickupBar in line with the USPS API
    /// Terms of Use and USPS mailing rules." The USPS API has no terms field:
    /// this is a reminder, not an acceptance PickupBar records.
    static func termsNote(alignment: TextAlignment = .leading) -> LinkedCaption {
        LinkedCaption(before: "By connecting, you agree to use PickupBar in line with the ",
                      linkText: "USPS API Terms of Use",
                      url: USPSLinks.termsOfUse,
                      after: " and USPS mailing rules.",
                      alignment: alignment)
    }

    /// Shown under the hazmat checkbox. The USPS API has no hazmat field
    /// either: the checkbox is a reminder only.
    static var publication52Note: LinkedCaption {
        LinkedCaption(before: "Not sure? See ",
                      linkText: "USPS Publication 52",
                      url: USPSLinks.publication52,
                      after: " for what counts as hazardous (lithium batteries, perfume, aerosols, …).")
    }
}
