import Foundation

/// The package types the form offers. Raw values are members of the
/// `packages[].packageType` enum in `docs/usps/carrier-pickup-v3.yaml`; the
/// spec's legacy `FIRST-CLASS_PACKAGE_SERVICE` is deliberately not offered.
enum PackageType: String, CaseIterable, Sendable {
    case groundAdvantage = "USPS_GROUND_ADVANTAGE"
    case priorityMail = "PRIORITY_MAIL"
    case priorityMailExpress = "PRIORITY_MAIL_EXPRESS"
    case international = "INTERNATIONAL"
    case returns = "RETURNS"
    case other = "OTHER"

    var displayName: String {
        switch self {
        case .groundAdvantage: return "Ground Advantage"
        case .priorityMail: return "Priority Mail"
        case .priorityMailExpress: return "Priority Mail Express"
        case .international: return "International"
        case .returns: return "Returns"
        case .other: return "Other"
        }
    }
}

extension PackageType: Codable {
    /// Lenient: `FIRST-CLASS_PACKAGE_SERVICE` (Ground Advantage's old name)
    /// maps to `.groundAdvantage`, anything else unknown to `.other`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let known = PackageType(rawValue: raw) {
            self = known
        } else if raw == "FIRST-CLASS_PACKAGE_SERVICE" {
            self = .groundAdvantage
        } else {
            self = .other
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
