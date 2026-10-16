import Foundation

/// Which USPS host the app talks to.
enum BaseURL {
    static let production = URL(string: "https://apis.usps.com")!
    static let test = URL(string: "https://apis-tem.usps.com")!

    /// Precedence: the `PICKUP_BASE_URL` environment variable (used to point
    /// the app at `Scripts/mock-server.py`), then the TEM settings toggle, then
    /// production.
    static func resolve(useTestEnvironment: Bool,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["PICKUP_BASE_URL"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Anything that is not an absolute http(s) URL with a host is
            // ignored: "localhost:8787", for example, parses as a URL whose
            // scheme is "localhost".
            if !trimmed.isEmpty,
               let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               let host = url.host, !host.isEmpty {
                return url
            }
        }
        return useTestEnvironment ? test : production
    }
}
