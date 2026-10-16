import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    private static let storageKey = "settings.v1"

    @Published var contact: PickupContact? { didSet { persist() } }
    @Published var address: PostalAddress? { didSet { persist() } }
    @Published var defaultLocation: PackageLocation = .frontDoor { didSet { persist() } }
    @Published var defaultInstructions: String = "" { didSet { persist() } }
    @Published var dogPresent: Bool = false { didSet { persist() } }
    @Published var defaultWeight: Double = 1 { didSet { persist() } }
    @Published var useTestEnvironment: Bool = false { didSet { persist() } }
    @Published var lastConfirmation: PickupConfirmation? { didSet { persist() } }
    /// Pickups this app scheduled, newest first, at most `historyLimit`.
    ///
    /// The USPS Carrier Pickup API has no "list pickups" endpoint (only GET,
    /// PUT and DELETE of one pickup by confirmation number), so this local
    /// list is the only record there is. Pickups made on usps.com never
    /// appear in it.
    @Published private(set) var history: [PickupRecord] = [] { didSet { persist() } }

    static let historyLimit = 200

    var isAddressConfigured: Bool { address != nil && contact != nil }

    private let defaults: UserDefaults
    private var isLoading = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isLoading = true
        if let data = defaults.data(forKey: Self.storageKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            contact = snapshot.contact
            address = snapshot.address
            defaultLocation = snapshot.defaultLocation
            defaultInstructions = snapshot.defaultInstructions
            dogPresent = snapshot.dogPresent
            defaultWeight = snapshot.defaultWeight
            useTestEnvironment = snapshot.useTestEnvironment
            lastConfirmation = snapshot.lastConfirmation
            history = snapshot.history
        }
        isLoading = false

        // Settings written before the history existed still remember the last
        // pickup: seed the history with it so that pickup is not lost.
        if history.isEmpty, let last = lastConfirmation {
            history = [PickupRecord(confirmationNumber: last.confirmationNumber,
                                    pickupDate: last.pickupDate,
                                    createdAt: Date(),
                                    packages: [],
                                    estimatedWeight: 0,
                                    location: .frontDoor,
                                    addressLine: PickupRecord.addressLine(address))]
        }
    }

    /// Adds `record` at the top of the history, replacing any earlier record
    /// with the same confirmation number, and drops the oldest beyond
    /// `historyLimit`.
    func addToHistory(_ record: PickupRecord) {
        var updated = history.filter { $0.confirmationNumber != record.confirmationNumber }
        updated.insert(record, at: 0)
        if updated.count > Self.historyLimit {
            updated.removeLast(updated.count - Self.historyLimit)
        }
        history = updated
    }

    /// Replaces the record with `record`'s confirmation number, keeping its
    /// place in the list. Does nothing when there is no such record.
    func updateHistory(_ record: PickupRecord) {
        guard let index = history.firstIndex(where: { $0.confirmationNumber == record.confirmationNumber })
        else { return }
        history[index] = record
    }

    /// Forgets a pickup locally. It stays scheduled with USPS.
    func removeFromHistory(confirmationNumber: String) {
        history.removeAll { $0.confirmationNumber == confirmationNumber }
    }

    func clear() {
        isLoading = true
        contact = nil
        address = nil
        defaultLocation = .frontDoor
        defaultInstructions = ""
        dogPresent = false
        defaultWeight = 1
        useTestEnvironment = false
        lastConfirmation = nil
        history = []
        isLoading = false
        persist()
    }

    private func persist() {
        guard !isLoading else { return }
        let snapshot = Snapshot(
            contact: contact,
            address: address,
            defaultLocation: defaultLocation,
            defaultInstructions: defaultInstructions,
            dogPresent: dogPresent,
            defaultWeight: defaultWeight,
            useTestEnvironment: useTestEnvironment,
            lastConfirmation: lastConfirmation,
            history: history
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Decoded key by key with the store's own defaults, so a snapshot written
    /// by a different version of the app — missing a key, or carrying one this
    /// version does not know — still restores everything it does understand
    /// instead of wiping the user's saved address.
    private struct Snapshot: Codable {
        var contact: PickupContact?
        var address: PostalAddress?
        var defaultLocation: PackageLocation
        var defaultInstructions: String
        var dogPresent: Bool
        var defaultWeight: Double
        var useTestEnvironment: Bool
        var lastConfirmation: PickupConfirmation?
        var history: [PickupRecord]

        init(contact: PickupContact?,
             address: PostalAddress?,
             defaultLocation: PackageLocation,
             defaultInstructions: String,
             dogPresent: Bool,
             defaultWeight: Double,
             useTestEnvironment: Bool,
             lastConfirmation: PickupConfirmation?,
             history: [PickupRecord]) {
            self.contact = contact
            self.address = address
            self.defaultLocation = defaultLocation
            self.defaultInstructions = defaultInstructions
            self.dogPresent = dogPresent
            self.defaultWeight = defaultWeight
            self.useTestEnvironment = useTestEnvironment
            self.lastConfirmation = lastConfirmation
            self.history = history
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contact = try container.decodeIfPresent(PickupContact.self, forKey: .contact)
            address = try container.decodeIfPresent(PostalAddress.self, forKey: .address)
            // Read as a raw string so a retired location (SECURITY_DECK,
            // SHIPPING_DOCK) falls back to the default, not to `.other`, which
            // would block submitting until the user typed instructions.
            let rawLocation = try? container.decodeIfPresent(String.self, forKey: .defaultLocation)
            defaultLocation = rawLocation.flatMap { PackageLocation(lenientRawValue: $0) } ?? .frontDoor
            defaultInstructions = try container.decodeIfPresent(String.self,
                                                                forKey: .defaultInstructions) ?? ""
            dogPresent = try container.decodeIfPresent(Bool.self, forKey: .dogPresent) ?? false
            defaultWeight = try container.decodeIfPresent(Double.self, forKey: .defaultWeight) ?? 1
            useTestEnvironment = try container.decodeIfPresent(Bool.self,
                                                               forKey: .useTestEnvironment) ?? false
            lastConfirmation = try container.decodeIfPresent(PickupConfirmation.self,
                                                             forKey: .lastConfirmation)
            // Absent in snapshots written before the history existed. A list
            // that fails to decode is dropped rather than taking the saved
            // address down with it.
            history = (try? container.decodeIfPresent([PickupRecord].self, forKey: .history)) ?? []
        }
    }
}
