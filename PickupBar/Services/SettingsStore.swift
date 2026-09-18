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
        }
        isLoading = false
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
            lastConfirmation: lastConfirmation
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

        init(contact: PickupContact?,
             address: PostalAddress?,
             defaultLocation: PackageLocation,
             defaultInstructions: String,
             dogPresent: Bool,
             defaultWeight: Double,
             useTestEnvironment: Bool,
             lastConfirmation: PickupConfirmation?) {
            self.contact = contact
            self.address = address
            self.defaultLocation = defaultLocation
            self.defaultInstructions = defaultInstructions
            self.dogPresent = dogPresent
            self.defaultWeight = defaultWeight
            self.useTestEnvironment = useTestEnvironment
            self.lastConfirmation = lastConfirmation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            contact = try container.decodeIfPresent(PickupContact.self, forKey: .contact)
            address = try container.decodeIfPresent(PostalAddress.self, forKey: .address)
            defaultLocation = try container.decodeIfPresent(PackageLocation.self,
                                                            forKey: .defaultLocation) ?? .frontDoor
            defaultInstructions = try container.decodeIfPresent(String.self,
                                                                forKey: .defaultInstructions) ?? ""
            dogPresent = try container.decodeIfPresent(Bool.self, forKey: .dogPresent) ?? false
            defaultWeight = try container.decodeIfPresent(Double.self, forKey: .defaultWeight) ?? 1
            useTestEnvironment = try container.decodeIfPresent(Bool.self,
                                                               forKey: .useTestEnvironment) ?? false
            lastConfirmation = try container.decodeIfPresent(PickupConfirmation.self,
                                                             forKey: .lastConfirmation)
        }
    }
}
