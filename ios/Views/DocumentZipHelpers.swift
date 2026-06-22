import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Drag provider

func makeDragProvider(for id: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let text = id.uuidString
    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerObject(text as NSString, visibility: .all)
    return provider
}

// MARK: - Move destination row

@ViewBuilder
func moveDestinationRow(title: String, subtitle: String, icon: String, isSelected: Bool) -> some View {
    HStack(spacing: 12) {
        Image(systemName: icon)
            .foregroundColor(Color("Primary"))
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        Spacer()
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundColor(Color("Primary"))
        }
    }
}

// MARK: - Zip export

func documentsForZipExport(
    documentManager: DocumentManager,
    selectedDocumentIds: Set<UUID>,
    selectedFolderIds: Set<UUID>
) -> [Document] {
    var ids = selectedDocumentIds
    for folderId in selectedFolderIds {
        let descendantIds = documentManager.descendantFolderIds(of: folderId).union([folderId])
        for doc in documentManager.documents {
            if let docFolderId = doc.folderId, descendantIds.contains(docFolderId) {
                ids.insert(doc.id)
            }
        }
    }
    return documentManager.documents.filter { ids.contains($0.id) }
}

func zipRelativePathForDocument(_ document: Document, folders: [DocumentFolder]) -> String {
    let parts = zipFolderPathComponents(for: document.folderId, folders: folders)
    let fileName = zipFileNameForDocument(document)
    if parts.isEmpty { return fileName }
    return parts.joined(separator: "/") + "/" + fileName
}

func zipFolderPathComponents(for folderId: UUID?, folders: [DocumentFolder]) -> [String] {
    guard let folderId else { return [] }
    var components: [String] = []
    var currentId: UUID? = folderId
    while let id = currentId,
          let folder = folders.first(where: { $0.id == id }) {
        components.append(folder.name)
        currentId = folder.parentId
    }
    return components.reversed()
}

func zipFileNameForDocument(_ document: Document) -> String {
    let parts = splitDisplayTitle(document.title)
    let base = zipSanitizedFileName(parts.base.isEmpty ? "Document" : parts.base)
    let ext = parts.ext.isEmpty ? fileExtension(for: document.type) : parts.ext
    return base + "." + ext
}

func zipSanitizedFileName(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    return name.components(separatedBy: invalid).joined(separator: "-")
}

func zipDataForDocument(_ document: Document, documentManager: DocumentManager) -> Data? {
    if let data = documentManager.anyFileData(for: document.id) { return data }
    return document.content.data(using: .utf8)
}

func zipShortDateString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return formatter.string(from: Date())
}

func makeZipExportDocument(title: String, data: Data, folderId: UUID?) -> Document {
    Document(
        title: title,
        content: "ZIP archive",
        summary: "ZIP archive",
        dateCreated: Date(),
        folderId: folderId,
        type: .zip,
        imageData: nil,
        pdfData: nil,
        originalFileData: data
    )
}

// MARK: - Protected PDF preview

func isProtectedPDFPreview(_ document: Document, documentManager: DocumentManager) -> Bool {
    guard document.type == .pdf || document.type == .scanned else { return false }
    guard let data = documentManager.pdfData(for: document.id) ?? documentManager.originalFileData(for: document.id),
          let pdf = PDFDocument(data: data) else { return false }
    return pdf.isEncrypted
}

struct ProtectedPDFUnlockSheet: View {
    let documentTitle: String
    @Binding var password: String
    let errorMessage: String
    let isUnlocking: Bool
    let onCancel: () -> Void
    let onUnlock: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                Text(splitDisplayTitle(documentTitle).base)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                Text("This PDF is protected. Enter the password to open it.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                    .padding(.horizontal)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            .navigationTitle("Unlock PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isUnlocking ? "Unlocking..." : "Unlock") { onUnlock() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("Primary"))
                        .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isUnlocking)
                }
            }
        }
    }
}
