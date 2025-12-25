// Views/Journey/JourneyContactPicker.swift
import SwiftUI
import ContactsUI

struct JourneyContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let defaultRole: ContactRole?
    let onSelect: (JourneyContactRef) -> Void

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
            let contactRef = JourneyContactService.shared.createContactRef(
                from: contact,
                nodeId: parent.nodeId,
                role: parent.defaultRole
            )

            parent.onSelect(contactRef)
            parent.isPresented = false
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}

// MARK: - Sheet Wrapper

struct JourneyContactPickerSheet: View {
    @Binding var isPresented: Bool
    let nodeId: UUID
    let onSelect: (JourneyContactRef) -> Void

    @State private var selectedRole: ContactRole = .contact
    @State private var showPicker: Bool = false
    @State private var permissionDenied: Bool = false

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
                    nodeId: nodeId,
                    defaultRole: selectedRole,
                    onSelect: { contactRef in
                        var ref = contactRef
                        ref.role = selectedRole
                        onSelect(ref)
                        isPresented = false
                    }
                )
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
}

#Preview {
    JourneyContactPickerSheet(
        isPresented: .constant(true),
        nodeId: UUID(),
        onSelect: { _ in }
    )
}
