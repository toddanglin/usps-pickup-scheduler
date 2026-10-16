import Foundation

/// Every failure the app surfaces from a USPS call, already translated from
/// HTTP/transport details into something a view can render.
enum USPSError: Error, Equatable, Sendable {
    case offline
    case invalidCredentials
    case forbidden
    /// The credentials are valid, but the USPS app behind them has no Carrier
    /// Pickup product, so the token it is issued carries no `carrier-pickup` scope.
    /// `granted` is the scope list from the token, empty when it is unknown.
    case insufficientScope(granted: [String])
    case rateLimited
    case serviceUnavailable
    case badRequest(message: String, details: [String])
    case addressNotEligible(message: String)
    /// A 404 on a single pickup: USPS has no pickup with that confirmation
    /// number (in this environment).
    case notFound(message: String)
    case unexpected(status: Int, body: String)
    case decoding(String)
}

extension USPSError {
    var title: String {
        switch self {
        case .offline:
            return "You're offline"
        case .invalidCredentials:
            return "USPS rejected your API credentials"
        case .forbidden, .insufficientScope:
            return "Your USPS app can't access Carrier Pickup"
        case .rateLimited:
            return "Slow down a little"
        case .serviceUnavailable:
            return "USPS is having trouble"
        case .badRequest:
            if isAlreadyCancelled { return "This pickup is already cancelled" }
            if isStaleETag { return "USPS couldn't update this pickup" }
            return "USPS couldn't schedule this pickup"
        case .addressNotEligible:
            return "This address isn't eligible for pickup"
        case .notFound:
            return "Pickup not found"
        case .unexpected, .decoding:
            return "Something unexpected happened"
        }
    }

    var message: String {
        switch self {
        case .offline:
            return "PickupBar couldn't reach USPS."
        case .invalidCredentials:
            return "The Consumer Key or Secret is wrong, expired, or was revoked."
        case .forbidden:
            return "USPS returned 403 Forbidden."
        case .insufficientScope:
            return "Your credentials are valid, but the USPS app they belong to doesn't include the Carrier Pickup API product."
        case .rateLimited:
            return "USPS is rate-limiting requests from this app."
        case .serviceUnavailable:
            return "The USPS API is temporarily unavailable."
        case .badRequest(let message, _):
            return message
        case .addressNotEligible(let message):
            return message
        case .notFound(let message):
            return message
        case .unexpected(let status, let body):
            // status 0 means a transport-level failure, where the body carries
            // the only human-readable description we have.
            return status == 0 ? body : "USPS returned status \(status)."
        case .decoding:
            return "PickupBar couldn't read the USPS response."
        }
    }

    var hint: String? {
        switch self {
        case .offline:
            return "Check your connection and try again."
        case .invalidCredentials:
            return "Open Settings › Account to update them."
        case .forbidden:
            return "In the USPS developer portal, make sure your app includes the Carrier Pickup (carrier-pickup) product, or contact USPS API Support."
        case .insufficientScope:
            return "In the USPS Developer Portal, open your app and add the Carrier Pickup (carrier-pickup) API product, "
                + "or ask USPS API Support to enable it. Then quit and reopen PickupBar."
        case .rateLimited:
            return "Wait a minute and try again."
        case .serviceUnavailable:
            return "Try again in a few minutes."
        case .badRequest(let message, let details):
            if isAlreadyCancelled { return "It's already cancelled with USPS — you can remove it from the list." }
            if isStaleETag { return "The pickup changed on USPS's side. Try again." }
            if message.lowercased().contains("date is in the past") {
                return "USPS can't change or cancel a pickup whose day has passed."
            }
            return details.isEmpty ? nil : details.joined(separator: "\n")
        case .addressNotEligible:
            return "Double-check the address, or schedule at usps.com to see alternatives."
        case .notFound:
            return "It may belong to the other USPS environment (production vs. TEM), or USPS no longer has it. "
                + "You can remove it from the list."
        case .unexpected:
            return "Copy the details and open an issue if this keeps happening."
        case .decoding:
            // A decode failure follows a 2xx, so the pickup was most likely
            // created even though we could not read the response.
            return "The pickup may still have been scheduled. Check usps.com before scheduling again."
        }
    }

    /// USPS's 400 "Pickup already cancelled." (error code 1401) on a DELETE.
    var isAlreadyCancelled: Bool {
        guard case .badRequest(let message, _) = self else { return false }
        return message.lowercased().contains("already cancelled")
    }

    /// USPS's 400 "…has been modified since the update indicated by the
    /// If-Match request header." — the ETag sent was stale.
    var isStaleETag: Bool {
        guard case .badRequest(let message, _) = self else { return false }
        return message.lowercased().contains("modified since")
    }

    /// Whether the failing operation is worth offering a "Try again" button for.
    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .serviceUnavailable, .unexpected:
            return true
        case .badRequest:
            // A stale ETag only means USPS's copy moved on; a fresh GET fixes it.
            return isStaleETag
        // `.decoding` is not retryable: it can only happen after a 2xx, so
        // retrying risks scheduling a second pickup.
        case .invalidCredentials, .forbidden, .insufficientScope,
             .addressNotEligible, .notFound, .decoding:
            return false
        }
    }

    /// Case name used in `technicalDetails`.
    private var caseName: String {
        switch self {
        case .offline: return "offline"
        case .invalidCredentials: return "invalidCredentials"
        case .forbidden: return "forbidden"
        case .insufficientScope: return "insufficientScope"
        case .rateLimited: return "rateLimited"
        case .serviceUnavailable: return "serviceUnavailable"
        case .badRequest: return "badRequest"
        case .addressNotEligible: return "addressNotEligible"
        case .notFound: return "notFound"
        case .unexpected: return "unexpected"
        case .decoding: return "decoding"
        }
    }

    /// Multi-line, copy-pasteable diagnostics for a bug report.
    var technicalDetails: String {
        var lines = ["PickupBar \(caseName)"]
        switch self {
        case .offline, .invalidCredentials, .forbidden, .rateLimited, .serviceUnavailable:
            break
        case .insufficientScope(let granted):
            lines.append("status: 401")
            lines.append("granted scopes: \(granted.isEmpty ? "unknown" : granted.joined(separator: " "))")
        case .badRequest(let message, let details):
            lines.append("status: 400")
            lines.append("message: \(message)")
            for detail in details { lines.append("detail: \(detail)") }
        case .addressNotEligible(let message):
            lines.append("status: 400")
            lines.append("message: \(message)")
        case .notFound(let message):
            lines.append("status: 404")
            lines.append("message: \(message)")
        case .unexpected(let status, let body):
            lines.append("status: \(status)")
            lines.append("body: \(body)")
        case .decoding(let description):
            lines.append("decoding: \(description)")
        }
        return lines.joined(separator: "\n")
    }
}
