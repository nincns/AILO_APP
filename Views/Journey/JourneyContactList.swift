// Views/Journey/JourneyContactList.swift
import SwiftUI

struct JourneyContactList: View {
    let contacts: [JourneyContactRef]
    let onDelete: ((JourneyContactRef) -> Void)?
    let onTap: ((JourneyContactRef) -> Void)?

    init(
        contacts: [JourneyContactRef],
        onDelete: ((JourneyContactRef) -> Void)? = nil,
        onTap: ((JourneyContactRef) -> Void)? = nil
    ) {
        self.contacts = contacts
        self.onDelete = onDelete
        self.onTap = onTap
    }

    var body: some View {
        if contacts.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "journey.contacts.empty"), systemImage: "person.crop.circle")
            } description: {
                Text(String(localized: "journey.contacts.add"))
            }
            .frame(height: 120)
        } else {
            ForEach(contacts) { contact in
                JourneyContactRow(
                    contact: contact,
                    onDelete: onDelete != nil ? { onDelete?(contact) } : nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onTap?(contact)
                }
            }
        }
    }
}

// MARK: - Grouped by Role

struct JourneyContactListGrouped: View {
    let contacts: [JourneyContactRef]
    let onDelete: ((JourneyContactRef) -> Void)?

    private var groupedContacts: [(role: ContactRole?, contacts: [JourneyContactRef])] {
        let grouped = Dictionary(grouping: contacts) { $0.role }
        return ContactRole.allCases.compactMap { role in
            guard let roleContacts = grouped[role], !roleContacts.isEmpty else { return nil }
            return (role: role, contacts: roleContacts)
        } + (grouped[nil].map { [(role: nil, contacts: $0)] } ?? [])
    }

    var body: some View {
        ForEach(groupedContacts, id: \.role) { group in
            Section(group.role?.title ?? String(localized: "journey.contacts.other")) {
                ForEach(group.contacts) { contact in
                    JourneyContactRow(
                        contact: contact,
                        showRole: false,
                        onDelete: onDelete != nil ? { onDelete?(contact) } : nil
                    )
                }
            }
        }
    }
}

#Preview {
    List {
        JourneyContactList(
            contacts: [
                JourneyContactRef(
                    nodeId: UUID(),
                    contactId: nil,
                    displayName: "Max Mustermann",
                    email: "max@example.com",
                    role: .assignee
                ),
                JourneyContactRef(
                    nodeId: UUID(),
                    contactId: nil,
                    displayName: "Anna Schmidt",
                    phone: "+49 123 456789",
                    role: .reviewer
                )
            ],
            onDelete: { _ in },
            onTap: nil
        )
    }
}
