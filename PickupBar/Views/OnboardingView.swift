import SwiftUI

/// First run (and re-auth): collect the USPS Consumer Key and Secret.
struct OnboardingView: View {
    @EnvironmentObject private var state: AppState

    @State private var consumerKey = ""
    @State private var consumerSecret = ""
    @State private var isBusy = false
    @State private var error: USPSError?

    private var canSubmit: Bool {
        !consumerKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !consumerSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            if state.credentialsStatus == .invalid {
                rejectedBanner
            }

            hero

            VStack(alignment: .leading, spacing: 6) {
                OnboardingStep(number: 1, text: "Create a free account at the USPS Developer Portal")
                OnboardingStep(number: 2, text: "Add an app and copy its Consumer Key and Secret")
                OnboardingStep(number: 3, text: "Paste them below — they're stored in your Keychain")
            }

            Link(destination: URL(string: "https://developers.usps.com")!) {
                Label("Open USPS Developer Portal", systemImage: "arrow.up.right.square")
                    .font(.callout)
            }

            VStack(spacing: 8) {
                TextField("Consumer Key", text: $consumerKey)
                    .accessibilityIdentifier("onboarding.key")
                SecureField("Consumer Secret", text: $consumerSecret)
                    .accessibilityIdentifier("onboarding.secret")
            }
            .textFieldStyle(.roundedBorder)
            .disabled(isBusy)

            if let error {
                InlineError(title: error.title, message: error.message, hint: error.hint)
            }

            PrimaryButton("Verify & Save", isBusy: isBusy, isEnabled: canSubmit, action: save)
                .accessibilityIdentifier("onboarding.verify")
        }
        .padding(Style.outerPadding)
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.accentColor))
            Text("Connect your USPS account")
                .font(.headline)
            Text("PickupBar schedules carrier pickups through the USPS API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var rejectedBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("USPS rejected the saved credentials — please re-enter them.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                .fill(Color.yellow.opacity(0.15))
        )
    }

    private func save() {
        error = nil
        isBusy = true
        Task {
            do {
                try await state.saveCredentials(
                    id: consumerKey.trimmingCharacters(in: .whitespaces),
                    secret: consumerSecret.trimmingCharacters(in: .whitespaces))
            } catch let uspsError as USPSError {
                error = uspsError
            } catch {
                self.error = .unexpected(status: 0, body: "\(error)")
            }
            isBusy = false
        }
    }
}

private struct OnboardingStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.secondary))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
