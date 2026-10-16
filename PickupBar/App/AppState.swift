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
    /// Set when the USPS app behind the stored credentials has no Carrier
    /// Pickup product, so scheduling will fail before the user tries. Always
    /// `.insufficientScope`, or nil.
    @Published private(set) var scopeWarning: USPSError?
    /// Scopes the last token carried, for Settings › Account. Empty when no
    /// token has been fetched yet or USPS did not list any.
    @Published private(set) var grantedScopes: [String] = []
    /// Whether `.confirmed` is showing a new pickup or a changed one.
    @Published private(set) var confirmationMode: ConfirmationMode = .scheduled
    /// The pickup the form is modifying, with the ETag from its last GET.
    @Published private(set) var pendingEdit: PendingEdit?
    /// Where the error screen's button goes: the form for a failed schedule,
    /// the history for a failed load or cancel, the edit form for a failed
    /// save.
    @Published private(set) var retryFlow: FlowState = .form

    /// True when the error screen leads back to the history rather than to
    /// something that will try again, so its button should say "Back".
    var retryReturnsToHistory: Bool { retryFlow == .history }

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
            applyScopes(await tokens.currentScopes())
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
        let token = try await api.fetchToken(clientID: id, clientSecret: secret)
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
        applyScopes(token.scopes)
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
        } catch let error as USPSError {
            // A scope rejection is not a credential problem: leave the flow
            // alone so the address form can show it inline.
            throw await enriched(error)
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
        retryFlow = .form
        do {
            let request = draft.request(address: address, contact: contact)
            let confirmation = try await withFreshTokenRetry { token in
                try await self.api.schedulePickup(request, token: token)
            }
            settings.lastConfirmation = confirmation
            // USPS may move the pickup to another day, so the record keeps the
            // confirmed date rather than the requested one.
            settings.addToHistory(PickupRecord(confirmation: confirmation,
                                               request: request,
                                               createdAt: now()))
            confirmationMode = .scheduled
            flow = .confirmed(confirmation)
        } catch {
            await fail(error)
        }
    }

    // MARK: - Modify / cancel

    /// History → the form, filled in with the pickup as USPS has it.
    func beginModify(_ record: PickupRecord) async {
        guard flow == .history else { return }
        let number = record.confirmationNumber
        flow = .working("Loading pickup…")
        retryFlow = .history
        do {
            let fetched = try await withFreshTokenRetry { token in
                try await self.api.fetchPickup(confirmationNumber: number, token: token)
            }
            draft = PickupDraft.forModifying(record, fetched: fetched.request,
                                             settings: settings, now: now())
            pendingEdit = PendingEdit(confirmationNumber: number, etag: fetched.etag)
            flow = .modifying(confirmationNumber: number)
        } catch {
            await fail(error)
        }
    }

    /// "Save Changes": sends the draft as a PUT. The ETag is fetched again
    /// right before, since it lasts only an hour and the form may have been
    /// open longer than that.
    func saveModification() async {
        guard draft.canSubmit,
              let edit = pendingEdit,
              flow == .modifying(confirmationNumber: edit.confirmationNumber),
              let address = settings.address,
              let contact = settings.contact else { return }

        let number = edit.confirmationNumber
        flow = .working("Updating your pickup…")
        retryFlow = .modifying(confirmationNumber: number)
        do {
            let request = draft.request(address: address, contact: contact, nextAvailablePickup: false)
            let fresh = try await withFreshTokenRetry { token in
                try await self.api.fetchPickup(confirmationNumber: number, token: token)
            }
            pendingEdit = PendingEdit(confirmationNumber: number, etag: fresh.etag)
            let updated = try await withFreshTokenRetry { token in
                try await self.api.updatePickup(confirmationNumber: number, etag: fresh.etag,
                                                request: request, token: token)
            }
            // The number is the one that was edited, whatever USPS echoes.
            let confirmation = PickupConfirmation(confirmationNumber: number,
                                                  pickupDate: updated.confirmation.pickupDate)
            if let existing = settings.history.first(where: { $0.confirmationNumber == number }) {
                settings.updateHistory(existing.updated(confirmation: confirmation, request: request, at: now()))
            } else {
                var record = PickupRecord(confirmation: confirmation, request: request, createdAt: now())
                record.updatedAt = now()
                settings.addToHistory(record)
            }
            if settings.lastConfirmation?.confirmationNumber == number {
                settings.lastConfirmation = confirmation
            }
            pendingEdit = nil
            confirmationMode = .updated
            flow = .confirmed(confirmation)
        } catch {
            await fail(error)
        }
    }

    /// "Discard": drop the edit and go back to the history.
    func cancelModification() {
        guard case .modifying = flow else { return }
        pendingEdit = nil
        draft = PickupDraft.fromDefaults(settings, now: now())
        flow = .history
    }

    /// Cancels the pickup with USPS: a GET for a fresh ETag, then the DELETE.
    /// USPS saying it is already cancelled counts as success.
    func cancelPickup(_ record: PickupRecord) async {
        guard flow == .history else { return }
        let number = record.confirmationNumber
        flow = .working("Cancelling your pickup…")
        retryFlow = .history
        do {
            do {
                let fetched = try await withFreshTokenRetry { token in
                    try await self.api.fetchPickup(confirmationNumber: number, token: token)
                }
                try await withFreshTokenRetry { token in
                    try await self.api.cancelPickup(confirmationNumber: number, etag: fetched.etag,
                                                    token: token)
                }
            } catch let error as USPSError where error.isAlreadyCancelled {
                // Cancelled elsewhere (or by an earlier attempt): same outcome.
            }
            var cancelled = settings.history.first { $0.confirmationNumber == number } ?? record
            cancelled.status = .cancelled
            cancelled.updatedAt = now()
            settings.updateHistory(cancelled)
            flow = .history
        } catch {
            await fail(error)
        }
    }

    /// Shows `error`, or the credentials screen when it is a credential
    /// rejection. `retryFlow` must already say where "Try again" goes.
    private func fail(_ error: Error) async {
        guard let error = error as? USPSError else {
            flow = .failed(.unexpected(status: 0, body: "\(error)"), retryable: true)
            return
        }
        if error == .invalidCredentials {
            handleInvalidCredentials()
        } else {
            let error = await enriched(error)
            flow = .failed(error, retryable: error.isRetryable)
        }
    }

    /// Confirmation screen → a fresh form.
    func scheduleAnother() {
        draft = PickupDraft.fromDefaults(settings, now: now())
        flow = .form
    }

    // MARK: - History

    /// Form or confirmation screen → "Scheduled pickups". Anywhere else (say,
    /// mid-request) it does nothing.
    func showHistory() {
        switch flow {
        case .form:
            flow = .history
        case .confirmed:
            // That draft was submitted; coming back should start a new one.
            draft = PickupDraft.fromDefaults(settings, now: now())
            flow = .history
        default:
            break
        }
    }

    /// "Scheduled pickups" → the form (never back to a confirmation, which is
    /// done with).
    func closeHistory() {
        guard flow == .history else { return }
        flow = .form
    }

    /// Error screen → back to where the failed request started (the form,
    /// the edit form, or the history), keeping what the user entered.
    func retry() {
        flow = retryFlow
        retryFlow = .form
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

    /// Fills a scope rejection in with the scopes the current token *does*
    /// have — the client raising it only knows that the token was refused.
    /// Every other error passes through untouched.
    private func enriched(_ error: USPSError) async -> USPSError {
        guard case .insufficientScope(let granted) = error, granted.isEmpty else { return error }
        let scopes = await tokens.currentScopes()
        applyScopes(scopes)
        return .insufficientScope(granted: scopes)
    }

    /// Records the scopes a fresh token carried and raises or clears the
    /// standing warning. An empty list says nothing, so it clears neither.
    private func applyScopes(_ scopes: [String]) {
        grantedScopes = scopes
        guard !scopes.isEmpty else { return }
        scopeWarning = OAuthToken.scopesAllowPickup(scopes) ? nil : .insufficientScope(granted: scopes)
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
