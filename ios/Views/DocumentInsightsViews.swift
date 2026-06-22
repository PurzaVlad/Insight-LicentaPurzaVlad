import SwiftUI
import PDFKit

// MARK: - Document Insights View
struct DocumentInsightsView: View {
    let document: Document
    let fileURL: URL
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss

    private var relatedDocuments: [Document] {
        let myTags = Set(document.tags.map { $0.lowercased() })
        let myKeyword = document.keywordsResume.lowercased().trimmingCharacters(in: .whitespaces)
        return documentManager.documents
            .filter { $0.id != document.id }
            .compactMap { other -> (Document, Int)? in
                var score = myTags.intersection(Set(other.tags.map { $0.lowercased() })).count * 2
                let otherKW = other.keywordsResume.lowercased().trimmingCharacters(in: .whitespaces)
                if !myKeyword.isEmpty && myKeyword == otherKW { score += 1 }
                return score > 0 ? (other, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { $0.0 }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(typeColor(document.type).opacity(0.12))
                                .frame(width: 46, height: 46)
                            Image(systemName: iconForDocumentType(document.type))
                                .font(.system(size: 21, weight: .medium))
                                .foregroundColor(typeColor(document.type))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                .font(.headline)
                            if !document.keywordsResume.isEmpty {
                                Text(document.keywordsResume)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                if !document.tags.isEmpty {
                    Section("Tags") {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 8
                        ) {
                            ForEach(document.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .foregroundColor(Color("Primary"))
                                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                                    .background(Color("Primary").opacity(0.1))
                                    .cornerRadius(14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color("Primary").opacity(0.25), lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !relatedDocuments.isEmpty {
                    Section("Related Documents") {
                        ForEach(relatedDocuments) { related in
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(typeColor(related.type).opacity(0.12))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: iconForDocumentType(related.type))
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(typeColor(related.type))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(splitDisplayTitle(related.title).base)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    if !related.keywordsResume.isEmpty {
                                        Text(related.keywordsResume)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("File Info") {
                    insightRow("Name", splitDisplayTitle(document.title).base)
                    insightRow("Size", formattedSize)
                    insightRow("Date Added", dateAdded)
                    insightRow("Extension", fileExt)
                    insightRow("Source", sourceLabel)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
        }
    }

    private func insightRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func typeColor(_ type: Document.DocumentType) -> Color {
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

    private var sourceLabel: String {
        document.type == .scanned ? "Scanned" : "Imported"
    }

    private var fileExt: String {
        let ext = fileURL.pathExtension.lowercased()
        return ext.isEmpty ? fileExtension(for: document.type) : ext
    }

    private var formattedSize: String {
        let bytes: Int = {
            if let d = documentManager.originalFileData(for: document.id) { return d.count }
            if let d = documentManager.pdfData(for: document.id) { return d.count }
            if let imgs = documentManager.imageData(for: document.id) { return imgs.reduce(0) { $0 + $1.count } }
            return document.content.utf8.count
        }()
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private var dateAdded: String {
        DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .short)
    }
}

struct DocumentInfoView: View {
    let document: Document
    let fileURL: URL
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    infoRow("Name", splitDisplayTitle(document.title).base)
                    infoRow("Size", formattedSize)
                    infoRow("Source", sourceLabel)
                    infoRow("Extension", fileExtension)
                    infoRow("Date Added", dateAdded)
                }

                Section("Extracted OCR") {
                    if ocrText.isEmpty {
                        Text("No OCR text available.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(ocrText)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .foregroundColor(.primary)
                    }
                }

            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var sourceLabel: String {
        document.type == .scanned ? "Scanned" : "Imported"
    }

    private var fileExtension: String {
        // Prefer the actual file URL extension when present.
        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty { return ext }

        switch document.type {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .xls: return "xls"
        case .xlsx: return "xlsx"
        case .image: return "jpg"
        case .scanned: return "pdf"
        case .text: return "txt"
        case .zip: return "zip"
        }
    }

    private var formattedSize: String {
        let bytes: Int = {
            if let d = documentManager.originalFileData(for: document.id) { return d.count }
            if let d = documentManager.pdfData(for: document.id) { return d.count }
            if let imgs = documentManager.imageData(for: document.id) { return imgs.reduce(0) { $0 + $1.count } }
            return document.content.utf8.count
        }()

        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private var dateAdded: String {
        DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .short)
    }

    private var tagsText: String {
        let tags = document.tags
        if tags.isEmpty { return "None" }
        return tags.joined(separator: ", ")
    }

    private var ocrText: String {
        let hasLiveSource = document.sourceDocumentId != nil &&
            document.summary == DocumentManager.summaryUnavailableMessage
        if hasLiveSource {
            return DocumentManager.ocrUnavailableWhileSourceExistsMessage
        }
        guard let pages = document.ocrPages, !pages.isEmpty else { return "" }
        return buildStructuredText(from: pages, includePageLabels: true)
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        guard !pages.isEmpty else { return "" }

        func paragraphize(_ lines: [(text: String, y: Double)]) -> String {
            var output: [String] = []
            var lastY: Double? = nil

            for line in lines {
                if let last = lastY, abs(line.y - last) > 0.04 {
                    output.append("")
                }
                output.append(line.text)
                lastY = line.y
            }

            return output.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        }

        var result: [String] = []
        for page in pages {
            let sorted = page.blocks.sorted { $0.order < $1.order }
            var lines: [(text: String, y: Double)] = []

            for block in sorted {
                if let last = lines.last, abs(block.bbox.y - last.y) < 0.02 {
                    let combined = last.text.isEmpty ? block.text : "\(last.text) \(block.text)"
                    lines[lines.count - 1] = (combined, last.y)
                } else {
                    lines.append((block.text, block.bbox.y))
                }
            }

            let body = paragraphize(lines)
            if includePageLabels {
                result.append("Page \(page.pageIndex + 1):\n\(body)")
            } else {
                result.append(body)
            }
        }

        return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Document Summary View
struct DocumentSummaryView: View {
    let document: Document
    @State private var summary: String = ""
    @State private var isGeneratingSummary = false
    @State private var selectedSummaryLength: SummaryLength = .medium
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var documentManager: DocumentManager

    private var currentDoc: Document {
        documentManager.getDocument(by: document.id) ?? document
    }

    private var supportsAISummary: Bool {
        document.type != .zip
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary section
                    VStack(alignment: .leading, spacing: 12) {
                        if !supportsAISummary {
                            Text("Summaries are unavailable for ZIP files.")
                                .foregroundColor(.secondary)
                                .padding(.vertical)
                        } else if isGeneratingSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical)
                        } else if summary.isEmpty {
                            Text("No summary.")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical)
                        } else {
                            Text(formatMarkdownText(summary))
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    .cornerRadius(10)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Document Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
              
                if supportsAISummary {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Picker("Length", selection: $selectedSummaryLength) {
                                Text("Short").tag(SummaryLength.short)
                                Text("Medium").tag(SummaryLength.medium)
                                Text("Long").tag(SummaryLength.long)
                            }
                            Button {
                                generateAISummary(force: true)
                            } label: {
                                Text(isGeneratingSummary ? "Generating..." : "Regenerate")
                            }
                            .disabled(isGeneratingSummary)
                        } label: {
                            Image(systemName: "text.viewfinder")
                                .imageScale(.large)
                        }
                    }
                }
            }
        }
        .onAppear {
            // Repair Word content if it was previously saved as XML noise
            Task { await documentManager.refreshContentIfNeeded(for: document.id) }
            // Use saved summary if available; avoid regenerating every time
            self.summary = currentDoc.summary
            let s = self.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholder = s.isEmpty || s == "Processing..." || s.contains("Processing summary")
            self.isGeneratingSummary = supportsAISummary && isPlaceholder
        }
        .onChange(of: currentDoc.summary) { newValue in
            if summary != newValue {
                summary = newValue
            }
        }
        .onChange(of: selectedSummaryLength) { _ in
            generateAISummary(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryGenerationStatus"))) { notification in
            guard let userInfo = notification.userInfo,
                  let idString = userInfo["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }
            guard docId == document.id else { return }
            if let active = userInfo["isActive"] as? Bool {
                isGeneratingSummary = active
            }
        }
    }

    private func generateAISummary(force: Bool) {
        AppLogger.ui.debug("DocumentSummaryView: Requesting AI summary for '\(document.title)'")
        isGeneratingSummary = true
        documentManager.generateSummary(
            for: currentDoc,
            force: force,
            length: selectedSummaryLength
        )
    }

}
