import SwiftUI

/// Settings › Account: credential status, replace/remove, environment toggle.
struct AccountSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    @State private var isReplacing = false
    @State private var consumerKey = ""
    @State private var consumerSecret = ""
    @State private var isBusy = false
    @State private var error: USPSError?
    @State private var confirmRemove = false

    private var canSubmit: Bool {
        !consumerKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !consumerSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { StatusPill(status: state.credentialsStatus) }
                LabeledContent("Consumer Key") {
                    Text(maskedKey)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("API access") { PickupAccessPill(scopes: state.grantedScopes) }
                if !state.grantedScopes.isEmpty {
                    Text("Granted scopes: " + state.grantedScopes.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(isReplacing ? "Cancel" : "Replace…") {
                        isReplacing.toggle()
                        error = nil
                        consumerKey = ""
                        consumerSecret = ""
                    }
                    Button("Remove") { confirmRemove = true }
                        .disabled(state.credentialsStatus == .missing)
                }
            }

            if isReplacing {
                Section("New credentials") {
                    TextField("Consumer Key", text: $consumerKey)
                    SecureField("Consumer Secret", text: $consumerSecret)
                    if let error {
                        InlineError(title: error.title, message: error.message)
                    }
                    Button("Verify & Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmit || isBusy)
                        .overlay(alignment: .trailing) {
                            if isBusy {
                                ProgressView().controlSize(.small).offset(x: 24)
                            }
                        }
                }
            }

            Section {
                Toggle("Use USPS test environment (TEM)", isOn: $settings.useTestEnvironment)
                Text("Sends requests to apis-tem.usps.com instead of production. Your TEM credentials are different from production ones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove the saved USPS credentials?",
                            isPresented: $confirmRemove) {
            Button("Remove Credentials", role: .destructive) {
                state.removeCredentials()
                isReplacing = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("PickupBar will ask for a Consumer Key and Secret the next time you open it.")
        }
    }

    /// First four characters, then dots — enough to tell two keys apart without
    /// putting the whole secret-ish value on screen. Read from `AppState`
    /// rather than the Keychain: `body` runs on every redraw, and a rejected
    /// key should still be shown so the user knows which one USPS refused.
    private var maskedKey: String {
        guard let prefix = state.credentialKeyPrefix else { return "Not set" }
        return prefix + "••••••••"
    }

    private func save() {
        error = nil
        isBusy = true
        Task {
            do {
                try await state.saveCredentials(
                    id: consumerKey.trimmingCharacters(in: .whitespaces),
                    secret: consumerSecret.trimmingCharacters(in: .whitespaces))
                isReplacing = false
                consumerKey = ""
                consumerSecret = ""
            } catch let uspsError as USPSError {
                error = uspsError
            } catch {
                self.error = .unexpected(status: 0, body: "\(error)")
            }
            isBusy = false
        }
    }
}

/// Whether the token's scopes cover Carrier Pickup. An empty scope list means
/// no token has come back yet, which says nothing either way.
private struct PickupAccessPill: View {
    let scopes: [String]

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }

    private var text: String {
        if scopes.isEmpty { return "Carrier Pickup: Unknown" }
        return scopes.contains("pickup") ? "Carrier Pickup: Enabled" : "Carrier Pickup: Not enabled"
    }

    private var color: Color {
        if scopes.isEmpty { return .secondary }
        return scopes.contains("pickup") ? .green : .orange
    }
}

private struct StatusPill: View {
    let status: CredentialsStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }

    private var text: String {
        switch status {
        case .valid: return "Valid"
        case .checking: return "Checking…"
        case .invalid: return "Invalid"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .valid: return .green
        case .checking: return .blue
        case .invalid: return .red
        case .missing: return .orange
        case .unknown: return .secondary
        }
    }
}
