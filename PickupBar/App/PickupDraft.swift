import Foundation

/// The in-progress pickup the form is editing. Converted to a
/// `SchedulePickupRequest` at submit time.
struct PickupDraft: Equatable {
    var selectedDate: Date
    var location: PackageLocation
    var instructions: String
    var dogPresent: Bool
    /// Always carries an entry for every `PackageType`, so the form can bind
    /// directly to `counts[type]`.
    var counts: [PackageType: Int]
    /// Pounds.
    var weight: Double
    var hazmatConfirmed: Bool = false

    var totalPackages: Int { counts.values.reduce(0, +) }

    /// USPS requires special instructions when the location is `.other`.
    var instructionsMissing: Bool {
        location == .other && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSubmit: Bool { totalPackages > 0 && weight > 0 && hazmatConfirmed && !instructionsMissing }

    /// A fresh draft: the next available pickup day, and the user's saved
    /// location/instructions/dog/weight defaults, with all counts at zero.
    @MainActor
    static func fromDefaults(_ settings: SettingsStore, now: Date = Date()) -> PickupDraft {
        var counts: [PackageType: Int] = [:]
        for type in PackageType.allCases { counts[type] = 0 }
        return PickupDraft(
            selectedDate: PickupDateCalculator.availableDates(from: now, count: 1)[0],
            location: settings.defaultLocation,
            instructions: settings.defaultInstructions,
            dogPresent: settings.dogPresent,
            counts: counts,
            weight: settings.defaultWeight,
            hazmatConfirmed: false)
    }

    /// A draft for changing an existing pickup: what USPS has for it, or,
    /// when USPS's copy could not be read, what PickupBar recorded. The day
    /// stays selected only if it is still on offer (`availableDates`);
    /// otherwise the first available day is. The hazmat promise is never
    /// carried over.
    @MainActor
    static func forModifying(_ record: PickupRecord, fetched: SchedulePickupRequest?,
                             settings: SettingsStore, now: Date = Date()) -> PickupDraft {
        var draft = fromDefaults(settings, now: now)
        let lines = fetched?.packages ?? record.packages
        for line in lines { draft.counts[line.packageType, default: 0] += line.packageCount }
        if let fetched {
            draft.location = fetched.pickupLocation.packageLocation
            draft.instructions = fetched.pickupLocation.specialInstructions ?? ""
            draft.dogPresent = fetched.pickupLocation.dogPresent
            draft.weight = fetched.estimatedWeight
        } else {
            draft.location = record.location
            if record.estimatedWeight > 0 { draft.weight = record.estimatedWeight }
        }
        let wanted = fetched?.pickupDate ?? record.pickupDate
        let offered = PickupDateCalculator.availableDates(from: now)
        draft.selectedDate = offered.first { PickupDateCalculator.apiDateString($0) == wanted } ?? offered[0]
        draft.hazmatConfirmed = false
        return draft
    }

    /// Builds the USPS wire request. Only package types with a count above
    /// zero are included, in `PackageType.allCases` order. A change to an
    /// existing pickup passes `nextAvailablePickup: false`: it names its day.
    func request(address: PostalAddress, contact: PickupContact,
                 nextAvailablePickup: Bool = true) -> SchedulePickupRequest {
        let packages: [PackageLine] = PackageType.allCases.compactMap { type in
            let count = counts[type] ?? 0
            guard count > 0 else { return nil }
            return PackageLine(packageType: type, packageCount: count)
        }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return SchedulePickupRequest(
            pickupDate: PickupDateCalculator.apiDateString(selectedDate),
            pickupAddress: PickupAddress(contact: contact, address: address),
            packages: packages,
            estimatedWeight: weight,
            pickupLocation: PickupLocation(packageLocation: location,
                                           specialInstructions: trimmed.isEmpty ? nil : trimmed,
                                           dogPresent: dogPresent),
            nextAvailablePickup: nextAvailablePickup)
    }
}
