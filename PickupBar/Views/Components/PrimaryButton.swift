import SwiftUI

/// Full-width prominent button. While `isBusy` the label is replaced by a small
/// spinner and the button stops accepting clicks, so callers only need to track
/// one piece of state.
struct PrimaryButton: View {
    let title: String
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    init(_ title: String,
         isBusy: Bool = false,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: { if !isBusy { action() } }) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!isEnabled || isBusy)
    }
}
