import SwiftUI
import UniformTypeIdentifiers

struct DocumentRowView: View {
    let document: Document
    let isSelected: Bool
    let isSelectionMode: Bool
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void
    @EnvironmentObject private var documentManager: DocumentManager

    var showsMoveToFolder: Bool = true
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void

    var body: some View {
        let parts = splitDisplayTitle(document.title)
        let dateText = DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .none)
        let typeText = fileTypeLabel(documentType: document.type, titleParts: parts)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if document.type == .zip {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color("Primary"))

                            Image(systemName: zipSymbolName())
                                .foregroundColor(.white)
                                .font(.system(size: 20))
                        }
                    } else if isProtectedPDFPreview(document, documentManager: documentManager) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color("Primary"))

                            Image(systemName: "lock.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 20))
                        }
                    } else {
                        DocumentThumbnailView(document: document, size: CGSize(width: 50, height: 50))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 2) {
                    Text(parts.base)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(dateText)
                        Text("•")
                        Text(typeText)
                        if !document.sensitiveFlags.isEmpty {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isSelectionMode && !usesNativeSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color("Primary") : .secondary)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .modifier(SelectionTapModifier(
            isSelectionMode: isSelectionMode,
            usesNativeSelection: usesNativeSelection,
            onSelectToggle: onSelectToggle,
            onOpen: onOpen
        ))
        .contextMenu {
            Button(action: onOpen) { Label("Open", systemImage: "doc") }
            Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            if showsMoveToFolder {
                Button(action: onMoveToFolder) { Label("Move to Folder", systemImage: "folder") }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .onDrag { makeDragProvider(for: document.id) }
    }

}

struct DocumentGridItemView: View {
    let document: Document
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onShare: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        let parts = splitDisplayTitle(document.title)
        let previewHeight: CGFloat = 120

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    if document.type == .zip {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color("Primary"))
                        Image(systemName: zipSymbolName())
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    } else if isProtectedPDFPreview(document, documentManager: documentManager) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color("Primary"))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.tertiarySystemBackground))
                        DocumentThumbnailView(document: document, size: CGSize(width: side, height: side))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(width: side, height: side)
            }
            .frame(height: previewHeight)
            .cornerRadius(10)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .overlay(alignment: .topLeading) {
                if isSelectionMode {
                    NativeGridSelectionIndicator(isSelected: isSelected)
                        .padding(.top, 6)
                        .padding(.leading, 6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.base)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(fileTypeLabel(documentType: document.type, titleParts: parts))")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onSelectToggle()
            } else {
                onOpen()
            }
        }
        .contextMenu {
            Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
    }
}

struct FolderRowView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    var isDropTargeted: Bool = false

    var body: some View {
        let dateText = DateFormatter.localizedString(from: folder.dateCreated, dateStyle: .medium, timeStyle: .none)
        let countText = "\(docCount) item\(docCount == 1 ? "" : "s")"

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color("Primary"))
                        .frame(width: 50, height: 50)

                    Image(systemName: "folder.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(dateText)
                        Text("•")
                        Text(countText)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isSelectionMode && !usesNativeSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color("Primary") : .secondary)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .modifier(SelectionTapModifier(
            isSelectionMode: isSelectionMode,
            usesNativeSelection: usesNativeSelection,
            onSelectToggle: onSelectToggle,
            onOpen: onOpen
        ))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color("Primary").opacity(0.18) : Color.clear)
        )
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct NativeGridSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 0.5)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isSelected)
    }
}

private struct SelectionTapModifier: ViewModifier {
    let isSelectionMode: Bool
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        if usesNativeSelection {
            content
        } else {
            content
                .onTapGesture {
                    if isSelectionMode {
                        onSelectToggle()
                    } else {
                        onOpen()
                    }
                }
        }
    }
}

struct FolderDropDelegate: DropDelegate {
    let folderId: UUID
    let documentManager: DocumentManager
    let onHoverChange: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText, UTType.text, UTType.data])
    }

    func dropEntered(info: DropInfo) {
        DispatchQueue.main.async {
            onHoverChange(true)
        }
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.async {
            onHoverChange(false)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText, UTType.text, UTType.data]).first else { return false }
        let preferredType = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : (provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ? UTType.text.identifier : UTType.data.identifier)

        provider.loadDataRepresentation(forTypeIdentifier: preferredType) { data, _ in
            let uuidString: String? = {
                if let data { return String(data: data, encoding: .utf8) }
                return nil
            }()

            guard let uuidString, let id = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                onHoverChange(false)
                // Check if it's a document or a folder and move accordingly
                if documentManager.documents.contains(where: { $0.id == id }) {
                    documentManager.moveDocument(documentId: id, toFolder: folderId)
                } else if documentManager.folders.contains(where: { $0.id == id }) {
                    // Prevent moving folder into itself
                    if id != folderId {
                        documentManager.moveFolder(folderId: id, toParent: folderId)
                    }
                }
            }
        }
        return true
    }
}

struct SettingsSheetBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.presentationBackground(.regularMaterial)
    }
}

struct ListFolderDropDelegate: DropDelegate {
    let folderId: UUID
    let documentManager: DocumentManager
    @Binding var dropTargetedFolderId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText, UTType.text, UTType.data])
    }

    func dropEntered(info: DropInfo) {
        DispatchQueue.main.async {
            dropTargetedFolderId = folderId
        }
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.async {
            if dropTargetedFolderId == folderId {
                dropTargetedFolderId = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText, UTType.text, UTType.data]).first else { return false }
        let preferredType = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : (provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ? UTType.text.identifier : UTType.data.identifier)

        provider.loadDataRepresentation(forTypeIdentifier: preferredType) { data, _ in
            let uuidString: String? = {
                if let data { return String(data: data, encoding: .utf8) }
                return nil
            }()

            guard let uuidString, let id = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                dropTargetedFolderId = nil
                // Check if it's a document or a folder and move accordingly
                if documentManager.documents.contains(where: { $0.id == id }) {
                    documentManager.moveDocument(documentId: id, toFolder: folderId)
                } else if documentManager.folders.contains(where: { $0.id == id }) {
                    // Prevent moving folder into itself
                    if id != folderId {
                        documentManager.moveFolder(folderId: id, toParent: folderId)
                    }
                }
            }
        }
        return true
    }
}

struct CheckeredPatternView: View {
    var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 4
            let rows = Int(ceil(size.height / tileSize))
            let cols = Int(ceil(size.width / tileSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )

                    context.fill(
                        Path(rect),
                        with: .color(isEven ? .gray.opacity(0.3) : .gray.opacity(0.1))
                    )
                }
            }
        }
    }
}

struct FolderGridItemView: View {
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    var isDropTargeted: Bool = false
    let onLongPress: () -> Void

    var body: some View {
        let previewHeight: CGFloat = 120
        let parts = splitDisplayTitle(folder.name)

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color("Primary"))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
                .frame(width: side, height: side)
            }
            .frame(height: previewHeight)
            .cornerRadius(10)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .overlay(alignment: .topLeading) {
                if isSelectionMode {
                    NativeGridSelectionIndicator(isSelected: isSelected)
                        .padding(.top, 6)
                        .padding(.leading, 6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.base)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(docCount) item\(docCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onSelectToggle()
            } else {
                onOpen()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color("Primary").opacity(0.18) : Color.clear)
        )
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
    }
}
