import Foundation

/// A single package-type line in a pickup request. Unknown package types
/// decode as `.other` (see `PackageType`). USPS returns
/// `packageCount` as either a JSON number or a numeric string, so decoding
/// accepts both; encoding always writes a JSON number.
struct PackageLine: Codable, Equatable, Sendable {
    var packageType: PackageType
    var packageCount: Int

    private enum CodingKeys: String, CodingKey {
        case packageType
        case packageCount
    }

    init(packageType: PackageType, packageCount: Int) {
        self.packageType = packageType
        self.packageCount = packageCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageType = try container.decode(PackageType.self, forKey: .packageType)
        if let intValue = try? container.decode(Int.self, forKey: .packageCount) {
            packageCount = intValue
        } else {
            let stringValue = try container.decode(String.self, forKey: .packageCount)
            guard let parsed = Int(stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .packageCount, in: container,
                    debugDescription: "packageCount was neither an Int nor an Int-parseable String")
            }
            packageCount = parsed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageType, forKey: .packageType)
        try container.encode(packageCount, forKey: .packageCount)
    }
}

/// `specialInstructions` is required by USPS when `packageLocation` is
/// `.other`; `PickupDraft.canSubmit` enforces that.
struct PickupLocation: Codable, Equatable, Sendable {
    var packageLocation: PackageLocation
    var specialInstructions: String?
    var dogPresent: Bool

    private enum CodingKeys: String, CodingKey {
        case packageLocation, specialInstructions, dogPresent
    }

    init(packageLocation: PackageLocation, specialInstructions: String?, dogPresent: Bool) {
        self.packageLocation = packageLocation
        self.specialInstructions = specialInstructions
        self.dogPresent = dogPresent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageLocation = try container.decode(PackageLocation.self, forKey: .packageLocation)
        specialInstructions = try container.decodeIfPresent(String.self, forKey: .specialInstructions)
        dogPresent = try container.decodeIfPresent(Bool.self, forKey: .dogPresent) ?? false
    }

    /// Empty instructions are omitted, never sent as `null` or `""`.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(packageLocation, forKey: .packageLocation)
        try container.encodeIfPresent(specialInstructions?.nonEmptyValue, forKey: .specialInstructions)
        try container.encode(dogPresent, forKey: .dogPresent)
    }
}

struct SchedulePickupRequest: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd"
    var pickupDate: String
    var pickupAddress: PickupAddress
    /// Only lines with count > 0 should be included.
    var packages: [PackageLine]
    /// Pounds.
    var estimatedWeight: Double
    var pickupLocation: PickupLocation
    var nextAvailablePickup: Bool
}

/// Decoded leniently: only the top-level `confirmationNumber` and `pickupDate`
/// are read. USPS returns two different response shapes (flat, and nested
/// under `carrierPickupRequest`), and any other fields are ignored.
struct PickupConfirmation: Codable, Equatable, Sendable {
    var confirmationNumber: String
    var pickupDate: String
}

struct USPSErrorBody: Codable, Sendable {
    struct Detail: Codable, Sendable {
        var code: String?
        var message: String?
        var title: String?
        var detail: String?
    }

    struct Inner: Codable, Sendable {
        var code: String?
        var message: String?
        var errors: [Detail]?
    }

    var apiVersion: String?
    var error: Inner?
}
