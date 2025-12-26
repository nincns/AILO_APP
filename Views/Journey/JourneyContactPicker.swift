// Views/Journey/JourneyContactPicker.swift
import SwiftUI
import ContactsUI
import Contacts

// MARK: - Raw Contact Picker (returns CNContact)

struct JourneyContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onSelect: (CNContact) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.predicateForEnablingContact = NSPredicate(value: true)

        // Zeige alle Kontakte mit mindestens Name
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactEmailAddressesKey,
            CNContactPhoneNumbersKey,
            CNContactThumbnailImageDataKey
        ]

        let nav = UINavigationController(rootViewController: picker)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: JourneyContactPicker

        init(_ parent: JourneyContactPicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            // Übergebe den partiellen Kontakt direkt - der vollständige wird später async geladen
            parent.onSelect(contact)
            parent.isPresented = false
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Sheet Wrapper with Email/Phone Selection

struct JourneyContactPickerSheet: View {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let onSelect: (JourneyContactRef) -> Void

    @State private var selectedRole: ContactRole = .contact
    @State private var showPicker: Bool = false
    @State private var permissionDenied: Bool = false

    // Ausgewählter Kontakt für E-Mail/Telefon-Auswahl
    @State private var selectedContact: CNContact?
    @State private var showContactDetails: Bool = false
    @State private var isLoadingContact: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // Permission Check
                if permissionDenied {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                                .font(.system(size: 50))
                                .foregroundStyle(.red)

                            Text(String(localized: "journey.contacts.noAccess"))
                                .font(.headline)

                            Text(String(localized: "journey.contacts.noAccess.message"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button(String(localized: "common.openSettings")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                    }
                } else {
                    // Role Picker
                    Section(String(localized: "journey.role")) {
                        Picker(String(localized: "journey.role"), selection: $selectedRole) {
                            ForEach(ContactRole.allCases, id: \.self) { role in
                                Text(role.title).tag(role)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Select Button
                    Section {
                        Button {
                            showPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.badge.plus")
                                Text(String(localized: "journey.contacts.select"))
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "journey.contacts.add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        isPresented = false
                    }
                }
            }
            .task {
                await checkPermission()
            }
            .sheet(isPresented: $showPicker) {
                JourneyContactPicker(
                    isPresented: $showPicker,
                    onSelect: { partialContact in
                        // Lade vollständigen Kontakt asynchron
                        loadFullContact(partialContact)
                    }
                )
            }
            .overlay {
                if isLoadingContact {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView(String(localized: "common.loading"))
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $showContactDetails) {
                if let contact = selectedContact {
                    ContactDetailsSelectionSheet(
                        contact: contact,
                        role: selectedRole,
                        onConfirm: { email, phone in
                            finalizeContact(contact: contact, selectedEmail: email, selectedPhone: phone)
                        },
                        onCancel: {
                            showContactDetails = false
                            selectedContact = nil
                        }
                    )
                }
            }
        }
    }

    private func checkPermission() async {
        let service = JourneyContactService.shared

        switch service.permissionStatus {
        case .authorized:
            permissionDenied = false
        case .notDetermined:
            let granted = await service.requestAccess()
            permissionDenied = !granted
        default:
            permissionDenied = true
        }
    }

    private func loadFullContact(_ partialContact: CNContact) {
        isLoadingContact = true

        Task {
            // Lade vollständigen Kontakt im Hintergrund
            let fullContact = await Task.detached {
                JourneyContactService.shared.fetchContact(identifier: partialContact.identifier) ?? partialContact
            }.value

            await MainActor.run {
                isLoadingContact = false
                selectedContact = fullContact

                // Zeige immer die Auswahl wenn E-Mails oder Telefonnummern vorhanden sind
                if !fullContact.emailAddresses.isEmpty || !fullContact.phoneNumbers.isEmpty {
                    showContactDetails = true
                } else {
                    // Keine E-Mails oder Telefonnummern - direkt übernehmen
                    finalizeContact(
                        contact: fullContact,
                        selectedEmail: nil,
                        selectedPhone: nil
                    )
                }
            }
        }
    }

    private func finalizeContact(contact: CNContact, selectedEmail: String?, selectedPhone: String?) {
        let displayName = [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .ifEmpty(contact.organizationName)

        let contactRef = JourneyContactRef(
            nodeId: nodeId,
            contactId: contact.identifier,
            displayName: displayName,
            email: selectedEmail,
            phone: selectedPhone,
            role: selectedRole,
            note: nil
        )

        onSelect(contactRef)
        isPresented = false
    }
}

// MARK: - Contact Details Selection Sheet

struct ContactDetailsSelectionSheet: View {
    let contact: CNContact
    let role: ContactRole
    let onConfirm: (String?, String?) -> Void
    let onCancel: () -> Void

    @State private var selectedEmailIndex: Int = 0
    @State private var selectedPhoneIndex: Int = 0

    private var emails: [String] {
        contact.emailAddresses.map { $0.value as String }
    }

    private var phones: [String] {
        contact.phoneNumbers.map { $0.value.stringValue }
    }

    private var displayName: String {
        [contact.givenName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Kontakt-Info
                Section {
                    HStack(spacing: 12) {
                        contactAvatar
                        VStack(alignment: .leading) {
                            Text(displayName)
                                .font(.headline)
                            Text(role.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // E-Mail Auswahl
                if !emails.isEmpty {
                    Section(header: Text(String(localized: "journey.contact.selectEmail"))) {
                        ForEach(emails.indices, id: \.self) { index in
                            Button {
                                selectedEmailIndex = index
                            } label: {
                                HStack {
                                    Image(systemName: "envelope")
                                        .foregroundStyle(.blue)
                                    Text(emails[index])
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedEmailIndex == index {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }

                // Telefon Auswahl
                if !phones.isEmpty {
                    Section(header: Text(String(localized: "journey.contact.selectPhone"))) {
                        ForEach(phones.indices, id: \.self) { index in
                            Button {
                                selectedPhoneIndex = index
                            } label: {
                                HStack {
                                    Image(systemName: "phone")
                                        .foregroundStyle(.green)
                                    Text(phones[index])
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedPhoneIndex == index {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "journey.contact.details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done")) {
                        let email = emails.isEmpty ? nil : emails[selectedEmailIndex]
                        let phone = phones.isEmpty ? nil : phones[selectedPhoneIndex]
                        onConfirm(email, phone)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contactAvatar: some View {
        if let imageData = contact.thumbnailImageData,
           let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
        } else {
            // Initialen
            let initials = String(contact.givenName.prefix(1)) + String(contact.familyName.prefix(1))
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 50, height: 50)
                .overlay(
                    Text(initials.uppercased())
                        .font(.headline)
                        .foregroundStyle(.blue)
                )
        }
    }
}

// MARK: - String Extension

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

#Preview {
    JourneyContactPickerSheet(
        isPresented: .constant(true),
        nodeId: UUID(),
        onSelect: { _ in }
    )
}
