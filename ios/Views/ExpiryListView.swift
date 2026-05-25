import SwiftUI

// MARK: - ExpiryListView

struct ExpiryListView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenDocument: (Document) -> Void

    private var sortedDocs: [Document] {
        documentManager.documents
            .filter { $0.expirationDate != nil }
            .sorted { $0.expirationDate! < $1.expirationDate! }
    }

    private var overdue: [Document] {
        sortedDocs.filter { $0.expirationDate! < Date() }
    }

    private var thisMonth: [Document] {
        let now = Date()
        let in30 = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        return sortedDocs.filter { $0.expirationDate! >= now && $0.expirationDate! <= in30 }
    }

    private var upcoming: [Document] {
        let now = Date()
        let in30 = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        return sortedDocs.filter { $0.expirationDate! > in30 }
    }

    var body: some View {
        Group {
            if sortedDocs.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Expirations")
        .navigationBarTitleDisplayMode(.large)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - List

    private var list: some View {
        List {
            if !overdue.isEmpty {
                Section("Overdue") {
                    ForEach(overdue) { doc in
                        ExpiryListRow(document: doc) { onOpenDocument(doc) }
                    }
                }
            }
            if !thisMonth.isEmpty {
                Section("This Month") {
                    ForEach(thisMonth) { doc in
                        ExpiryListRow(document: doc) { onOpenDocument(doc) }
                    }
                }
            }
            if !upcoming.isEmpty {
                Section("Upcoming") {
                    ForEach(upcoming) { doc in
                        ExpiryListRow(document: doc) { onOpenDocument(doc) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("No Expirations Detected")
                .font(.headline)
            Text("Import documents with expiry dates — contracts, insurance cards, passports — and they'll appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ExpiryListRow

struct ExpiryListRow: View {
    let document: Document
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(urgencyColor.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: typeIcon)
                        .font(.system(size: 18))
                        .foregroundColor(urgencyColor)
                }

                // Title + label
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let label = document.expirationLabel {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Days badge
                Text(daysLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(urgencyColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(urgencyColor.opacity(0.12))
                    .clipShape(Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var daysLabel: String {
        guard let date = document.expirationDate else { return "" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day ?? 0
        if days < 0 { return "Expired" }
        if days == 0 { return "Today" }
        if days == 1 { return "1 day" }
        if days < 30 { return "\(days) days" }
        let months = days / 30
        return months == 1 ? "1 month" : "\(months) months"
    }

    private var urgencyColor: Color {
        guard let date = document.expirationDate else { return .secondary }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days < 0 { return .red }
        if days <= 7 { return .red }
        if days <= 30 { return .orange }
        return .green
    }

    private var typeIcon: String {
        switch document.type {
        case .pdf, .scanned: return "doc.richtext"
        case .docx: return "doc.text"
        case .xls, .xlsx: return "tablecells"
        case .ppt, .pptx: return "play.rectangle"
        case .image: return "photo"
        case .zip: return "archivebox"
        case .text: return "doc.plaintext"
        }
    }
}
