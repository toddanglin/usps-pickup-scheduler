import SwiftUI

/// Copies `text` to the pasteboard and says "Copied" for a moment.
struct CopyButton: View {
    let text: String
    var title: String = "Copy"
    var style: Style = .bordered

    enum Style {
        case bordered
        case borderless
    }

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch style {
            case .bordered:
                button.buttonStyle(.bordered).controlSize(.small)
            case .borderless:
                button.buttonStyle(.borderless).font(.caption)
            }
        }
        .onDisappear { resetTask?.cancel() }
    }

    private var button: some View {
        Button(didCopy ? "Copied" : title, action: copy)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

/// `SettingsLink`, plus the app activation it is missing.
///
/// PickupBar is an `LSUIElement`, so on macOS 14 a `SettingsLink` tapped from
/// the menu bar popover opens the Settings window without bringing the app
/// forward: the window can appear behind whatever the user was working in.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: Label

    var body: some View {
        SettingsLink { label }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
    }
}
