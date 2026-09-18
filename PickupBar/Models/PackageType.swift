import Foundation

enum PackageType: String, CaseIterable, Codable, Sendable {
    case groundAdvantage = "FIRST-CLASS_PACKAGE_SERVICE"
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
