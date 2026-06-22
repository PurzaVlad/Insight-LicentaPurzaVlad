import SwiftUI

// MARK: - Folder Suggestion Card

struct FolderSuggestionCardView: View {
    let suggestion: FolderSuggestion
    let documentManager: DocumentManager
    let onReviewSplit: () -> Void

    var body: some View {
        switch suggestion.kind {
        case .moveToFolder(let docId, _, let path):
            let docTitle = documentManager.getDocument(by: docId)?.title ?? "Document"
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to \(path)?")
                        .font(.subheadline.weight(.medium))
                    Text(docTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Move") {
                    documentManager.acceptFolderSuggestion(suggestion)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    documentManager.dismissFolderSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        case .createFolderAndMove(let docId, let name, _):
            let docTitle = documentManager.getDocument(by: docId)?.title ?? "Document"
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create \"\(name)\" folder?")
                        .font(.subheadline.weight(.medium))
                    Text(docTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Create") {
                    documentManager.acceptFolderSuggestion(suggestion)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    documentManager.dismissFolderSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

        case .splitFolder(let folderId, let proposed):
            let folderName = documentManager.folders.first(where: { $0.id == folderId })?.name ?? "Folder"
            let docCount = documentManager.documents(in: folderId).count
            let subNames = proposed.prefix(3).map { $0.name }.joined(separator: ", ")
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\"\(folderName)\" has \(docCount) docs")
                        .font(.subheadline.weight(.medium))
                    Text("Split into: \(subNames)\(proposed.count > 3 ? "…" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Review") {
                    onReviewSplit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    documentManager.dismissFolderSuggestion(suggestion)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Folder Split Review Sheet

struct FolderSplitReviewSheet: View {
    let folder: DocumentFolder
    let proposed: [ProposedSubfolder]
    let documentManager: DocumentManager
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("AI suggests splitting \"\(folder.name)\" into \(proposed.count) subfolders based on document topics.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(proposed, id: \.name) { sub in
                    Section(sub.name) {
                        ForEach(sub.documentIds, id: \.self) { docId in
                            if let doc = documentManager.getDocument(by: docId) {
                                Text(doc.title)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Split Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss", action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm Split", action: onConfirm)
                        .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
