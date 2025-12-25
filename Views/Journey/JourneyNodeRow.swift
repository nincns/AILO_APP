// Views/Journey/JourneyNodeRow.swift
import SwiftUI

struct JourneyNodeRow: View {
    let node: JourneyNodeMock

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            nodeIcon
                .font(.title3)
                .frame(width: 28)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(node.title)
                    .font(.body)
                    .lineLimit(1)

                // Tags oder Status
                if node.nodeType == .task, let status = node.status {
                    HStack(spacing: 6) {
                        Text(status.title)
                            .font(.caption)
                            .foregroundStyle(statusColor(status))

                        if let progress = node.progress, progress > 0 && progress < 100 {
                            Text("\(progress)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let dueDate = node.dueDate {
                            Text(dueDate, style: .date)
                                .font(.caption)
                                .foregroundStyle(isDueSoon(dueDate) ? .red : .secondary)
                        }
                    }
                } else if !node.tags.isEmpty {
                    Text(node.tags.prefix(3).joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Progress indicator für Tasks
            if node.nodeType == .task, let progress = node.progress {
                CircularProgressView(progress: Double(progress) / 100.0)
                    .frame(width: 24, height: 24)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var nodeIcon: some View {
        switch node.nodeType {
        case .folder:
            Image(systemName: "folder.fill")
                .foregroundStyle(.yellow)
        case .entry:
            Image(systemName: "doc.text.fill")
                .foregroundStyle(sectionColor)
        case .task:
            if let status = node.status {
                Image(systemName: status.icon)
                    .foregroundStyle(statusColor(status))
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.gray)
            }
        }
    }

    private var sectionColor: Color {
        switch node.section {
        case .inbox: return .orange
        case .journal: return .purple
        case .wiki: return .blue
        case .projects: return .green
        }
    }

    private func statusColor(_ status: JourneyTaskStatus) -> Color {
        switch status {
        case .open: return .gray
        case .inProgress: return .blue
        case .done: return .green
        case .cancelled: return .red
        }
    }

    private func isDueSoon(_ date: Date) -> Bool {
        date < Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    }
}

// Mini Progress Circle
struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    List {
        JourneyNodeRow(node: JourneyMockData.projects.first!.children!.first!)
        JourneyNodeRow(node: JourneyMockData.wiki.first!)
        JourneyNodeRow(node: JourneyMockData.inbox.first!)
    }
}
