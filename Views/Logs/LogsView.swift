import SwiftUI

struct LogsView: View {
    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Text("logs.selection.title")
                    .font(.largeTitle)
                    .bold()
                Text("logs.selection.subtitle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 20)
            
            // Drei große Kacheln
            VStack(spacing: 16) {
                // 1. Notiz schreiben
                NavigationLink(destination: SchreibenView()) {
                    SelectionCard(
                        icon: "square.and.pencil",
                        title: String(localized: "logs.selection.write"),
                        color: .blue
                    )
                }
                .buttonStyle(.plain)
                
                // 2. Sprachaufnahme
                NavigationLink(destination: SprechenView()) {
                    SelectionCard(
                        icon: "mic.fill",
                        title: String(localized: "logs.selection.speak"),
                        color: .red
                    )
                }
                .buttonStyle(.plain)
                
                // 3. Text & Audio Logs
                NavigationLink(destination: LogsListView()) {
                    SelectionCard(
                        icon: "list.bullet.rectangle",
                        title: String(localized: "logs.selection.list"),
                        color: .green
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Selection Card Component
private struct SelectionCard: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(color)
                .frame(width: 60, height: 60)
                .background(color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
    }
}

#Preview {
    NavigationStack {
        LogsView()
    }
}
