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
    /// First few characters of the stored Consumer Key, for Settings › Account.
    /// Kept even while the credentials are rejected, so the user can see *which*
    /// key USPS refused. Nil only when nothing is stored.
    @Published private(set) var credentialKeyPrefix: String?

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
        guard let stored else {
            credentialKeyPrefix = nil
            credentialsStatus = .missing
            flow = .needsCredentials
            return
        }
        credentialKeyPrefix = Self.keyPrefix(stored.id)

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
        do {
            try keychain.saveCredentials(id: id, secret: secret)
        } catch let error as KeychainError {
            // The credentials themselves are fine — say so, rather than leaving
            // onboarding showing a bare "Something unexpected happened".
            throw USPSError.unexpected(
                status: 0,
                body: "Couldn't save to Keychain (\(Self.describe(error))). "
                    + "Your credentials are valid, but macOS refused to store them.")
        }
        await tokens.invalidate()
        credentialKeyPrefix = Self.keyPrefix(id)
        credentialsStatus = .valid
        needsAttention = false
        didNotifyInvalidCredentials = false
        flow = settings.isAddressConfigured ? .form : .needsAddress
    }

    /// Forgets the stored credentials and returns to onboarding.
    func removeCredentials() {
        try? keychain.deleteCredentials()
        Task { await tokens.invalidate() }
        credentialKeyPrefix = nil
        credentialsStatus = .missing
        flow = .needsCredentials
    }

    // MARK: - Address

    /// Runs the eligibility check and stores the USPS-standardized address plus
    /// the contact. Returns the standardized address so the caller can show it.
    ///
    /// Deliberately leaves `flow` alone: during onboarding the address screen
    /// has to stay up long enough to show the "verified by USPS" banner. The
    /// user moves on with `finishAddressSetup()`.
    @discardableResult
    func validateAndSaveAddress(contact: PickupContact,
                                address: PostalAddress) async throws -> PostalAddress {
        do {
            let standardized = try await withFreshTokenRetry { token in
                try await self.api.checkEligibility(address, token: token)
            }
            settings.address = standardized
            settings.contact = contact
            return standardized
        } catch USPSError.invalidCredentials {
            handleInvalidCredentials()
            throw USPSError.invalidCredentials
        }
    }

    /// Onboarding's "Continue" after the address was verified.
    func finishAddressSetup() {
        if flow == .needsAddress { flow = .form }
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
            let request = draft.request(address: address, contact: contact)
            let confirmation = try await withFreshTokenRetry { token in
                try await self.api.schedulePickup(request, token: token)
            }
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

    /// Rebuilds the USPS client against the currently configured base URL and
    /// re-checks the stored credentials against it. Production and TEM issue
    /// different keys, so the status pill would otherwise keep claiming the old
    /// environment's verdict. Called automatically when
    /// `settings.useTestEnvironment` changes.
    func environmentChanged() async {
        let api = apiFactory(BaseURL.resolve(useTestEnvironment: settings.useTestEnvironment))
        self.api = api
        await tokens.replaceAPI(api)
        await tokens.invalidate()

        let stored: (id: String, secret: String)? = try? keychain.loadCredentials()
        guard stored != nil else {
            credentialsStatus = .missing
            return
        }
        credentialsStatus = .checking
        didNotifyInvalidCredentials = false
        await verifyStoredCredentials()
    }

    // MARK: - Private

    /// First four characters of a Consumer Key — enough to tell two keys apart
    /// without putting the whole value on screen. Nil for an empty key.
    private static func keyPrefix(_ id: String) -> String? {
        id.isEmpty ? nil : String(id.prefix(4))
    }

    private static func describe(_ error: KeychainError) -> String {
        switch error {
        case .osStatus(let status): return "OSStatus \(status)"
        case .badData: return "unreadable data"
        }
    }

    /// Runs `operation` with a valid token, and retries it once with a freshly
    /// fetched token when USPS rejects the one it was given. A token can be
    /// revoked or expire early mid-session, and that 401 comes from the API
    /// call rather than from the token fetch, so it is worth one clean retry
    /// before declaring the credentials bad.
    private func withFreshTokenRetry<T>(_ operation: (String) async throws -> T) async throws -> T {
        let token = try await tokens.validToken()
        do {
            return try await operation(token)
        } catch USPSError.invalidCredentials {
            await tokens.invalidate()
            let fresh = try await tokens.validToken()
            return try await operation(fresh)
        }
    }

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
