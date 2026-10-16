import SwiftUI

/// "Scheduled pickups": the pickups this app has scheduled, upcoming first.
///
/// The list is the app's own local history (`SettingsStore.history`). The
/// USPS Carrier Pickup API cannot list pickups — it only reads, changes or
/// cancels one by confirmation number — so pickups made on usps.com or
/// anywhere else never appear here.
struct PickupHistoryView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    /// The pickup whose "Cancel pickup…" is waiting for a yes or no. The
    /// question is asked inline: a sheet or alert on the `MenuBarExtra` window
    /// closes the popover when clicked, and the click is lost.
    @State private var pendingCancel: PickupRecord?

    /// About eight rows; beyond that the list scrolls at this fixed height.
    private static let listMaxHeight: CGFloat = 8 * 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Style.outerPadding)
                .padding(.top, Style.outerPadding)
                .padding(.bottom, 8)

            if let record = pendingCancel {
                cancelConfirmation(record)
            } else if settings.history.isEmpty {
                emptyState
            } else {
                FittingScrollView(maxHeight: min(Self.listMaxHeight, PopoverMetrics.maxHeight - 120)) {
                    list
                }
            }

            Text("Only pickups scheduled with Pickup are listed. "
                 + "USPS doesn't provide a way to list pickups made elsewhere.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Style.outerPadding)
                .padding(.top, 8)
                .padding(.bottom, Style.outerPadding)
        }
    }

    private func cancelConfirmation(_ record: PickupRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cancel the pickup on \(record.longDisplayDate)?")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("history.cancelTitle")
                Text("USPS will no longer come for these packages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.packageSummary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(record.confirmationNumber)
                        .font(.caption.monospaced())
                }
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Keep pickup") { pendingCancel = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("history.cancelKeep")
                    Spacer(minLength: 0)
                    Button("Cancel pickup", role: .destructive) {
                        pendingCancel = nil
                        Task { await state.cancelPickup(record) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("history.cancelConfirm")
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Style.outerPadding)
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
            Text("Pickups you schedule with Pickup appear here.")
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
                        HistoryRow(record: record,
                                   isActionable: record.isUpcoming(asOf: Date()),
                                   modify: { Task { await state.beginModify(record) } },
                                   cancel: { pendingCancel = record },
                                   remove: {
                                       settings.removeFromHistory(confirmationNumber: record.confirmationNumber)
                                   })
                    }
                }
            }
        }
    }
}

/// One pickup: day, packages, confirmation number, and its actions. Upcoming
/// scheduled pickups can be modified or cancelled with USPS; past and
/// cancelled ones can only be copied or removed from the list.
private struct HistoryRow: View {
    let record: PickupRecord
    let isActionable: Bool
    let modify: () -> Void
    /// Asks before cancelling; see `PickupHistoryView.pendingCancel`.
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(record.shortDisplayDate)
                        .font(.callout.weight(.medium))
                        .strikethrough(record.status == .cancelled, color: .secondary)
                    if record.status == .cancelled {
                        Text("Cancelled")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Cancelled")
                            .accessibilityIdentifier("history.status.\(record.confirmationNumber)")
                    } else if record.updatedAt != nil {
                        Text("Updated")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Updated")
                            .accessibilityIdentifier("history.updated.\(record.confirmationNumber)")
                    }
                }
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
        if isActionable {
            Button("Modify…", action: modify)
                .accessibilityIdentifier("history.modify.\(record.confirmationNumber)")
            Button("Cancel pickup…", role: .destructive) { cancel() }
                .accessibilityIdentifier("history.cancel.\(record.confirmationNumber)")
            Divider()
        }
        Button("Copy confirmation number") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(record.confirmationNumber, forType: .string)
        }
        Button("Remove from list", role: .destructive, action: remove)
            .help(record.status == .cancelled
                  ? "Removes it from this list."
                  : "Removes it from this list only. The pickup stays scheduled with USPS.")
    }
}
