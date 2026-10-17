import Foundation

/// One pickup this app scheduled, kept in the local history
/// (`SettingsStore.history`).
///
/// The USPS Carrier Pickup API has no "list pickups" endpoint — only GET, PUT
/// and DELETE of a single pickup by confirmation number — so the app keeps
/// its own record of the pickups it scheduled. Pickups made on usps.com or in
/// another app never appear here.
struct PickupRecord: Codable, Equatable, Identifiable, Sendable {
    /// What the app last did to the pickup. USPS has no status field — a
    /// cancelled pickup still reads back from GET like a scheduled one — so
    /// this is only ever known locally.
    enum Status: String, Codable, Sendable {
        case scheduled
        case cancelled

        /// Unknown values (from a newer version of the app) read as
        /// `.scheduled`, so the record keeps its actions.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .scheduled
        }
    }

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
    var status: Status = .scheduled
    /// When the pickup was last changed or cancelled from the app.
    var updatedAt: Date?
    /// Nil when unknown (a record written before these were kept).
    var specialInstructions: String?
    /// Nil when unknown (a record written before these were kept).
    var dogPresent: Bool?
    /// The ETag of the last GET or PUT the app saw. POST returns none, so a
    /// newly scheduled pickup has none until it is first checked.
    var etag: String?
    /// The background check found the pickup changed on usps.com. Shown as a
    /// red dot until the list is shown again, or the pickup is modified or
    /// cancelled in the app.
    var changedExternally: Bool = false

    var id: String { confirmationNumber }

    private enum CodingKeys: String, CodingKey {
        case confirmationNumber, pickupDate, createdAt, packages, totalPackages, estimatedWeight,
             location, addressLine, status, updatedAt, specialInstructions, dogPresent, etag,
             changedExternally
    }

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

    /// `status` and `updatedAt` are absent from records written before
    /// modify/cancel existed; the instructions, dog, ETag and change flag
    /// from records written before the background check.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmationNumber = try container.decode(String.self, forKey: .confirmationNumber)
        pickupDate = try container.decode(String.self, forKey: .pickupDate)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        packages = try container.decode([PackageLine].self, forKey: .packages)
        totalPackages = try container.decode(Int.self, forKey: .totalPackages)
        estimatedWeight = try container.decode(Double.self, forKey: .estimatedWeight)
        location = try container.decode(PackageLocation.self, forKey: .location)
        addressLine = try container.decode(String.self, forKey: .addressLine)
        status = (try? container.decodeIfPresent(Status.self, forKey: .status)) ?? .scheduled
        updatedAt = try? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        specialInstructions = try? container.decodeIfPresent(String.self, forKey: .specialInstructions)
        dogPresent = try? container.decodeIfPresent(Bool.self, forKey: .dogPresent)
        etag = try? container.decodeIfPresent(String.self, forKey: .etag)
        changedExternally = (try? container.decodeIfPresent(Bool.self, forKey: .changedExternally)) ?? false
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
        specialInstructions = request.pickupLocation.specialInstructions
        dogPresent = request.pickupLocation.dogPresent
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

    /// True when the pickup is still scheduled and its day (America/Chicago)
    /// is today or later. A date that cannot be parsed counts as upcoming, so
    /// it is never hidden among past pickups by mistake.
    func isUpcoming(asOf now: Date) -> Bool {
        guard status == .scheduled else { return false }
        guard let day = pickupDay else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PickupDateCalculator.timeZone
        return day >= calendar.startOfDay(for: now)
    }

    /// The record after a successful PUT: USPS's date, and what was sent.
    func updated(confirmation: PickupConfirmation, request: SchedulePickupRequest,
                 at date: Date) -> PickupRecord {
        var copy = self
        copy.pickupDate = confirmation.pickupDate
        copy.packages = request.packages
        copy.totalPackages = request.packages.reduce(0) { $0 + $1.packageCount }
        copy.estimatedWeight = request.estimatedWeight
        copy.location = request.pickupLocation.packageLocation
        copy.specialInstructions = request.pickupLocation.specialInstructions
        copy.dogPresent = request.pickupLocation.dogPresent
        copy.status = .scheduled
        copy.updatedAt = date
        copy.changedExternally = false
        return copy
    }

    /// The record brought up to date with what USPS returned for it, and
    /// whether that differs from what the app had: the date, the non-zero
    /// package lines (in any order), the weight, the location, the
    /// instructions (none and empty are the same) or the dog.
    ///
    /// A record the app never saw an ETag for is only compared by date, since
    /// what it stored may predate the fields being kept at all. Every record
    /// with an ETag had them filled in from a request or a GET, so a nil
    /// instruction there means none; an unknown dog is never a difference. `changedExternally`
    /// is left alone: the caller decides what a difference means.
    func merged(with fetched: FetchedPickup) -> (record: PickupRecord, differs: Bool) {
        var copy = self
        copy.pickupDate = fetched.confirmation.pickupDate
        copy.etag = fetched.etag
        var differs = pickupDate != fetched.confirmation.pickupDate

        if let request = fetched.request {
            let fetchedLines = request.packages.filter { $0.packageCount > 0 }
            let linesDiffer = Self.lineCounts(packages) != Self.lineCounts(fetchedLines)
            let fetchedInstructions = request.pickupLocation.specialInstructions?.nonEmptyValue
            let instructionsDiffer = specialInstructions?.nonEmptyValue != fetchedInstructions
            let dogDiffers = dogPresent.map { $0 != request.pickupLocation.dogPresent } ?? false
            if etag != nil {
                differs = differs
                    || linesDiffer
                    || estimatedWeight != request.estimatedWeight
                    || location != request.pickupLocation.packageLocation
                    || instructionsDiffer
                    || dogDiffers
            }
            if linesDiffer {
                copy.packages = fetchedLines
                copy.totalPackages = fetchedLines.reduce(0) { $0 + $1.packageCount }
            }
            copy.estimatedWeight = request.estimatedWeight
            copy.location = request.pickupLocation.packageLocation
            copy.specialInstructions = fetchedInstructions
            copy.dogPresent = request.pickupLocation.dogPresent
        }
        return (copy, differs)
    }

    /// Package count per type, zero lines dropped, so order does not matter.
    private static func lineCounts(_ lines: [PackageLine]) -> [PackageType: Int] {
        lines.reduce(into: [:]) { counts, line in
            if line.packageCount > 0 { counts[line.packageType, default: 0] += line.packageCount }
        }
    }

    /// e.g. "Saturday, October 3"; the raw string if it cannot be parsed.
    var longDisplayDate: String {
        guard let day = pickupDay else { return pickupDate }
        return PickupDateCalculator.longDisplay(day)
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
