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

    /// Builds the USPS wire request. Only package types with a count above
    /// zero are included, in `PackageType.allCases` order.
    func request(address: PostalAddress, contact: PickupContact) -> SchedulePickupRequest {
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
            nextAvailablePickup: true)
    }
}
