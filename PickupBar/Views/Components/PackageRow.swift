import SwiftUI

/// One package type with its count and a 0…50 stepper. Dimmed while the count
/// is zero so the rows the user actually filled in stand out.
struct PackageRow: View {
    let type: PackageType
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(type.displayName)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 18, alignment: .trailing)
            Stepper("", value: $count, in: 0...50)
                .labelsHidden()
        }
        .opacity(count == 0 ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(type.displayName)
        .accessibilityValue("\(count)")
    }
}
