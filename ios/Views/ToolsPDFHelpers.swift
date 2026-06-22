import Foundation
import PDFKit

func isPDFDocument(_ document: Document) -> Bool {
    document.type == .pdf || document.type == .scanned
}

func pdfData(from document: Document, documentManager: DocumentManager) -> Data? {
    if let pdfData = documentManager.pdfData(for: document.id) { return pdfData }
    if let original = documentManager.originalFileData(for: document.id) { return original }
    return nil
}

func makePDFDocument(
    title: String,
    data: Data,
    sourceDocumentId: UUID?,
    sourceDocument: Document? = nil,
    inheritMetadata: Bool = true
) -> Document {
    let text = extractText(from: data)
    let summaryText: String
    if inheritMetadata,
       let inheritedSummary = sourceDocument?.summary.trimmingCharacters(in: .whitespacesAndNewlines),
       !inheritedSummary.isEmpty {
        summaryText = inheritedSummary
    } else {
        summaryText = "Processing summary..."
    }
    let inheritedOCRPages = inheritMetadata ? sourceDocument?.ocrPages : nil
    let inheritedTags = inheritMetadata ? (sourceDocument?.tags ?? []) : []
    return Document(
        title: title,
        content: text,
        summary: summaryText,
        ocrPages: inheritedOCRPages,
        tags: inheritedTags,
        sourceDocumentId: sourceDocumentId,
        dateCreated: Date(),
        type: .pdf,
        imageData: nil,
        pdfData: data,
        originalFileData: data
    )
}

func extractText(from data: Data) -> String {
    guard let pdf = PDFDocument(data: data) else { return "" }
    var text = ""
    for idx in 0..<pdf.pageCount {
        if let page = pdf.page(at: idx), let pageText = page.string {
            text += pageText + "\n"
        }
    }
    return text
}

func baseTitle(for title: String) -> String {
    let url = URL(fileURLWithPath: title)
    let base = url.deletingPathExtension().lastPathComponent
    return base.isEmpty ? "PDF" : base
}

func existingDocumentTitles(in documentManager: DocumentManager) -> Set<String> {
    Set(documentManager.documents.map { $0.title.lowercased() })
}

func uniquePDFTitle(preferredBase: String, existingTitles: Set<String>) -> String {
    uniqueTitle(preferredBase: preferredBase, ext: "pdf", existingTitles: existingTitles)
}

func uniqueTitle(preferredBase: String, ext: String, existingTitles: Set<String>) -> String {
    let trimmedBase = preferredBase.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmedBase.isEmpty ? "PDF" : trimmedBase
    let extSuffix = ext.isEmpty ? "" : ".\(ext)"
    var candidate = "\(base)\(extSuffix)"
    let lowerExisting = existingTitles

    if !lowerExisting.contains(candidate.lowercased()) {
        return candidate
    }

    var idx = 2
    while true {
        candidate = "\(base)\(idx)\(extSuffix)"
        if !lowerExisting.contains(candidate.lowercased()) {
            return candidate
        }
        idx += 1
    }
}
