import SwiftUI

/// Contact + pickup address entry, shared by the first-run address screen and
/// Settings › Address. Runs the USPS eligibility check on save and reports the
/// standardized address inline.
struct AddressFormView: View {
    /// When set, a "Continue" button appears under the verified-address banner.
    /// Onboarding uses it to leave the address step; Settings shows the banner
    /// alone, because there is nowhere to continue to.
    var continueAction: (() -> Void)?

    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: SettingsStore

    /// 72 pt / 52 pt at the default text size, grown with the user's.
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 72
    @ScaledMetric(relativeTo: .body) private var stateFieldWidth: CGFloat = 52

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var firm = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var street = ""
    @State private var secondary = ""
    @State private var city = ""
    @State private var stateCode = ""
    @State private var zip = ""

    @State private var isBusy = false
    @State private var problems: [String] = []
    @State private var error: USPSError?
    @State private var standardized: PostalAddress?
    @State private var didPrefill = false

    var body: some View {
        VStack(alignment: .leading, spacing: Style.sectionSpacing) {
            VStack(spacing: 6) {
                FieldRow(label: "First name", text: $firstName, identifier: "address.firstName", labelWidth: labelWidth)
                FieldRow(label: "Last name", text: $lastName, identifier: "address.lastName", labelWidth: labelWidth)
                FieldRow(label: "Company", text: $firm, placeholder: "Optional",
                         identifier: "address.firm", labelWidth: labelWidth)
                FieldRow(label: "Phone", text: $phone, placeholder: "10 digits",
                         identifier: "address.phone", labelWidth: labelWidth)
                    .onChange(of: phone) { _, newValue in
                        let cleaned = String(Self.digits(newValue).prefix(10))
                        if cleaned != newValue { phone = cleaned }
                    }
                FieldRow(label: "Email", text: $email, placeholder: "Optional",
                         identifier: "address.email", labelWidth: labelWidth)
            }

            VStack(spacing: 6) {
                FieldRow(label: "Street", text: $street, identifier: "address.street", labelWidth: labelWidth)
                FieldRow(label: "Apt/Suite", text: $secondary, placeholder: "Optional",
                         identifier: "address.secondary", labelWidth: labelWidth)
                FieldRow(label: "City", text: $city, identifier: "address.city", labelWidth: labelWidth)
                HStack(spacing: 6) {
                    Text("State")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("TX", text: $stateCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: stateFieldWidth)
                        .onChange(of: stateCode) { _, newValue in
                            let cleaned = String(newValue.filter(\.isLetter).uppercased().prefix(2))
                            if cleaned != newValue { stateCode = cleaned }
                        }
                        .accessibilityIdentifier("address.state")
                    Text("ZIP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("78701", text: $zip)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: zip) { _, newValue in
                            let cleaned = String(Self.digits(newValue).prefix(5))
                            if cleaned != newValue { zip = cleaned }
                        }
                        .accessibilityIdentifier("address.zip")
                }
            }

            if !problems.isEmpty {
                InlineError(title: "Check these fields",
                            message: problems.joined(separator: "\n"))
            }

            if let error {
                InlineError(title: error.title, message: error.message, hint: error.hint)
            }

            if let standardized, error == nil, problems.isEmpty {
                successBanner(standardized)
            }

            PrimaryButton("Validate & Save", isBusy: isBusy, action: save)
                .accessibilityIdentifier("address.validate")

            if let continueAction, standardized != nil, error == nil, problems.isEmpty {
                PrimaryButton("Continue", action: continueAction)
                    .accessibilityIdentifier("address.continue")
            }
        }
        .disabled(isBusy)
        .onAppear(perform: prefill)
    }

    private func successBanner(_ address: PostalAddress) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Address verified by USPS")
                    .font(.callout.weight(.medium))
                Text(Self.oneLine(address))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let contact = settings.contact {
            firstName = contact.firstName
            lastName = contact.lastName
            firm = contact.firm ?? ""
            phone = contact.phone
            email = contact.email ?? ""
        }
        if let address = settings.address {
            street = address.streetAddress
            secondary = address.secondaryAddress ?? ""
            city = address.city
            stateCode = address.state
            zip = address.ZIPCode
        }
    }

    private func save() {
        // Normalize the fields that have a canonical form before validating,
        // so the user never has to fix formatting by hand.
        phone = Self.digits(phone)
        stateCode = stateCode.uppercased().trimmingCharacters(in: .whitespaces)
        zip = String(Self.digits(zip).prefix(5))

        error = nil
        standardized = nil
        problems = validate()
        guard problems.isEmpty else { return }

        let contact = PickupContact(
            firstName: firstName.trimmed,
            lastName: lastName.trimmed,
            firm: firm.trimmed.nilIfEmpty,
            phone: phone,
            email: email.trimmed.nilIfEmpty)
        let address = PostalAddress(
            streetAddress: street.trimmed,
            secondaryAddress: secondary.trimmed.nilIfEmpty,
            city: city.trimmed,
            state: stateCode,
            ZIPCode: zip,
            ZIPPlus4: nil)

        isBusy = true
        Task {
            do {
                standardized = try await state.validateAndSaveAddress(contact: contact,
                                                                      address: address)
            } catch let uspsError as USPSError {
                error = uspsError
            } catch {
                self.error = .unexpected(status: 0, body: "\(error)")
            }
            isBusy = false
        }
    }

    /// Human-readable list of everything still wrong with the form.
    private func validate() -> [String] {
        var problems: [String] = []
        if firstName.trimmed.isEmpty { problems.append("First name is required.") }
        if lastName.trimmed.isEmpty { problems.append("Last name is required.") }
        if Self.digits(phone).count != 10 { problems.append("Phone must be 10 digits.") }
        if street.trimmed.isEmpty { problems.append("Street is required.") }
        if city.trimmed.isEmpty { problems.append("City is required.") }
        if stateCode.count != 2 || !stateCode.allSatisfy(\.isLetter) {
            problems.append("State must be 2 letters.")
        }
        if Self.digits(zip).count != 5 { problems.append("ZIP must be 5 digits.") }
        return problems
    }

    // MARK: - Helpers

    private static func digits(_ value: String) -> String {
        value.filter(\.isNumber)
    }

    static func oneLine(_ address: PostalAddress) -> String {
        var line = address.streetAddress
        if let secondary = address.secondaryAddress, !secondary.isEmpty {
            line += " \(secondary)"
        }
        return "\(line), \(address.city) \(address.state) \(address.ZIPCode)"
    }
}

/// Label on the left, field on the right — compact enough for a 340 pt popover.
private struct FieldRow: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    /// Goes on the text field itself: an identifier set on the row would land
    /// on the enclosing group instead, where UI tests cannot use it.
    var identifier: String = ""
    var labelWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
