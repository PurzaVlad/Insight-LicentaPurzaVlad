import SwiftUI

// MARK: - Model

struct ImportBatchResult: Identifiable {
    let id = UUID()
    let documentIds: [UUID]
    let importedAt: Date
}

// MARK: - ImportReviewView

struct ImportReviewView: View {
    let result: ImportBatchResult
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss

    // Snapshot at presentation time so background keyword updates don't wipe sensitive flags
    @State private var snapshotDocuments: [Document] = []

    private var documents: [Document] {
        snapshotDocuments.isEmpty
            ? result.documentIds.compactMap { documentManager.getDocument(by: $0) }
            : snapshotDocuments
    }

    private var allSensitiveFlags: [SensitiveDataFlag] {
        let flagSet = documents.reduce(into: Set<SensitiveDataFlag>()) { set, doc in
            doc.sensitiveFlags.forEach { set.insert($0) }
        }
        return SensitiveDataFlag.allCases.filter { flagSet.contains($0) }
    }

    private var typeCounts: [(Document.DocumentType, Int)] {
        Dictionary(grouping: documents) { $0.type }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
    }

    private var topics: [String] {
        Array(
            Set(documents.compactMap { doc -> String? in
                let kw = doc.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
                return kw.isEmpty ? nil : kw
            })
        ).sorted()
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    heroSection
                    if !allSensitiveFlags.isEmpty { sensitiveSection }
                    if !typeCounts.isEmpty { typeSection }
                    if !topics.isEmpty { topicsSection }
                    documentListSection
                    Spacer(minLength: 40)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Import Complete")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if snapshotDocuments.isEmpty {
                    snapshotDocuments = result.documentIds.compactMap { documentManager.getDocument(by: $0) }
                }
            }
            .onReceive(documentManager.objectWillChange) {
                for i in snapshotDocuments.indices {
                    guard let updated = documentManager.getDocument(by: snapshotDocuments[i].id) else { continue }
                    if snapshotDocuments[i].keywordsResume.isEmpty && !updated.keywordsResume.isEmpty {
                        snapshotDocuments[i] = snapshotDocuments[i].with(keywordsResume: updated.keywordsResume)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Sections

    private var sensitiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                Text("Sensitive Data Detected")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(allSensitiveFlags.enumerated()), id: \.element.rawValue) { index, flag in
                    HStack(spacing: 10) {
                        Image(systemName: flag.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                            .frame(width: 20)
                        Text(flag.label)
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    if index < allSensitiveFlags.count - 1 {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)

            Text("These documents may contain personal or financial information.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
        }
    }

    private var heroSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
                .padding(.top, 20)
            Text("\(result.documentIds.count)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
            Text(result.documentIds.count == 1 ? "Document Imported" : "Documents Imported")
                .font(.title3)
                .foregroundColor(.secondary)
        }
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("File Types")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(typeCounts, id: \.0.rawValue) { type, count in
                        ImportTypeChip(type: type, count: count)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Detected Topics")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(topics, id: \.self) { topic in
                        ImportTopicPill(topic: topic)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var documentListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Documents")
            VStack(spacing: 0) {
                ForEach(Array(documents.enumerated()), id: \.element.id) { index, doc in
                    ImportDocRow(document: doc, availableKeywords: allKeywords, onKeywordChange: { newKeyword in
                        changeKeyword(doc, to: newKeyword)
                    })
                    if index < documents.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
        }
    }

    private var allKeywords: [String] {
        let fromDocs = Set(documentManager.documents.compactMap { doc -> String? in
            let kw = doc.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
            return kw.isEmpty ? nil : kw
        })
        let predefined: [String] = [
            "Finance", "Healthcare", "Legal", "Tax Return", "Real Estate",
            "Education", "Technology", "Medical", "Insurance", "Business",
            "Personal", "Travel", "Contract", "Invoice", "Report"
        ]
        var combined = predefined
        for kw in fromDocs.sorted() where !combined.contains(kw) {
            combined.append(kw)
        }
        return combined
    }

    private func changeKeyword(_ document: Document, to keyword: String) {
        let updated = document.with(keywordsResume: keyword)
        if let idx = documentManager.documents.firstIndex(where: { $0.id == document.id }) {
            documentManager.documents[idx] = updated
        }
        if let idx = snapshotDocuments.firstIndex(where: { $0.id == document.id }) {
            snapshotDocuments[idx] = updated
        }
    }

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 16)
    }
}

// MARK: - Type Chip

private struct ImportTypeChip: View {
    let type: Document.DocumentType
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: typeIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(typeColor)
            Text("\(count) \(type.displayName)")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(typeColor.opacity(0.12))
        .cornerRadius(20)
    }

    private var typeIcon: String {
        switch type {
        case .pdf:        return "doc.fill"
        case .docx:       return "doc.richtext"
        case .ppt, .pptx: return "rectangle.on.rectangle"
        case .xls, .xlsx: return "tablecells"
        case .image:      return "photo"
        case .scanned:    return "scanner"
        case .text:       return "doc.text"
        case .zip:        return "archivebox"
        }
    }

    private var typeColor: Color {
        switch type {
        case .pdf:        return .red
        case .docx:       return .blue
        case .ppt, .pptx: return .orange
        case .xls, .xlsx: return .green
        case .image:      return .purple
        case .scanned:    return .teal
        case .text:       return .gray
        case .zip:        return Color(.brown)
        }
    }
}

// MARK: - Topic Pill

private struct ImportTopicPill: View {
    let topic: String

    var body: some View {
        Text(topic)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Color("Primary"))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color("Primary").opacity(0.1))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color("Primary").opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Document Row

private struct ImportDocRow: View {
    let document: Document
    let availableKeywords: [String]
    let onKeywordChange: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(typeColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: typeIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                keywordPicker
            }

            Spacer()

            if !document.sensitiveFlags.isEmpty {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
            }

            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var keywordPicker: some View {
        let current = document.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            Text("Analyzing…")
                .font(.caption)
                .foregroundColor(Color(.tertiaryLabel))
        } else {
            Menu {
                ForEach(availableKeywords, id: \.self) { keyword in
                    Button {
                        onKeywordChange(keyword)
                    } label: {
                        if keyword == current {
                            Label(keyword, systemImage: "checkmark")
                        } else {
                            Text(keyword)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(current)
                        .font(.caption)
                        .foregroundColor(Color("Primary"))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color("Primary"))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color("Primary").opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var typeIcon: String {
        switch document.type {
        case .pdf:        return "doc.fill"
        case .docx:       return "doc.richtext"
        case .ppt, .pptx: return "rectangle.on.rectangle"
        case .xls, .xlsx: return "tablecells"
        case .image:      return "photo"
        case .scanned:    return "scanner"
        case .text:       return "doc.text"
        case .zip:        return "archivebox"
        }
    }

    private var typeColor: Color {
        switch document.type {
        case .pdf:        return .red
        case .docx:       return .blue
        case .ppt, .pptx: return .orange
        case .xls, .xlsx: return .green
        case .image:      return .purple
        case .scanned:    return .teal
        case .text:       return .gray
        case .zip:        return Color(.brown)
        }
    }
}
