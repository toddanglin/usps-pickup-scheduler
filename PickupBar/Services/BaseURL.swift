import Foundation

/// Which USPS host the app talks to.
enum BaseURL {
    static let production = URL(string: "https://apis.usps.com")!
    static let test = URL(string: "https://apis-tem.usps.com")!

    /// Precedence: the `PICKUPBAR_BASE_URL` environment variable (used to point
    /// the app at `Scripts/mock-server.py`), then the TEM settings toggle, then
    /// production.
    static func resolve(useTestEnvironment: Bool,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["PICKUPBAR_BASE_URL"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil {
                return url
            }
        }
        return useTestEnvironment ? test : production
    }
}
