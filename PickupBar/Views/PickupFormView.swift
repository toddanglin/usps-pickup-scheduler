import SwiftUI

/// The main screen: pick a day, say where the packages are, count them, submit.
///
/// Sizing matters here: a `MenuBarExtra` window takes its height from the
/// content's ideal size, and a bare `ScrollView` has almost none, so a form
/// wrapped only in a `ScrollView` collapses the popover to just the footer.
/// The form is therefore shown at its natural height, and only falls back to a
/// fixed-height scrolling version when it cannot fit (very large text sizes or
/// a short screen).
struct PickupFormView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    /// Tallest the form may be before it scrolls: most of the visible screen.
    private var maxHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(360, screen - 120)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView {
                content
            }
            .frame(height: maxHeight)
        }
        .frame(maxHeight: maxHeight)
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
            PrimaryButton("Schedule Pickup", isEnabled: state.draft.canSubmit) {
                Task { await state.schedule() }
            }
            .accessibilityIdentifier("form.schedule")
        }
        .padding(Style.outerPadding)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Schedule a pickup")
                .font(.headline)
            if let address = settings.address {
                Text("\(address.streetAddress), \(address.city) \(address.state)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let last = settings.lastConfirmation {
                Text(Self.lastPickupCaption(last))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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

    private var hazmatToggle: some View {
        Toggle(isOn: $state.draft.hazmatConfirmed) {
            Text("These packages contain no hazardous materials")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("form.hazmat")
    }
}
