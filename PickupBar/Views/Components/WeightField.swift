import SwiftUI

/// A pounds field backed by its own `String`.
///
/// `TextField(value:format:)` keeps the last value it managed to parse, so
/// clearing the field leaves the bound `Double` at the old number while the
/// field looks empty — the form would then submit a weight the user cannot
/// see. Parsing the text ourselves keeps the two in step and lets an
/// in-progress "" or "0" say so out loud.
struct WeightField: View {
    @Binding var weight: Double
    /// Written to `weight` in place of anything at or below it. The pickup form
    /// allows 0 (which simply disables submitting); a default must be usable.
    var minimum: Double = 0
    var identifier: String?

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                TextField("Weight", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier(identifier ?? "")
                    .onChange(of: text) { _, newValue in
                        weight = max(Self.parse(newValue), minimum)
                    }
                Text("lb")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if showsWarning {
                Text("Enter a weight greater than 0")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { text = Self.format(weight) }
    }

    private var showsWarning: Bool {
        !text.isEmpty && Self.parse(text) <= 0
    }

    /// Accepts a comma as the decimal separator; anything unparseable is 0.
    static func parse(_ text: String) -> Double {
        max(Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0, 0)
    }

    /// Whole pounds lose the ".0" so the field reads like the user typed it.
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int(value))
            : String(value)
    }
}
