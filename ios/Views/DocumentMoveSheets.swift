import SwiftUI

struct MoveToFolderSheet: View {
    let document: Document
    let folders: [DocumentFolder]
    let currentFolderId: UUID?
    let allFolders: [DocumentFolder]
    let currentContainerName: String
    let allowRootSelection: Bool
    let onSelectFolder: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                if allowRootSelection {
                    Button {
                        onSelectFolder(nil)
                    } label: {
                        moveDestinationRow(
                            title: "Documents",
                            subtitle: "Root",
                            icon: "folder",
                            isSelected: currentFolderId == nil
                        )
                    }
                }

                ForEach(folders) { folder in
                    Button {
                        onSelectFolder(folder.id)
                    } label: {
                        moveDestinationRow(
                            title: folder.name,
                            subtitle: parentLabel(for: folder),
                            icon: "folder.fill",
                            isSelected: currentFolderId == folder.id
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func parentLabel(for folder: DocumentFolder) -> String {
        guard let parentId = folder.parentId else { return "Documents" }
        return allFolders.first(where: { $0.id == parentId })?.name ?? "Documents"
    }
}

struct MoveFolderSheet: View {
    let folder: DocumentFolder
    let folders: [DocumentFolder]
    let currentParentId: UUID?
    let onSelectParent: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Button {
                    onSelectParent(nil)
                } label: {
                    moveDestinationRow(
                        title: "Documents",
                        subtitle: "Root",
                        icon: "folder",
                        isSelected: currentParentId == nil
                    )
                }

                ForEach(folders.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { dest in
                    Button {
                        onSelectParent(dest.id)
                    } label: {
                        moveDestinationRow(
                            title: dest.name,
                            subtitle: parentLabel(for: dest),
                            icon: "folder.fill",
                            isSelected: currentParentId == dest.id
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func parentLabel(for folder: DocumentFolder) -> String {
        guard let parentId = folder.parentId else { return "Documents" }
        return folders.first(where: { $0.id == parentId })?.name ?? "Documents"
    }
}

struct DocumentNameSearchSheet: View {
    @Binding var query: String
    let documents: [Document]
    let onSelect: (Document) -> Void
    let onClose: () -> Void

    private var matches: [Document] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()
        return documents.filter { doc in
            let title = doc.title.lowercased()
            if title.hasPrefix(q) { return true }
            let base = splitDisplayTitle(doc.title).base.lowercased()
            return base.hasPrefix(q)
        }
        .sorted { a, b in
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            List {
                if matches.isEmpty {
                } else {
                    ForEach(matches) { doc in
                        Button {
                            onSelect(doc)
                        } label: {
                            HStack {
                                Image(systemName: iconForDocumentType(doc.type))
                                    .foregroundColor(.blue)
                                Text(doc.title)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Find Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { onClose() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Enter document name")
        }
    }
}

struct BulkMoveSheet: View {
    let folders: [DocumentFolder]
    let currentParentId: UUID?
    let onSelectParent: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Button {
                    onSelectParent(nil)
                } label: {
                    moveDestinationRow(
                        title: "Documents",
                        subtitle: "Root",
                        icon: "folder",
                        isSelected: currentParentId == nil
                    )
                }

                ForEach(folders.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { dest in
                    Button {
                        onSelectParent(dest.id)
                    } label: {
                        moveDestinationRow(
                            title: dest.name,
                            subtitle: parentLabel(for: dest),
                            icon: "folder.fill",
                            isSelected: currentParentId == dest.id
                        )
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }

    private func parentLabel(for folder: DocumentFolder) -> String {
        guard let parentId = folder.parentId else { return "Documents" }
        return folders.first(where: { $0.id == parentId })?.name ?? "Documents"
    }
}
