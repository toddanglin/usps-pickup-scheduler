import SwiftUI

/// One package type with an editable count and a 0…50 stepper. The name and
/// stepper are dimmed while the count is zero so the rows the user actually
/// filled in stand out; the count field never is, so it still reads as
/// something to type into.
///
/// The field and the stepper are separate accessibility elements
/// (`form.count.<RAW>` and `form.stepper.<RAW>`) so both can be driven.
struct PackageRow: View {
    let type: PackageType
    @Binding var count: Int

    static let range = 0...50

    @State private var text = ""
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(type.displayName)
                .font(.callout)
                .lineLimit(1)
                .opacity(dimmed)
            Spacer(minLength: 4)
            countField
            Stepper("", value: $count, in: Self.range)
                .labelsHidden()
                .opacity(dimmed)
                .accessibilityLabel(type.displayName)
                .accessibilityValue("\(count)")
                .accessibilityIdentifier("form.stepper.\(type.rawValue)")
        }
        .onAppear { text = Self.display(count) }
        .onChange(of: count) { _, newValue in
            // Leave the field alone while it already says this (e.g. empty
            // while the count is 0), so typing is never fought.
            if Self.parse(text) != newValue { text = Self.display(newValue) }
        }
    }

    private var dimmed: Double { count == 0 ? 0.55 : 1 }

    private var countField: some View {
        TextField("0", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .font(.callout.weight(.medium).monospacedDigit())
            .frame(width: 28)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isFocused
                          ? Color(nsColor: .textBackgroundColor)
                          : Color.primary.opacity(isHovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12),
                                  lineWidth: 1)
            )
            .focused($isFocused)
            .onHover { isHovering = $0 }
            .onChange(of: text) { _, newValue in typed(newValue) }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    // Typing should replace the count, not append to it. The
                    // field editor is only installed after focus lands.
                    DispatchQueue.main.async {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                } else {
                    commit()
                }
            }
            .onSubmit(commit)
            .help("Type a count from 0 to 50")
            .accessibilityLabel("\(type.displayName) count")
            .accessibilityIdentifier("form.count.\(type.rawValue)")
    }

    /// Keeps only digits, clamps to `range`, and pushes the value to `count`
    /// as the user types so the total updates live.
    private func typed(_ newValue: String) {
        var digits = String(newValue.filter(\.isASCIIDigit))
        if let value = Int(digits.prefix(4)), value > Self.range.upperBound {
            digits = "\(Self.range.upperBound)"
        }
        if digits != newValue {
            text = digits
            return  // Called again with the cleaned text.
        }
        let value = Self.parse(digits)
        if value != count { count = value }
    }

    /// Return, Tab or losing focus: show the canonical form ("007" → "7",
    /// "0" → empty with the "0" placeholder).
    private func commit() {
        let value = Self.parse(text)
        if value != count { count = value }
        text = Self.display(value)
    }

    /// Empty or unparseable means 0; always within `range`.
    static func parse(_ text: String) -> Int {
        let value = Int(text.filter(\.isASCIIDigit).prefix(4)) ?? 0
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// 0 shows as an empty field, so the "0" placeholder is what the user sees.
    static func display(_ count: Int) -> String {
        count == 0 ? "" : "\(count)"
    }
}
