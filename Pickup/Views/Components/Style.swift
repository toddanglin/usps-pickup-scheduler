import SwiftUI

/// Shared spacing/shape constants so every screen lines up.
enum Style {
    static let outerPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 10
}

/// A small uppercase section heading, e.g. "DAY".
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Rounded, faintly filled grouping used around form clusters.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
    }
}

/// Red, icon-led inline error text used by the onboarding and address forms.
struct InlineError: View {
    let title: String
    var message: String?
    var hint: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                if let message, !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let hint, !hint.isEmpty {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
