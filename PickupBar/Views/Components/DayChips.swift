import SwiftUI

/// The next six valid pickup days as a row of tappable chips.
struct DayChips: View {
    @Binding var selection: Date
    /// Injected so the chips can be driven from a fixed date in previews.
    var now: Date = Date()

    private var dates: [Date] { PickupDateCalculator.availableDates(from: now, count: 6) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(dates, id: \.self) { date in
                DayChip(date: date,
                        isSelected: isSelected(date),
                        isNext: date == dates.first) {
                    selection = date
                }
            }
        }
        .onAppear(perform: snapSelectionIfNeeded)
    }

    private func isSelected(_ date: Date) -> Bool {
        PickupDateCalculator.apiDateString(date) == PickupDateCalculator.apiDateString(selection)
    }

    /// The app can stay open past midnight, leaving the draft pointing at a day
    /// that is no longer offered. Snap back to the first available day.
    private func snapSelectionIfNeeded() {
        let dates = dates
        guard let first = dates.first else { return }
        if !dates.contains(where: isSelected) {
            selection = first
        }
    }
}

private struct DayChip: View {
    let date: Date
    let isSelected: Bool
    let isNext: Bool
    let action: () -> Void

    var body: some View {
        let label = PickupDateCalculator.displayLabel(date)
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label.weekday)
                    .font(.caption2.weight(.semibold))
                Text(label.day)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(isNext ? "Next" : " ")
                    .font(.system(size: 8))
                    .opacity(isNext ? 0.8 : 0)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PickupDateCalculator.longDisplay(date))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
