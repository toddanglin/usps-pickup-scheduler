import SwiftUI

/// Failure screen: what went wrong, what to do about it, and a way out.
struct ErrorView: View {
    let error: USPSError
    let retryable: Bool

    @EnvironmentObject private var state: AppState
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    private var suggestsSettings: Bool {
        switch error {
        case .forbidden, .addressNotEligible: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: Style.sectionSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.orange)

            VStack(spacing: 4) {
                Text(error.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(error.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                if let hint = error.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Button(didCopy ? "Copied" : "Copy details", action: copyDetails)
                .buttonStyle(.borderless)
                .font(.caption)

            VStack(spacing: 6) {
                PrimaryButton(retryable ? "Try again" : "Back") { state.retry() }
                if suggestsSettings {
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(Style.outerPadding)
        .frame(maxWidth: .infinity)
        .onDisappear { copyResetTask?.cancel() }
    }

    private func copyDetails() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(error.technicalDetails, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
