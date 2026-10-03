import Foundation

/// One pickup this app scheduled, kept in the local history
/// (`SettingsStore.history`).
///
/// The USPS Carrier Pickup API has no "list pickups" endpoint — only GET, PUT
/// and DELETE of a single pickup by confirmation number — so PickupBar keeps
/// its own record of the pickups it scheduled. Pickups made on usps.com or in
/// another app never appear here.
struct PickupRecord: Codable, Equatable, Identifiable, Sendable {
    var confirmationNumber: String
    /// "yyyy-MM-dd", as USPS confirmed it (which may differ from the date the
    /// user asked for).
    var pickupDate: String
    var createdAt: Date
    /// Empty when unknown (a record migrated from `lastConfirmation`).
    var packages: [PackageLine]
    var totalPackages: Int
    /// Pounds; 0 when unknown.
    var estimatedWeight: Double
    var location: PackageLocation
    /// e.g. "43 S SPRING TRELLIS CIR, THE WOODLANDS TX".
    var addressLine: String

    var id: String { confirmationNumber }

    init(confirmationNumber: String,
         pickupDate: String,
         createdAt: Date,
         packages: [PackageLine],
         totalPackages: Int? = nil,
         estimatedWeight: Double,
         location: PackageLocation,
         addressLine: String) {
        self.confirmationNumber = confirmationNumber
        self.pickupDate = pickupDate
        self.createdAt = createdAt
        self.packages = packages
        self.totalPackages = totalPackages ?? packages.reduce(0) { $0 + $1.packageCount }
        self.estimatedWeight = estimatedWeight
        self.location = location
        self.addressLine = addressLine
    }

    /// The record for a pickup that was just scheduled from `request`.
    init(confirmation: PickupConfirmation, request: SchedulePickupRequest, createdAt: Date) {
        self.init(confirmationNumber: confirmation.confirmationNumber,
                  pickupDate: confirmation.pickupDate,
                  createdAt: createdAt,
                  packages: request.packages,
                  estimatedWeight: request.estimatedWeight,
                  location: request.pickupLocation.packageLocation,
                  addressLine: Self.addressLine(request.pickupAddress.address))
    }

    /// "STREET, CITY ST", the one-line address the history shows.
    static func addressLine(_ address: PostalAddress?) -> String {
        guard let address else { return "" }
        return "\(address.streetAddress), \(address.city) \(address.state)"
    }

    /// The pickup day, parsed in America/Chicago. Nil if `pickupDate` is not
    /// "yyyy-MM-dd".
    var pickupDay: Date? {
        let parser = DateFormatter()
        parser.timeZone = PickupDateCalculator.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser.date(from: pickupDate)
    }

    /// True when the pickup day (America/Chicago) is today or later. A date
    /// that cannot be parsed counts as upcoming, so it is never hidden among
    /// past pickups by mistake.
    func isUpcoming(asOf now: Date) -> Bool {
        guard let day = pickupDay else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PickupDateCalculator.timeZone
        return day >= calendar.startOfDay(for: now)
    }

    /// e.g. "Sat, Oct 3"; the raw string if it cannot be parsed.
    var shortDisplayDate: String {
        guard let day = pickupDay else { return pickupDate }
        let display = DateFormatter()
        display.timeZone = PickupDateCalculator.timeZone
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "EEE, MMM d"
        return display.string(from: day)
    }

    /// e.g. "2 Priority Mail, 1 Ground Advantage"; "—" when unknown.
    var packageSummary: String {
        guard !packages.isEmpty else { return "—" }
        return packages
            .map { "\($0.packageCount) \($0.packageType.displayName)" }
            .joined(separator: ", ")
    }
}
