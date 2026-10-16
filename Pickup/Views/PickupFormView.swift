import SwiftUI

/// The main screen: pick a day, say where the packages are, count them, submit.
///
/// Sizing matters here: a `MenuBarExtra` window takes its height from the
/// content's ideal size. A bare `ScrollView` has almost none (the popover
/// collapses to the footer), and a `.frame(maxHeight:)` is flexible (the popover
/// grows to that height, mostly empty). `FittingScrollView` shows the form at
/// its natural height and only scrolls, at a fixed height, when it cannot fit
/// (very large text sizes or a short screen).
struct PickupFormView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        FittingScrollView(maxHeight: PopoverMetrics.maxHeight) {
            content
        }
    }

    /// The pickup being modified, or nil for a new one.
    private var editingNumber: String? {
        if case .modifying(let number) = state.flow { return number }
        return nil
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = state.scopeWarning {
                ScopeWarningBanner(error: warning, compact: true)
            }
            header
            daySection
            locationSection
            packagesSection
            weightSection
            hazmatToggle
            if editingNumber != nil {
                PrimaryButton("Save Changes", isEnabled: state.draft.canSubmit) {
                    Task { await state.saveModification() }
                }
                .accessibilityIdentifier("form.save")
                Button("Discard") { state.cancelModification() }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .help("Leave the pickup as it is")
                    .accessibilityIdentifier("form.discard")
            } else {
                PrimaryButton("Schedule Pickup", isEnabled: state.draft.canSubmit) {
                    Task { await state.schedule() }
                }
                .accessibilityIdentifier("form.schedule")
            }
        }
        .padding(Style.outerPadding)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(editingNumber == nil ? "Schedule a pickup" : "Modify pickup")
                .font(.headline)
                .accessibilityIdentifier("form.title")
            if let number = editingNumber {
                Text(number)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("form.editingNumber")
            }
            if let address = settings.address {
                Text("\(address.streetAddress), \(address.city) \(address.state)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if editingNumber == nil, let last = settings.lastConfirmation {
                Button {
                    state.showHistory()
                } label: {
                    HStack(spacing: 3) {
                        Text(Self.lastPickupCaption(last))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Scheduled pickups")
                .accessibilityIdentifier("form.lastPickup")
            }
        }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Day")
            DayChips(selection: $state.draft.selectedDate)
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Location")
            Picker("", selection: $state.draft.location) {
                ForEach(PackageLocation.allCases, id: \.self) { location in
                    Text(location.displayName).tag(location)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(state.draft.location == .other
                      ? "Special instructions (required)"
                      : "Special instructions (optional)",
                      text: $state.draft.instructions)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("form.instructions")

            if state.draft.instructionsMissing {
                Text("Instructions are required when the location is Other")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("form.instructionsRequired")
            }

            Toggle("Dog on premises", isOn: $state.draft.dogPresent)
                .toggleStyle(.checkbox)
                .font(.callout)
        }
    }

    private var packagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Packages")
                Text(state.draft.totalPackages == 1
                     ? "1 total"
                     : "\(state.draft.totalPackages) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("form.total")
            }
            Card {
                VStack(spacing: 2) {
                    ForEach(PackageType.allCases, id: \.self) { type in
                        PackageRow(type: type,
                                   count: Binding(
                                    get: { state.draft.counts[type] ?? 0 },
                                    set: { state.draft.counts[type] = $0 }))
                    }
                }
            }
        }
    }

    private var weightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Weight")
            WeightField(weight: $state.draft.weight, identifier: "form.weight")
        }
    }

    /// e.g. "Last pickup: WTC123456 on Fri, Sep 19".
    static func lastPickupCaption(_ confirmation: PickupConfirmation) -> String {
        let parser = DateFormatter()
        parser.timeZone = PickupDateCalculator.timeZone
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        guard let date = parser.date(from: confirmation.pickupDate) else {
            return "Last pickup: \(confirmation.confirmationNumber)"
        }
        let display = DateFormatter()
        display.timeZone = PickupDateCalculator.timeZone
        display.locale = Locale(identifier: "en_US_POSIX")
        display.dateFormat = "EEE, MMM d"
        return "Last pickup: \(confirmation.confirmationNumber) on \(display.string(from: date))"
    }

    /// The USPS API has no hazmat field: the checkbox is a reminder, and the
    /// Publication 52 link says what it is a reminder of.
    private var hazmatToggle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $state.draft.hazmatConfirmed) {
                Text("These packages contain no hazardous materials")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("form.hazmat")
            LinkedCaption.publication52Note
                // Line up with the checkbox's label, not the box itself.
                .padding(.leading, 20)
                .accessibilityIdentifier("form.pub52")
        }
    }
}
