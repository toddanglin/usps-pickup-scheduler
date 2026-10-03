import SwiftUI

/// "Scheduled pickups": the pickups this app has scheduled, upcoming first.
///
/// The list is PickupBar's own local history (`SettingsStore.history`). The
/// USPS Carrier Pickup API cannot list pickups — it only reads, changes or
/// cancels one by confirmation number — so pickups made on usps.com or
/// anywhere else never appear here.
struct PickupHistoryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    /// About eight rows; beyond that the list scrolls at this fixed height.
    private static let listMaxHeight: CGFloat = 8 * 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Style.outerPadding)
                .padding(.top, Style.outerPadding)
                .padding(.bottom, 8)

            if settings.history.isEmpty {
                emptyState
            } else {
                FittingScrollView(maxHeight: min(Self.listMaxHeight, PopoverMetrics.maxHeight - 120)) {
                    list
                }
            }

            Text("Only pickups scheduled with PickupBar are listed. "
                 + "USPS doesn't provide a way to list pickups made elsewhere.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Style.outerPadding)
                .padding(.top, 8)
                .padding(.bottom, Style.outerPadding)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                state.closeHistory()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("history.back")

            Text("Scheduled pickups")
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No pickups yet")
                .font(.callout.weight(.medium))
            Text("Pickups you schedule with PickupBar appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, Style.outerPadding)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.empty")
    }

    private var list: some View {
        let now = Date()
        let upcoming = settings.history.filter { $0.isUpcoming(asOf: now) }
            // Soonest first.
            .sorted { $0.pickupDate < $1.pickupDate }
        let past = settings.history.filter { !$0.isUpcoming(asOf: now) }
        return VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            if !upcoming.isEmpty { section("Upcoming", upcoming) }
            if !past.isEmpty { section("Past", past) }
        }
        .padding(.horizontal, Style.outerPadding)
    }

    private func section(_ title: String, _ records: [PickupRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider().padding(.vertical, 4) }
                        HistoryRow(record: record) {
                            settings.removeFromHistory(confirmationNumber: record.confirmationNumber)
                        }
                    }
                }
            }
        }
    }
}

/// One pickup: day, packages, confirmation number, and copy/remove actions.
private struct HistoryRow: View {
    let record: PickupRecord
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.shortDisplayDate)
                    .font(.callout.weight(.medium))
                Text(record.packageSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(record.confirmationNumber)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .accessibilityIdentifier("history.number.\(record.confirmationNumber)")
            }
            Spacer(minLength: 4)
            CopyButton(text: record.confirmationNumber, style: .borderless)
                .accessibilityIdentifier("history.copy.\(record.confirmationNumber)")
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("history.more.\(record.confirmationNumber)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy confirmation number") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(record.confirmationNumber, forType: .string)
        }
        Button("Remove from list", role: .destructive, action: remove)
            .help("Removes it from this list only. The pickup stays scheduled with USPS.")
    }
}
