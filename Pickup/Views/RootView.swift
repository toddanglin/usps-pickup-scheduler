import SwiftUI

/// The popover's content: the screen for the current `FlowState`, plus the
/// shared footer.
struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            screen
                .transition(.opacity)
            FooterBar()
        }
        .animation(.easeInOut(duration: 0.18), value: state.flow)
        .onAppear { state.start() }
    }

    @ViewBuilder
    private var screen: some View {
        switch state.flow {
        case .needsCredentials:
            OnboardingView()
        case .needsAddress:
            AddressSetupView()
        case .form, .modifying:
            PickupFormView()
        case .scheduling:
            SchedulingView(title: "Scheduling your pickup…")
        case .working(let label):
            SchedulingView(title: label)
        case .confirmed(let confirmation):
            ConfirmationView(confirmation: confirmation, mode: state.confirmationMode)
        case .failed(let error, let retryable):
            ErrorView(error: error, retryable: retryable)
        case .history:
            PickupHistoryView()
        }
    }
}
