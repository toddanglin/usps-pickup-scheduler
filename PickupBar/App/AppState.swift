import Foundation
import Combine

/// The app's flow state machine: owns the current screen, the draft the form is
/// editing, and every USPS call the UI triggers.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var flow: FlowState
    @Published var draft: PickupDraft
    @Published private(set) var needsAttention = false
    @Published private(set) var credentialsStatus: CredentialsStatus = .unknown

    let settings: SettingsStore

    private let keychain: KeychainStoring
    private let apiFactory: (URL) -> USPSAPI
    private let notifier: Notifying
    private let now: () -> Date

    private var api: USPSAPI
    private let tokens: TokenManager

    private var hasStarted = false
    /// True once the current invalid-credentials episode has been notified.
    /// Reset when credentials verify again.
    private var didNotifyInvalidCredentials = false
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore,
         keychain: KeychainStoring,
         apiFactory: @escaping (URL) -> USPSAPI,
         notifier: Notifying,
         now: @escaping () -> Date = { Date() }) {
        self.settings = settings
        self.keychain = keychain
        self.apiFactory = apiFactory
        self.notifier = notifier
        self.now = now

        let api = apiFactory(BaseURL.resolve(useTestEnvironment: settings.useTestEnvironment))
        self.api = api
        self.tokens = TokenManager(api: api, credentials: { try? keychain.loadCredentials() })

        self.flow = .needsCredentials
        self.draft = PickupDraft.fromDefaults(settings, now: now())

        // Rebuild the client whenever the TEM toggle flips, so settings UI does
        // not have to remember to call `environmentChanged()`.
        settings.$useTestEnvironment
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.environmentChanged() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Launch

    /// Picks the initial screen and, when credentials exist, verifies them in
    /// the background. Safe to call more than once; only the first call acts.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let stored: (id: String, secret: String)? = try? keychain.loadCredentials()
        guard stored != nil else {
            credentialsStatus = .missing
            flow = .needsCredentials
            return
        }

        credentialsStatus = .checking
        flow = settings.isAddressConfigured ? .form : .needsAddress
        draft = PickupDraft.fromDefaults(settings, now: now())

        Task { await verifyStoredCredentials() }
    }

    private func verifyStoredCredentials() async {
        do {
            _ = try await tokens.validToken()
            credentialsStatus = .valid
            didNotifyInvalidCredentials = false
        } catch USPSError.invalidCredentials {
            handleInvalidCredentials()
        } catch {
            // Offline or a transient USPS failure tells us nothing about the
            // credentials themselves.
            credentialsStatus = .unknown
        }
    }

    // MARK: - Credentials

    /// Verifies `id`/`secret` with a direct token fetch (bypassing the cached
    /// manager), then stores them. Throws on failure and leaves `flow` alone so
    /// the onboarding screen can show an inline error.
    func saveCredentials(id: String, secret: String) async throws {
        _ = try await api.fetchToken(clientID: id, clientSecret: secret)
        try keychain.saveCredentials(id: id, secret: secret)
        await tokens.invalidate()
        credentialsStatus = .valid
        needsAttention = false
        didNotifyInvalidCredentials = false
        flow = settings.isAddressConfigured ? .form : .needsAddress
    }

    /// Forgets the stored credentials and returns to onboarding.
    func removeCredentials() {
        try? keychain.deleteCredentials()
        Task { await tokens.invalidate() }
        credentialsStatus = .missing
        flow = .needsCredentials
    }

    // MARK: - Address

    /// Runs the eligibility check and stores the USPS-standardized address plus
    /// the contact. Returns the standardized address so the caller can show it.
    @discardableResult
    func validateAndSaveAddress(contact: PickupContact,
                                address: PostalAddress) async throws -> PostalAddress {
        do {
            let token = try await tokens.validToken()
            let standardized = try await api.checkEligibility(address, token: token)
            settings.address = standardized
            settings.contact = contact
            if flow == .needsAddress { flow = .form }
            return standardized
        } catch USPSError.invalidCredentials {
            handleInvalidCredentials()
            throw USPSError.invalidCredentials
        }
    }

    // MARK: - Scheduling

    /// Submits `draft`. A draft that cannot be submitted, or missing
    /// address/contact settings, is a no-op.
    func schedule() async {
        guard draft.canSubmit,
              let address = settings.address,
              let contact = settings.contact else { return }

        flow = .scheduling
        do {
            let token = try await tokens.validToken()
            let confirmation = try await api.schedulePickup(
                draft.request(address: address, contact: contact), token: token)
            settings.lastConfirmation = confirmation
            flow = .confirmed(confirmation)
        } catch let error as USPSError {
            if error == .invalidCredentials {
                handleInvalidCredentials()
            } else {
                flow = .failed(error, retryable: error.isRetryable)
            }
        } catch {
            flow = .failed(.unexpected(status: 0, body: "\(error)"), retryable: true)
        }
    }

    /// Confirmation screen → a fresh form.
    func scheduleAnother() {
        draft = PickupDraft.fromDefaults(settings, now: now())
        flow = .form
    }

    /// Error screen → back to the form, keeping what the user entered.
    func retry() {
        flow = .form
    }

    // MARK: - Environment

    /// Rebuilds the USPS client against the currently configured base URL.
    /// Called automatically when `settings.useTestEnvironment` changes.
    func environmentChanged() async {
        let api = apiFactory(BaseURL.resolve(useTestEnvironment: settings.useTestEnvironment))
        self.api = api
        await tokens.replaceAPI(api)
    }

    // MARK: - Private

    private func handleInvalidCredentials() {
        credentialsStatus = .invalid
        needsAttention = true
        flow = .needsCredentials
        if !didNotifyInvalidCredentials {
            didNotifyInvalidCredentials = true
            notifier.notifyCredentialsNeeded()
        }
    }
}
