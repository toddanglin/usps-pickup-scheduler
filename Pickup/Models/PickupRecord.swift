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

    /// The record for a pickup that was just scheduled from `request`:
    /// USPS's own copy of it (`confirmation.request`) when the response had
    /// one, else what was sent. The date is always the confirmation's, since
    /// USPS may move the pickup and the echoed copy keeps the requested day.
    init(confirmation: PickupConfirmation, request: SchedulePickupRequest, createdAt: Date) {
        let copy = confirmation.request ?? request
        self.init(confirmationNumber: confirmation.confirmationNumber,
                  pickupDate: confirmation.pickupDate,
                  createdAt: createdAt,
                  packages: Self.storedLines(copy.packages, preferring: request.packages),
                  estimatedWeight: copy.estimatedWeight,
                  location: copy.pickupLocation.packageLocation,
                  addressLine: Self.addressLine(copy.pickupAddress.address))
        specialInstructions = copy.pickupLocation.specialInstructions
        dogPresent = copy.pickupLocation.dogPresent
    }

    /// `lines` without zero counts; `preferred` (what was sent, in the
    /// user's order) instead when it holds the same counts.
    private static func storedLines(_ lines: [PackageLine],
                                    preferring preferred: [PackageLine]) -> [PackageLine] {
        if lineCounts(lines) == lineCounts(preferred) {
            return preferred.filter { $0.packageCount > 0 }
        }
        return lines.filter { $0.packageCount > 0 }
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

    /// The record after a successful PUT: USPS's date, and USPS's copy of
    /// the pickup (`echoed`, from the PUT response) or, without one, what
    /// was sent.
    func updated(confirmation: PickupConfirmation, request: SchedulePickupRequest,
                 echoed: SchedulePickupRequest? = nil, at date: Date) -> PickupRecord {
        let source = echoed ?? request
        var copy = self
        copy.pickupDate = confirmation.pickupDate
        copy.packages = Self.storedLines(source.packages, preferring: request.packages)
        copy.totalPackages = copy.packages.reduce(0) { $0 + $1.packageCount }
        copy.estimatedWeight = source.estimatedWeight
        copy.location = source.pickupLocation.packageLocation
        copy.specialInstructions = source.pickupLocation.specialInstructions
        copy.dogPresent = source.pickupLocation.dogPresent
        copy.status = .scheduled
        copy.updatedAt = date
        copy.changedExternally = false
        return copy
    }

    /// The record brought up to date with what USPS returned for it, and
    /// whether that differs from what the app had.
    ///
    /// USPS normalizes what it is sent (seen live on apis-tem.usps.com): the
    /// weight comes back rounded *up* to a whole pound (3.5 → 4); names,
    /// addresses, emails and instructions upper-cased; and `dogPresent`
    /// missing when false. So the comparison is of the pickup, not the bytes:
    /// the date exactly; the non-zero package lines as counts per type, in
    /// any order; the weight by `sameWeight`; the location exactly; the
    /// instructions by `sameInstructions`; and the dog, a missing one being
    /// no dog (an unknown dog on an old record is never a difference).
    ///
    /// First contact never differs: a record the app holds no ETag for (any
    /// pickup scheduled with POST, which returns none, and records from
    /// older versions) has never been compared with USPS's copy, so whatever
    /// USPS has is adopted silently, date included. `changedExternally` is
    /// left alone: the caller decides what a difference means.
    func merged(with fetched: FetchedPickup) -> (record: PickupRecord, differs: Bool) {
        let isFirstContact = etag == nil
        var copy = self
        copy.pickupDate = fetched.confirmation.pickupDate
        copy.etag = fetched.etag
        var differs = pickupDate != fetched.confirmation.pickupDate

        if let request = fetched.request {
            let fetchedLines = request.packages.filter { $0.packageCount > 0 }
            let linesDiffer = Self.lineCounts(packages) != Self.lineCounts(fetchedLines)
            let fetchedInstructions = request.pickupLocation.specialInstructions?.nonEmptyValue
            let dogDiffers = dogPresent.map { $0 != request.pickupLocation.dogPresent } ?? false
            differs = differs
                || linesDiffer
                || !Self.sameWeight(estimatedWeight, request.estimatedWeight)
                || location != request.pickupLocation.packageLocation
                || !Self.sameInstructions(specialInstructions, fetchedInstructions)
                || dogDiffers
            if linesDiffer {
                copy.packages = fetchedLines
                copy.totalPackages = fetchedLines.reduce(0) { $0 + $1.packageCount }
            }
            copy.estimatedWeight = request.estimatedWeight
            copy.location = request.pickupLocation.packageLocation
            copy.specialInstructions = fetchedInstructions
            copy.dogPresent = request.pickupLocation.dogPresent
        }
        return (copy, differs && !isFirstContact)
    }

    /// Whether two weights are the same to USPS, which keeps whole pounds
    /// and rounds up: equal when both round up to the same pound (3.5 and 4
    /// are; 2 and 3.2 are not).
    static func sameWeight(_ a: Double, _ b: Double) -> Bool {
        a.rounded(.up) == b.rounded(.up)
    }

    /// Whether two special instructions say the same thing: compared
    /// trimmed and ignoring case (USPS upper-cases them), with none, empty
    /// and blank all the same.
    static func sameInstructions(_ a: String?, _ b: String?) -> Bool {
        func normalized(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        return normalized(a) == normalized(b)
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
