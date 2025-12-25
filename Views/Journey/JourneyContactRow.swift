// Views/Journey/JourneyContactRow.swift
import SwiftUI

struct JourneyContactRow: View {
    let contact: JourneyContactRef
    var showRole: Bool = true
    let onDelete: (() -> Void)?

    @State private var avatarImage: UIImage?

    init(
        contact: JourneyContactRef,
        showRole: Bool = true,
        onDelete: (() -> Void)? = nil
    ) {
        self.contact = contact
        self.showRole = showRole
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            avatarView
                .frame(width: 44, height: 44)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if showRole, let role = contact.role {
                        Text(role.title)
                            .font(.caption)
                            .foregroundStyle(roleColor(role))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(roleColor(role).opacity(0.15))
                            .clipShape(Capsule())
                    }

                    if let email = contact.email {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let phone = contact.phone {
                        Text(phone)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            if let onDelete = onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .task {
            loadAvatar()
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let image = avatarImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else {
            ZStack {
                Circle()
                    .fill(Color(.systemGray5))

                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var initials: String {
        let parts = contact.displayName.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last?.prefix(1) ?? "" : ""
        return "\(first)\(last)".uppercased()
    }

    private func roleColor(_ role: ContactRole) -> Color {
        switch role {
        case .assignee: return .blue
        case .owner: return .purple
        case .stakeholder: return .orange
        case .reviewer: return .green
        case .contact: return .gray
        }
    }

    private func loadAvatar() {
        guard let data = JourneyContactService.shared.avatar(for: contact.contactId),
              let image = UIImage(data: data) else {
            return
        }
        avatarImage = image
    }
}

#Preview {
    List {
        JourneyContactRow(
            contact: JourneyContactRef(
                nodeId: UUID(),
                contactId: nil,
                displayName: "Max Mustermann",
                email: "max@example.com",
                role: .assignee
            ),
            onDelete: {}
        )

        JourneyContactRow(
            contact: JourneyContactRef(
                nodeId: UUID(),
                contactId: nil,
                displayName: "Anna Schmidt",
                phone: "+49 123 456789",
                role: .reviewer
            ),
            onDelete: nil
        )
    }
}
