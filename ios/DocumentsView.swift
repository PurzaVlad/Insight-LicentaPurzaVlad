import SwiftUI
import UIKit
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import QuickLookThumbnailing
import Foundation
import AVFoundation
import SSZipArchive
import OSLog

// MARK: - Drag & Drop modifiers
extension View {
    @ViewBuilder
    func folderDraggable(_ id: UUID) -> some View {
        self.draggable(id.uuidString)
    }
    
    @ViewBuilder
    func folderDropDestination(
        folderId: UUID,
        documentManager: DocumentManager,
        dropTargetedFolderId: Binding<UUID?>
    ) -> some View {
        self.dropDestination(for: String.self) { items, _ in
            guard let uuidString = items.first, let id = UUID(uuidString: uuidString) else { return false }
            if id == folderId { return false }
            if documentManager.documents.contains(where: { $0.id == id }) {
                documentManager.moveDocument(documentId: id, toFolder: folderId)
                return true
            } else if documentManager.folders.contains(where: { $0.id == id }) {
                documentManager.moveFolder(folderId: id, toParent: folderId)
                return true
            }
            return false
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetedFolderId.wrappedValue = folderId
            } else if dropTargetedFolderId.wrappedValue == folderId {
                dropTargetedFolderId.wrappedValue = nil
            }
        }
    }
}

private struct TabBarVisibilityModifier: ViewModifier {
    let isHidden: Bool

    func body(content: Content) -> some View {
        content.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
    }
}

private struct BottomBarVisibilityModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.toolbar(isVisible ? .visible : .hidden, for: .bottomBar)
    }
}

private struct TabBarControllerAccessor: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.tabBarController?.tabBar.isHidden = isHidden
    }
}

extension View {
    func tabBarVisibility(_ isHidden: Bool) -> some View {
        self.modifier(TabBarVisibilityModifier(isHidden: isHidden))
    }

    func tabBarHiddenCompat(_ isHidden: Bool) -> some View {
        self.background(TabBarControllerAccessor(isHidden: isHidden))
    }

    func bottomBarVisibility(_ isVisible: Bool) -> some View {
        self.modifier(BottomBarVisibilityModifier(isVisible: isVisible))
    }
}

enum DocumentLayoutMode {
    case list
    case grid
}

enum ScannerMode {
    case document
    case simple
}

enum DocumentsSortMode: String, CaseIterable {
    case dateNewest = "newest"
    case dateOldest = "oldest"
    case nameAsc = "alphabetically"
    case nameDesc = "alphabetically_desc"
    case accessNewest = "access_newest"
    case accessOldest = "access_oldest"

    var title: String {
        switch self {
        case .dateNewest: return "Newest"
        case .dateOldest: return "Oldest"
        case .nameAsc: return "A → Z"
        case .nameDesc: return "Z → A"
        case .accessNewest: return "Most Recent"
        case .accessOldest: return "Least Recent"
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest: return "arrow.down"
        case .dateOldest: return "arrow.up"
        case .nameAsc, .nameDesc: return "textformat"
        case .accessNewest, .accessOldest: return "clock"
        }
    }
}

enum MixedItemKind {
    case folder(DocumentFolder)
    case document(Document)
}

struct MixedItem: Identifiable {
    let id: UUID
    let kind: MixedItemKind
    let name: String
    let dateCreated: Date
}

struct DocumentsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void
    var isEmbedded: Bool = false
    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var isProcessing = false
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText: String = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var pendingCategory: Document.DocumentCategory = .general
    @State private var pendingKeywordsResume: String = ""
    @State private var isOpeningPreview = false
    @State private var activeFolderForRoot: DocumentFolder? = nil
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var documentToRename: Document?
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }

    @State private var showingNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var newFolderDescription = ""
    @State private var documentToMove: Document?
    @State private var showingSplitReviewSheet = false
    @State private var splitReviewSuggestion: FolderSuggestion?

    @State private var showingRenameFolderDialog = false
    @State private var renameFolderText = ""
    @State private var folderToRename: DocumentFolder?

    @State private var showingMoveFolderSheet = false
    @State private var folderToMove: DocumentFolder?

    @State private var showingDeleteFolderDialog = false
    @State private var folderToDelete: DocumentFolder?

    @State private var showingZipExportSheet = false
    @State private var showingQuickZipNamePrompt = false
    @State private var quickZipName = ""
    @State private var showingQuickZipAlert = false
    @State private var quickZipAlertMessage = ""

    @State private var isSelectionMode = false
    @State private var selectedDocumentIds: Set<UUID> = []
    @State private var selectedFolderIds: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var showingBulkDeleteDialog = false
    @State private var showingBulkMoveSheet = false
    @State private var showingNameSearch = false
    @State private var nameSearchText = ""
    @State private var showingSettings = false
    @State private var isFolderSelectionModeActive = false
    @State private var dropTargetedFolderId: UUID? = nil
    @State private var protectedUnlockTarget: Document?
    @State private var protectedUnlockPassword = ""
    @State private var protectedUnlockError = ""
    @State private var showingSmartViews = false
    @State private var pendingSmartViewDocument: Document?
    @State private var importBatchResult: ImportBatchResult?
    @AppStorage("documentsSortMode") private var documentsSortModeRaw = DocumentsSortMode.dateNewest.rawValue

    private var documentsSortMode: DocumentsSortMode {
        get { DocumentsSortMode(rawValue: documentsSortModeRaw) ?? .dateNewest }
        nonmutating set { documentsSortModeRaw = newValue.rawValue }
    }

    private func toggleNameSort() {
        documentsSortMode = (documentsSortMode == .nameAsc) ? .nameDesc : .nameAsc
    }

    private func toggleDateSort() {
        documentsSortMode = (documentsSortMode == .dateNewest) ? .dateOldest : .dateNewest
    }

    private func toggleAccessSort() {
        documentsSortMode = (documentsSortMode == .accessNewest) ? .accessOldest : .accessNewest
    }

    private func toggleRootSelectAll() {
        if rootIsAllSelected {
            selectedDocumentIds.removeAll()
            selectedFolderIds.removeAll()
        } else {
            selectedDocumentIds = rootSelectableDocumentIds
            selectedFolderIds = rootSelectableFolderIds
        }
    }

    private var listSelectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { selectedDocumentIds.union(selectedFolderIds) },
            set: { newValue in
                let docIds = Set(documentManager.documents.map { $0.id })
                let folderIds = Set(documentManager.folders.map { $0.id })
                selectedDocumentIds = newValue.filter { docIds.contains($0) }
                selectedFolderIds = newValue.filter { folderIds.contains($0) }
            }
        )
    }

    private var rootFolders: [DocumentFolder] { documentManager.folders(in: nil) }
    private var rootDocs: [Document] { documentManager.documents(in: nil) }
    private var hasSelection: Bool { !selectedDocumentIds.isEmpty || !selectedFolderIds.isEmpty }
    private var rootSelectableDocumentIds: Set<UUID> { Set(rootDocs.map { $0.id }) }
    private var rootSelectableFolderIds: Set<UUID> { Set(rootFolders.map { $0.id }) }
    private var rootHasSelectableItems: Bool {
        !rootSelectableDocumentIds.isEmpty || !rootSelectableFolderIds.isEmpty
    }
    private var rootIsAllSelected: Bool {
        rootHasSelectableItems
            && rootSelectableDocumentIds.isSubset(of: selectedDocumentIds)
            && rootSelectableFolderIds.isSubset(of: selectedFolderIds)
    }
    private var shouldHideTabBar: Bool {
        isSelectionMode || isFolderSelectionModeActive
    }

    private var sortMenu: some View {
        Menu {
            ForEach(DocumentsSortMode.allCases, id: \.rawValue) { mode in
                Button {
                    documentsSortModeRaw = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                Button("Scan Document") {
                    startScan()
                }
                .buttonStyle(.borderedProminent)
              
                Text("or")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
              
                Button("Import Files") {
                    showingDocumentPicker = true
                }
                .buttonStyle(.borderedProminent)
            }

            Text("to get started")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var rootListView: some View {
        if isSelectionMode {
            // Use List for native selection support
            List(selection: listSelectionBinding) {
                ForEach(mixedRootItems()) { item in
                    rootListRow(item)
                }
            }
            .listStyle(.plain)
            .hideScrollBackground()
            .environment(\.editMode, $editMode)
        } else {
            // Use ScrollView + LazyVStack for drag and drop support
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(documentManager.pendingSuggestions) { suggestion in
                        FolderSuggestionCardView(
                            suggestion: suggestion,
                            documentManager: documentManager,
                            onReviewSplit: {
                                splitReviewSuggestion = suggestion
                                showingSplitReviewSheet = true
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    ForEach(mixedRootItems()) { item in
                        rootScrollRow(item)
                    }
                }
            }
            .hideScrollBackground()
            .sheet(isPresented: $showingSplitReviewSheet) {
                if let s = splitReviewSuggestion, case .splitFolder(let folderId, let proposed) = s.kind,
                   let folder = documentManager.folders.first(where: { $0.id == folderId }) {
                    FolderSplitReviewSheet(
                        folder: folder,
                        proposed: proposed,
                        documentManager: documentManager,
                        onConfirm: {
                            documentManager.executeSplit(proposed, in: folderId)
                            splitReviewSuggestion = nil
                            showingSplitReviewSheet = false
                        },
                        onDismiss: {
                            documentManager.dismissFolderSuggestion(s)
                            splitReviewSuggestion = nil
                            showingSplitReviewSheet = false
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func rootScrollRow(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                docCount: documentManager.itemCount(in: folder.id),
                isSelected: selectedFolderIds.contains(folder.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleFolderSelection(folder.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: folder.id)
                    activeFolderForRoot = folder
                },
                onRename: {
                    folderToRename = folder
                    renameFolderText = folder.name
                    showingRenameFolderDialog = true
                },
                onMove: {
                    folderToMove = folder
                    showingMoveFolderSheet = true
                },
                onDelete: {
                    folderToDelete = folder
                    showingDeleteFolderDialog = true
                },
                isDropTargeted: dropTargetedFolderId == folder.id
            )
            .padding(.horizontal, 8)
            .onDrag { makeDragProvider(for: folder.id) }
            .onDrop(
                of: [UTType.plainText, UTType.text, UTType.data],
                delegate: ListFolderDropDelegate(
                    folderId: folder.id,
                    documentManager: documentManager,
                    dropTargetedFolderId: $dropTargetedFolderId
                )
            )
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleDocumentSelection(document.id) },
                onOpen: { openDocumentPreview(document: document) },
                onRename: { renameDocument(document) },
                onMoveToFolder: {
                    documentToMove = document
                },
                onDelete: { deleteDocument(document) },
                onShare: { shareDocuments([document]) }
            )
            .padding(.horizontal, 8)
            .onDrag { makeDragProvider(for: document.id) }
        }
    }

    @ViewBuilder
    private func rootListRow(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                docCount: documentManager.itemCount(in: folder.id),
                isSelected: selectedFolderIds.contains(folder.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleFolderSelection(folder.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: folder.id)
                    activeFolderForRoot = folder
                },
                onRename: {
                    folderToRename = folder
                    renameFolderText = folder.name
                    showingRenameFolderDialog = true
                },
                onMove: {
                    folderToMove = folder
                    showingMoveFolderSheet = true
                },
                onDelete: {
                    folderToDelete = folder
                    showingDeleteFolderDialog = true
                },
                isDropTargeted: false
            )
            .tag(folder.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleDocumentSelection(document.id) },
                onOpen: { openDocumentPreview(document: document) },
                onRename: { renameDocument(document) },
                onMoveToFolder: {
                    documentToMove = document
                },
                onDelete: { deleteDocument(document) },
                onShare: { shareDocuments([document]) }
            )
            .tag(document.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        }
    }

    private var rootGridView: some View {
        if isSelectionMode {
            return AnyView(
                NativeDocumentGridView(
                    items: mixedRootItems(),
                    selectedIds: listSelectionBinding,
                    isSelectionMode: $isSelectionMode,
                    dropTargetedFolderId: $dropTargetedFolderId,
                    documentManager: documentManager,
                    onOpenDocument: { openDocumentPreview(document: $0) },
                    onOpenFolder: { folder in
                        documentManager.updateLastAccessed(id: folder.id)
                        activeFolderForRoot = folder
                    },
                    onRenameDocument: { renameDocument($0) },
                    onMoveDocument: { documentToMove = $0 },
                    onDeleteDocument: { deleteDocument($0) },
                    onShareDocuments: { shareDocuments($0) },
                    onRenameFolderRequest: { folder in
                        folderToRename = folder
                        renameFolderText = folder.name
                        showingRenameFolderDialog = true
                    },
                    onMoveFolderRequest: { folder in
                        folderToMove = folder
                        showingMoveFolderSheet = true
                    },
                    onDeleteFolderRequest: { folder in
                        folderToDelete = folder
                        showingDeleteFolderDialog = true
                    }
                )
            )
        }

        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return AnyView(ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(mixedRootItems()) { item in
                    switch item.kind {
                    case .folder(let folder):
                        FolderGridItemView(
                            folder: folder,
                            docCount: documentManager.itemCount(in: folder.id),
                            isSelected: selectedFolderIds.contains(folder.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleFolderSelection(folder.id) },
                            onOpen: {
                                documentManager.updateLastAccessed(id: folder.id)
                                activeFolderForRoot = folder
                            },
                            onRename: {
                                folderToRename = folder
                                renameFolderText = folder.name
                                showingRenameFolderDialog = true
                            },
                            onMove: {
                                folderToMove = folder
                                showingMoveFolderSheet = true
                            },
                            onDelete: {
                                folderToDelete = folder
                                showingDeleteFolderDialog = true
                            },
                            isDropTargeted: dropTargetedFolderId == folder.id,
                            onLongPress: {
                                beginSelection(folderId: folder.id)
                            }
                        )
                        .onDrag { makeDragProvider(for: folder.id) }
                        .onDrop(
                            of: [UTType.plainText, UTType.text, UTType.data],
                            delegate: FolderDropDelegate(
                                folderId: folder.id,
                                documentManager: documentManager,
                                onHoverChange: { isHovering in
                                    dropTargetedFolderId = isHovering ? folder.id : nil
                                }
                            )
                        )
                    case .document(let document):
                        DocumentGridItemView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onOpen: { openDocumentPreview(document: document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: { documentToMove = document },
                            onDelete: { deleteDocument(document) },
                            onShare: { shareDocuments([document]) },
                            onLongPress: {
                                beginSelection(documentId: document.id)
                            }
                        )
                        .onDrag { makeDragProvider(for: document.id) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 24)
        })
    }

    @ViewBuilder
    private var rootBrowserView: some View {
        if layoutMode == .list {
            rootListView
        } else {
            rootGridView
        }
    }

    private var processingOverlayView: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Processing document...")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
        }
    }

    @ToolbarContentBuilder
    private var documentsSelectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(rootIsAllSelected ? "Deselect All" : "Select All") {
                toggleRootSelectAll()
            }
            .disabled(!rootHasSelectableItems)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Cancel") {
                clearSelection()
            }
        }

        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button {
                shareSelectedDocuments()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasSelection)
            Spacer()
            Button {
                showingZipExportSheet = true
            } label: {
                Label("Compress", systemImage: zipSymbolName())
            }
            .disabled(!hasSelection)
            Spacer()
            Button {
                showingBulkMoveSheet = true
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(!hasSelection)
            Spacer()
            Button {
                showingBulkDeleteDialog = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            .disabled(!hasSelection)
            Spacer()
        }
    }

    @ToolbarContentBuilder
    private var documentsNormalToolbar: some ToolbarContent {
        if !isEmbedded {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSmartViews = true
                } label: {
                    Image(systemName: "sparkles.rectangle.stack")
                        .foregroundColor(.primary)
                }
                .accessibilityLabel("Smart Views")
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showingDocumentPicker = true
                } label: {
                    Label("Import Files", systemImage: "square.and.arrow.down")
                }

                Button {
                    startScan()
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }

                Button {
                    newFolderName = ""
                    showingNewFolderDialog = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                
                Button {
                    showingZipExportSheet = true
                } label: {
                    Label("Create Zip", systemImage: zipSymbolName())
                }
            } label: {
                Image(systemName: "plus")
                    .foregroundColor(.primary)
            }
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    DispatchQueue.main.async {
                        isSelectionMode = true
                        editMode = .active
                    }
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }

                Button {
                    showingSettings = true
                } label: {
                    Label("Preferences", systemImage: "gearshape")
                }

                Divider()

                Picker("View", selection: Binding(
                    get: { documentManager.prefersGridLayout },
                    set: { documentManager.setPrefersGridLayout($0) }
                )) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Picker("Sort By", selection: Binding(
                    get: {
                        switch documentsSortMode {
                        case .nameAsc, .nameDesc: return "name"
                        case .dateNewest, .dateOldest: return "date"
                        case .accessNewest, .accessOldest: return "recent"
                        }
                    },
                    set: { group in
                        switch group {
                        case "name": toggleNameSort()
                        case "date": toggleDateSort()
                        case "recent": toggleAccessSort()
                        default: break
                        }
                    }
                )) {
                    let nameText = documentsSortMode == .nameAsc ? "Name ↓" : documentsSortMode == .nameDesc ? "Name ↑" : "Name"
                    let dateText = documentsSortMode == .dateNewest ? "Date ↓" : documentsSortMode == .dateOldest ? "Date ↑" : "Date"
                    let recentText = documentsSortMode == .accessNewest ? "Recent ↓" : documentsSortMode == .accessOldest ? "Recent ↑" : "Recent"
                    Label(nameText, systemImage: "textformat").tag("name")
                    Label(dateText, systemImage: "calendar").tag("date")
                    Label(recentText, systemImage: "clock").tag("recent")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.primary)
            }
        }
    }

    private var documentsBaseContent: some View {
        Group {
            if documentManager.documents.isEmpty && !isProcessing {
                emptyStateView
            } else {
                rootBrowserView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationDestination(item: $activeFolderForRoot) { folder in
            FolderDocumentsView(
                folder: folder,
                onOpenDocument: openDocumentPreview,
                onSelectionModeChange: { isActive in
                    isFolderSelectionModeActive = isActive
                }
            )
            .environmentObject(documentManager)
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.large)
    }
    
    @ViewBuilder
    private var documentsCoreContent: some View {
        if isSelectionMode {
            documentsBaseContent
                .toolbar { documentsSelectionToolbar }
        } else {
            documentsBaseContent
                .toolbar { documentsNormalToolbar }
        }
    }

    var body: some View {
        withDocumentPresentations
    }

    private var coreStack: some View {
        documentsCoreContent
            .tabBarVisibility(shouldHideTabBar)
            .tabBarHiddenCompat(shouldHideTabBar)
            .bindGlobalOperationLoading(isProcessing || isOpeningPreview)
    }

    private var withFolderPresentations: some View {
        coreStack
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SettingsSheetBackgroundModifier())
            }
            .sheet(isPresented: $showingSmartViews) {
                SmartViewsListView(
                    onOpenPreview: { doc, url in
                        showingSmartViews = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenPreview(doc, url) }
                    },
                    onShowSummary: { doc in
                        showingSmartViews = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onShowSummary(doc) }
                    }
                )
                .environmentObject(documentManager)
            }
            .onChange(of: isSelectionMode) { _, active in
                editMode = active ? .active : .inactive
            }
            .onChange(of: activeFolderForRoot) { _, folder in
                if folder == nil { isFolderSelectionModeActive = false }
            }
            .alert("New Folder", isPresented: $showingNewFolderDialog) {
                TextField("Folder name", text: $newFolderName)
                TextField("Topic (optional)", text: $newFolderDescription)
                Button("Create") {
                    let desc = newFolderDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    documentManager.createFolder(name: newFolderName, description: desc.isEmpty ? nil : desc)
                    newFolderDescription = ""
                }
                Button("Cancel", role: .cancel) { newFolderDescription = "" }
            } message: { Text("Enter a name for the folder") }
            .alert("Rename Folder", isPresented: $showingRenameFolderDialog) {
                TextField("Folder name", text: $renameFolderText)
                Button("Rename") {
                    guard let folder = folderToRename else { return }
                    documentManager.renameFolder(folderId: folder.id, to: renameFolderText)
                    folderToRename = nil
                }
                Button("Cancel", role: .cancel) { folderToRename = nil }
            } message: { Text("Enter a new name for the folder") }
            .confirmationDialog("Delete Folder", isPresented: $showingDeleteFolderDialog, presenting: folderToDelete) { folder in
                Button("Delete all items", role: .destructive) {
                    documentManager.deleteFolder(folderId: folder.id, mode: .deleteAllItems)
                    folderToDelete = nil
                }
                let parentName = documentManager.folderName(for: folder.parentId) ?? "On My iPhone"
                Button("Move items to \"\(parentName)\"", role: .destructive) {
                    documentManager.deleteFolder(folderId: folder.id, mode: .moveItemsToParent)
                    folderToDelete = nil
                }
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: { folder in Text("Choose what to do with items inside \"\(folder.name)\".") }
            .confirmationDialog("Delete Selected Items", isPresented: $showingBulkDeleteDialog) {
                Button("Delete", role: .destructive) { deleteSelectedItems() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This will delete all selected items and their contents.") }
            .sheet(isPresented: $showingBulkMoveSheet) {
                BulkMoveSheet(
                    folders: documentManager.folders,
                    currentParentId: nil,
                    onSelectParent: { parentId in
                        moveSelectedItems(to: parentId)
                        showingBulkMoveSheet = false
                    },
                    onCancel: { showingBulkMoveSheet = false }
                )
            }
            .sheet(isPresented: $showingMoveFolderSheet) {
                if let folder = folderToMove {
                    let invalid = documentManager.descendantFolderIds(of: folder.id).union([folder.id])
                    MoveFolderSheet(
                        folder: folder,
                        folders: documentManager.folders.filter { !invalid.contains($0.id) },
                        currentParentId: folder.parentId,
                        onSelectParent: { parentId in
                            documentManager.moveFolder(folderId: folder.id, toParent: parentId)
                            folderToMove = nil
                            showingMoveFolderSheet = false
                        },
                        onCancel: { folderToMove = nil; showingMoveFolderSheet = false }
                    )
                }
            }
            .sheet(item: $documentToMove) { doc in
                MoveToFolderSheet(
                    document: doc,
                    folders: documentManager.folders(in: nil),
                    currentFolderId: doc.folderId,
                    allFolders: documentManager.folders,
                    currentContainerName: "Documents",
                    allowRootSelection: true,
                    onSelectFolder: { folderId in
                        documentManager.moveDocument(documentId: doc.id, toFolder: folderId)
                        documentToMove = nil
                    },
                    onCancel: { documentToMove = nil }
                )
            }
    }

    private var withDocumentPresentations: some View {
        withFolderPresentations
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker { urls in processImportedFiles(urls) }
            }
            .sheet(isPresented: $showingZipExportSheet) {
                ZipExportView(
                    preselectedDocumentIds: selectedDocumentIds,
                    preselectedFolderIds: selectedFolderIds
                )
                .environmentObject(documentManager)
            }
            .alert("ZIP Name", isPresented: $showingQuickZipNamePrompt) {
                TextField("Archive name", text: $quickZipName)
                Button("Create") {
                    let trimmed = quickZipName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        quickZipAlertMessage = "Please enter a name."
                        showingQuickZipAlert = true
                    } else {
                        createQuickZip(named: trimmed, targetFolderId: nil)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Enter a name for the ZIP file.") }
            .alert("Create Zip", isPresented: $showingQuickZipAlert) {
                Button("OK", role: .cancel) {}
            } message: { Text(quickZipAlertMessage) }
            .onAppear { documentManager.objectWillChange.send() }
            .fullScreenCover(isPresented: $showingScanner) {
                if scannerMode == .document, VNDocumentCameraViewController.isSupported {
                    DocumentScannerView { images in
                        self.scannedImages = images
                        self.prepareNamingDialog(for: images)
                    }
                    .ignoresSafeArea()
                } else {
                    SimpleCameraView { text in processScannedText(text) }
                        .ignoresSafeArea()
                }
            }
            .alert("Camera Access Needed", isPresented: $showingCameraPermissionAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Allow camera access to scan documents.") }
            .alert("Name Document", isPresented: $showingNamingDialog) {
                TextField("Document name", text: $customName)
                Button("Use Suggested") { finalizePendingDocument(with: suggestedName) }
                Button("Use Custom") {
                    finalizePendingDocument(with: customName.isEmpty ? suggestedName : customName)
                }
                Button("Cancel", role: .cancel) {
                    scannedImages.removeAll()
                    extractedText = ""
                    suggestedName = ""
                    customName = ""
                    pendingCategory = .general
                    pendingKeywordsResume = ""
                    pendingOCRPages = []
                    isProcessing = false
                }
            } message: {
                Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
            }
            .alert("Rename Document", isPresented: $showingRenameDialog) {
                TextField("Document name", text: $renameText)
                Button("Rename") {
                    guard let document = documentToRename else { return }
                    let typed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !typed.isEmpty else { return }

                    if let idx = documentManager.documents.firstIndex(where: { $0.id == document.id }) {
                        let old = documentManager.documents[idx]
                        let oldParts = splitDisplayTitle(old.title)
                        let typedURL = URL(fileURLWithPath: typed)
                        let typedExt = typedURL.pathExtension.lowercased()
                        let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
                        let sanitizedBase = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : typed
                        let newTitle = oldParts.ext.isEmpty ? sanitizedBase : "\(sanitizedBase).\(oldParts.ext)"
                        let updated = Document(
                            id: old.id,
                            title: newTitle,
                        content: old.content,
                        summary: old.summary,
                        ocrPages: old.ocrPages,
                        category: old.category,
                        keywordsResume: old.keywordsResume,
                        tags: old.tags,
                        sourceDocumentId: old.sourceDocumentId,
                        dateCreated: old.dateCreated,
                        folderId: old.folderId,
                        sortOrder: old.sortOrder,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData,
                        sensitiveFlags: old.sensitiveFlags
                    )
                    documentManager.documents[idx] = updated

                    // Persist via an existing public save-triggering method.
                    documentManager.updateSummary(for: updated.id, to: updated.summary)
                }

                documentToRename = nil
            }
            
            Button("Cancel", role: .cancel) {
                documentToRename = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for the document")
        }
        .sheet(isPresented: $showingNameSearch) {
            DocumentNameSearchSheet(
                query: $nameSearchText,
                documents: documentManager.documents,
                onSelect: { doc in
                    showingNameSearch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        openDocumentPreview(document: doc)
                    }
                },
                onClose: {
                    showingNameSearch = false
                }
            )
        }
        .sheet(item: $protectedUnlockTarget) { document in
            ProtectedPDFUnlockSheet(
                documentTitle: document.title,
                password: $protectedUnlockPassword,
                errorMessage: protectedUnlockError,
                isUnlocking: isOpeningPreview,
                onCancel: {
                    protectedUnlockTarget = nil
                    protectedUnlockPassword = ""
                    protectedUnlockError = ""
                },
                onUnlock: {
                    openProtectedDocumentPreview(document: document)
                }
            )
        }
        .sheet(item: $importBatchResult) { batch in
            ImportReviewView(result: batch)
                .environmentObject(documentManager)
        }
    }



    // Menu actions
    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = splitDisplayTitle(document.title).base
        showingRenameDialog = true
    }

    private func beginSelection(documentId: UUID? = nil, folderId: UUID? = nil) {
        if !isSelectionMode {
            isSelectionMode = true
            editMode = .active
        }
        if let documentId {
            toggleDocumentSelection(documentId)
        }
        if let folderId {
            toggleFolderSelection(folderId)
        }
    }

    private func toggleDocumentSelection(_ id: UUID) {
        if selectedDocumentIds.contains(id) {
            selectedDocumentIds.remove(id)
        } else {
            selectedDocumentIds.insert(id)
        }
    }

    private func toggleFolderSelection(_ id: UUID) {
        if selectedFolderIds.contains(id) {
            selectedFolderIds.remove(id)
        } else {
            selectedFolderIds.insert(id)
        }
    }

    private func clearSelection() {
        isSelectionMode = false
        selectedDocumentIds.removeAll()
        selectedFolderIds.removeAll()
    }

    private func processImportedFiles(_ urls: [URL]) {
        isProcessing = true
        let folderId = activeFolderForRoot?.id

        Task.detached(priority: .userInitiated) {
            var processedDocuments: [Document] = []

            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                if let document = await self.documentManager.processFile(at: url) {
                    processedDocuments.append(document)
                }
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            await MainActor.run {
                for document in processedDocuments {
                    let withFolder = Document(
                        id: document.id,
                        title: document.title,
                        content: document.content,
                        summary: document.summary,
                        ocrPages: document.ocrPages,
                        category: document.category,
                        keywordsResume: document.keywordsResume,
                        tags: document.tags,
                        sourceDocumentId: document.sourceDocumentId,
                        dateCreated: document.dateCreated,
                        folderId: folderId,
                        sortOrder: document.sortOrder,
                        type: document.type,
                        imageData: document.imageData,
                        pdfData: document.pdfData,
                        originalFileData: document.originalFileData,
                        sensitiveFlags: document.sensitiveFlags
                    )

                    self.documentManager.addDocument(withFolder)

                    let fullTextForKeywords = withFolder.content
                    DispatchQueue.global(qos: .utility).async {
                        let cat = DocumentManager.inferCategory(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)
                        let kw = DocumentManager.makeKeywordsResume(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)

                        DispatchQueue.main.async {
                            let current = self.documentManager.getDocument(by: withFolder.id) ?? withFolder
                            let updated = Document(
                                id: current.id,
                                title: current.title,
                                content: current.content,
                                summary: current.summary,
                                ocrPages: current.ocrPages,
                                category: cat,
                                keywordsResume: kw,
                                tags: current.tags,
                                sourceDocumentId: current.sourceDocumentId,
                                dateCreated: current.dateCreated,
                                folderId: current.folderId ?? folderId,
                                sortOrder: current.sortOrder,
                                type: current.type,
                                imageData: current.imageData,
                                pdfData: current.pdfData,
                                originalFileData: current.originalFileData,
                                sensitiveFlags: current.sensitiveFlags
                            )
                            if let idx = self.documentManager.documents.firstIndex(where: { $0.id == current.id }) {
                                self.documentManager.documents[idx] = updated
                            }
                        }
                    }
                }

                self.isProcessing = false
                if !processedDocuments.isEmpty {
                    self.importBatchResult = ImportBatchResult(documentIds: processedDocuments.map(\.id), importedAt: Date())
                }
            }
        }
    }

    private func finalizePendingDocument(with name: String) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = finalName.isEmpty ? suggestedName : finalName
        finalizeDocument(with: safeName)
    }

    private func startScan() {
        func presentScanner() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showingScanner = true
            }
        }
        if !VNDocumentCameraViewController.isSupported {
            scannerMode = .simple
            presentScanner()
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            scannerMode = .document
            presentScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        scannerMode = .document
                        presentScanner()
                    } else {
                        showingCameraPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingCameraPermissionAlert = true
        @unknown default:
            showingCameraPermissionAlert = true
        }
    }

    private func processScannedText(_ text: String) {
        isProcessing = true

        let cappedText = FileProcessingService.truncateText(text, maxChars: 50000)
        let document = Document(
            title: normalizedScannedTitle(titleCaseFromOCR(cappedText)),
            content: cappedText,
            summary: "Processing summary...",
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: activeFolderForRoot?.id,
            type: .scanned,
            imageData: nil,
            pdfData: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }

    private func prepareNamingDialog(for images: [UIImage]) {
        guard let firstImage = images.first else { return }

        isProcessing = true

        let firstPage = performOCRDetailed(on: firstImage, pageIndex: 0)
        let firstPageText = firstPage.text

        var ocrPages: [OCRPage] = []
        for (index, image) in images.enumerated() {
            let page = performOCRDetailed(on: image, pageIndex: index)
            ocrPages.append(page.page)
        }
        extractedText = buildStructuredText(from: ocrPages, includePageLabels: true)
        pendingOCRPages = ocrPages

        let fullTextForKeywords = extractedText
        DispatchQueue.global(qos: .utility).async {
            let cat = DocumentManager.inferCategory(title: "", content: fullTextForKeywords, summary: "")
            let kw = DocumentManager.makeKeywordsResume(title: "", content: fullTextForKeywords, summary: "")
            DispatchQueue.main.async {
                self.pendingCategory = cat
                self.pendingKeywordsResume = kw
            }
        }

        let namingSeed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? firstPageText : extractedText

        if !namingSeed.isEmpty {
            generateAIDocumentName(from: namingSeed)
        } else {
            suggestedName = titleCaseFromOCR(firstPageText)
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }

    private func titleCaseFromOCR(_ text: String) -> String {
        let snippet = String(text.prefix(300))
        return enforceTitleCase(snippet)
    }

    private func enforceTitleCase(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let words = normalized.split(separator: " ").map(String.init)
        let acronymWords: Set<String> = ["ai", "ocr", "pdf", "docx", "ppt", "pptx", "xls", "xlsx", "jpg", "jpeg", "png"]
        let cased = words.map { word -> String in
            guard !word.isEmpty else { return "" }
            let lowered = word.lowercased()
            let plain = lowered.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            if acronymWords.contains(plain) { return word.uppercased() }
            if word == word.uppercased(), word.count <= 4 { return word }

            var result = ""
            var didCapitalizeLetter = false
            for scalar in word.unicodeScalars {
                let char = Character(scalar)
                if CharacterSet.letters.contains(scalar) {
                    if didCapitalizeLetter {
                        result.append(String(char).lowercased())
                    } else {
                        result.append(String(char).uppercased())
                        didCapitalizeLetter = true
                    }
                } else {
                    result.append(char)
                }
            }
            return result
        }
        return cased.joined(separator: " ")
    }

    private func compactPascalCaseTitle(_ value: String, maxWords: Int) -> String {
        let expanded = value
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { return "" }

        let acronymWords: Set<String> = ["ai", "ocr", "pdf", "docx", "ppt", "pptx", "xls", "xlsx", "jpg", "jpeg", "png", "heic", "csv"]
        return expanded
            .split { $0.isWhitespace }
            .prefix(maxWords)
            .map { token in
                let raw = String(token)
                let lowered = raw.lowercased()
                if acronymWords.contains(lowered) {
                    return lowered.uppercased()
                }
                let first = raw.prefix(1).uppercased()
                let rest = raw.dropFirst().lowercased()
                return first + rest
            }
            .joined()
    }

    private func normalizedScannedTitle(_ raw: String) -> String {
        let trimmed = raw
            .replacingOccurrences(of: "^(?i)\\s*(suggested\\s+)?(document\\s+)?title\\s*[:\\-]\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\btitle\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "Scanned Document"
        guard !trimmed.isEmpty else { return "ScannedDocument.pdf" }

        let typedURL = URL(fileURLWithPath: trimmed)
        let typedExt = typedURL.pathExtension.lowercased()
        let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
        let base = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : trimmed

        let cleanedBase = base
            .replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        let safeBaseRaw = cleanedBase.isEmpty ? fallback : cleanedBase
        let safeBase = compactPascalCaseTitle(
            safeBaseRaw
            .replacingOccurrences(of: "(?i)\\btitle\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            maxWords: 10
        )
        let finalBase = safeBase.isEmpty ? "ScannedDocument" : safeBase
        return "\(finalBase).pdf"
    }

    private func finalizeDocument(with name: String) {
        guard !scannedImages.isEmpty else { return }

        isProcessing = true

        var imageDataArray: [Data] = []
        for image in scannedImages {
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }

        let pdfData = createPDF(from: scannedImages)
        let cappedText = FileProcessingService.truncateText(extractedText, maxChars: 50000)
        let cappedPages: [OCRPage]? = {
            if pendingOCRPages.isEmpty { return nil }
            return [OCRPage(pageIndex: 0, blocks: [OCRBlock(text: cappedText, confidence: 1.0, bbox: OCRBoundingBox(x: 0.0, y: 0.0, width: 1.0, height: 1.0), order: 0)])]
        }()
        let pagesToStore = pendingOCRPages.isEmpty ? cappedPages : pendingOCRPages

        let document = Document(
            title: normalizedScannedTitle(name),
            content: cappedText,
            summary: "Processing summary...",
            ocrPages: pagesToStore,
            category: pendingCategory,
            keywordsResume: pendingKeywordsResume,
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: activeFolderForRoot?.id,
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            documentManager.addDocument(document)
            isProcessing = false

            scannedImages.removeAll()
            extractedText = ""
            suggestedName = ""
            customName = ""
            pendingCategory = .general
            pendingKeywordsResume = ""
            pendingOCRPages = []
        }
    }

    private func createPDF(from images: [UIImage]) -> Data? {
        let pdfData = NSMutableData()

        guard let dataConsumer = CGDataConsumer(data: pdfData) else { return nil }
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var mediaBox = pageRect

        guard let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }

        for image in images {
            pdfContext.beginPDFPage(nil)
            let imageSize = image.size
            let scale = min(pageWidth / imageSize.width, pageHeight / imageSize.height)
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            let x = (pageWidth - width) / 2
            let y = (pageHeight - height) / 2
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if let cgImage = image.cgImage {
                pdfContext.draw(cgImage, in: rect)
            }
            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfData as Data
    }

    private func performOCRDetailed(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            return ("Could not process image", OCRPage(pageIndex: pageIndex, blocks: []))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        var recognizedText = ""
        var blocks: [OCRBlock] = []

        do {
            try handler.perform([request])
            if let results = request.results as? [VNRecognizedTextObservation] {
                for (idx, observation) in results.enumerated() {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let bbox = observation.boundingBox
                    let bounding = OCRBoundingBox(x: bbox.origin.x, y: bbox.origin.y, width: bbox.size.width, height: bbox.size.height)
                    blocks.append(OCRBlock(text: candidate.string, confidence: Double(candidate.confidence), bbox: bounding, order: idx))
                    recognizedText += candidate.string + "\n"
                }
            }
        } catch {
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }

        let page = OCRPage(pageIndex: pageIndex, blocks: blocks)
        return (recognizedText, page)
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        var output: [String] = []
        for page in pages {
            if includePageLabels {
                output.append("Page \(page.pageIndex + 1):")
            }
            let sorted = page.blocks.sorted { $0.order < $1.order }
            for block in sorted {
                let line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    output.append(line)
                }
            }
            output.append("")
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        let targetSize: CGFloat = 2560
        let scale = min(targetSize / max(image.size.width, 1), targetSize / max(image.size.height, 1))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: newSize))
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func mixedRootItems() -> [MixedItem] {
        let folderItems = rootFolders.map { folder in
            MixedItem(id: folder.id, kind: .folder(folder), name: folder.name, dateCreated: folder.dateCreated)
        }
        let documentItems = rootDocs.map { doc in
            MixedItem(id: doc.id, kind: .document(doc), name: splitDisplayTitle(doc.title).base, dateCreated: doc.dateCreated)
        }
        return sortMixedItems(folderItems + documentItems)
    }

    private func sortMixedItems(_ items: [MixedItem]) -> [MixedItem] {
        switch documentsSortMode {
        case .dateNewest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .dateOldest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated < $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameAsc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.dateCreated > $1.dateCreated
            }
        case .nameDesc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedDescending }
                return $0.dateCreated > $1.dateCreated
            }
        case .accessNewest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .accessOldest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func deleteSelectedItems() {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            if let doc = documentManager.documents.first(where: { $0.id == id }) {
                documentManager.deleteDocument(doc)
            }
        }

        for folderId in folderIds {
            documentManager.deleteFolder(folderId: folderId, mode: .deleteAllItems)
        }

        clearSelection()
    }

    private func moveSelectedItems(to parentId: UUID?) {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            documentManager.moveDocument(documentId: id, toFolder: parentId)
        }

        for folderId in folderIds {
            documentManager.moveFolder(folderId: folderId, toParent: parentId)
        }

        clearSelection()
    }

    private func createQuickZip(named name: String, targetFolderId: UUID?) {
        isProcessing = true
        let selectedDocIds = selectedDocumentIds
        let selectedFldIds = selectedFolderIds

        let workItem = DispatchWorkItem {
            let selectedDocs = documentsForZipExport(
                documentManager: documentManager,
                selectedDocumentIds: selectedDocIds,
                selectedFolderIds: selectedFldIds
            )
            guard !selectedDocs.isEmpty else {
                DispatchQueue.main.async {
                    isProcessing = false
                    quickZipAlertMessage = "No documents found to zip."
                    showingQuickZipAlert = true
                }
                return
            }

            let tempDir = FileManager.default.temporaryDirectory
            let stagingURL = tempDir.appendingPathComponent("zip_export_\(UUID().uuidString)", isDirectory: true)
            let safeName = zipSanitizedFileName(name)
            let fileName = safeName.isEmpty ? "Insight_Archive_\(zipShortDateString()).zip" : "\(safeName).zip"
            let zipURL = tempDir.appendingPathComponent(fileName)

            defer {
                do {
                    try FileManager.default.removeItem(at: stagingURL)
                } catch {
                    AppLogger.ui.warning("Failed to remove staging directory: \(error.localizedDescription)")
                }
                do {
                    try FileManager.default.removeItem(at: zipURL)
                } catch {
                    AppLogger.ui.warning("Failed to remove temporary zip file: \(error.localizedDescription)")
                }
            }

            do {
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

                for doc in selectedDocs {
                    let relativePath = zipRelativePathForDocument(doc, folders: documentManager.folders)
                    let fileURL = stagingURL.appendingPathComponent(relativePath)
                    let folderURL = fileURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                    if let data = zipDataForDocument(doc, documentManager: documentManager) {
                        try data.write(to: fileURL, options: [.atomic])
                    }
                }

                let ok = SSZipArchive.createZipFile(atPath: zipURL.path, withContentsOfDirectory: stagingURL.path)
                let zipData: Data
                do {
                    guard ok else { throw NSError(domain: "ZipExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "SSZipArchive failed"]) }
                    zipData = try Data(contentsOf: zipURL)
                } catch {
                    AppLogger.ui.error("Failed to read zip archive data: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        isProcessing = false
                        quickZipAlertMessage = "Failed to create ZIP archive."
                        showingQuickZipAlert = true
                    }
                    return
                }

                let zipDoc = makeZipExportDocument(title: fileName, data: zipData, folderId: targetFolderId)
                DispatchQueue.main.async {
                    documentManager.addDocument(zipDoc)
                    isProcessing = false
                    clearSelection()
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    quickZipAlertMessage = "ZIP creation failed: \(error.localizedDescription)"
                    showingQuickZipAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func deleteDocument(_ document: Document) {
        documentManager.deleteDocument(document)
    }
    
    private func convertDocument(_ document: Document) {
        // Navigate to conversion view with pre-selected document
        // This will be handled by the dedicated Convert tab
        AppLogger.ui.debug("Convert document: \(document.title)")
        // Note: Users should use the Convert tab for full conversion functionality
    }

    private func generateAIDocumentName(from text: String) {
        let base = extractHeadingsAndFirstParagraph(from: text)
        let seed = base.isEmpty ? text : base
        let candidates = extractTitleCandidates(from: seed)
        let fallbackRaw = compactPascalCaseTitle(candidates.first ?? titleCaseFromOCR(text), maxWords: 4)
        let fallback = fallbackRaw.isEmpty ? "ScannedDocument" : fallbackRaw
        let contentSnippet = String(seed.prefix(300))

        let prompt = """
            Generate a short, descriptive title (2-5 words) for this document. \
            The title should capture what the document is specifically about — be specific and descriptive. \
            Output only the title in Title Case.

            HINTS:
            \(candidates.map { "- \($0)" }.joined(separator: "\n"))

            CONTENT:
            \(contentSnippet)
            """

        AppLogger.ui.debug("Generating AI document name from OCR text")
        // Ensure the JS bridge routes this as a naming request with no chat history.
        EdgeAI.shared?.generate("<<<NO_HISTORY>>><<<NAME_REQUEST>>>" + prompt, resolver: { result in
            AppLogger.ui.debug("Got name suggestion result: \(String(describing: result))")
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = normalizeSuggestedTitle(clean, fallback: fallback)
                    self.suggestedName = normalized.isEmpty ? fallback : normalized
                } else {
                    self.suggestedName = fallback
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
            AppLogger.ui.error("Name generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.suggestedName = fallback
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        })
    }

    private func extractTitleCandidates(from text: String) -> [String] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var scored: [(String, Double)] = []
        for (idx, line) in lines.enumerated() {
            if isMetadataLine(line) { continue }
            let score = scoreTitleLine(line, index: idx)
            if score > 0 {
                scored.append((line, score))
            }
        }

        let top = scored
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { normalizeTitleCandidate($0.0, maxWords: 16) }
            .filter { !$0.isEmpty }

        return top.isEmpty ? [normalizeTitleCandidate(text, maxWords: 8)] : top
    }

    private func isMetadataLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let denylist = [
            "abstract", "keywords", "references", "acknowledg", "copyright",
            "doi", "issn", "isbn", "volume", "vol.", "issue", "no.", "page",
            "journal", "proceedings", "conference", "university", "department",
            "faculty", "publisher", "press", "editor", "address", "telephone", "phone", "fax"
        ]
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") { return true }
        if lower.range(of: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if lower.range(of: "\\bdoi\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bissn\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bpage\\s+\\d+\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bvol\\.?\\s*\\d+", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bissue\\s*\\d+", options: .regularExpression) != nil { return true }
        if denylist.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    private func scoreTitleLine(_ line: String, index: Int) -> Double {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 4 { return -1 }
        if trimmed.count > 120 { return -1 }

        let words = trimmed.split { $0.isWhitespace }
        let wordCount = words.count
        let letters = trimmed.filter { $0.isLetter }.count
        let digits = trimmed.filter { $0.isNumber }.count
        let total = max(1, trimmed.count)

        var score: Double = 0
        score += Double(max(0, 5 - index)) * 0.35 // top-of-page boost
        if wordCount >= 4 && wordCount <= 16 { score += 2.0 }
        if wordCount <= 2 { score -= 1.5 }
        if wordCount > 20 { score -= 1.0 }

        let letterRatio = Double(letters) / Double(total)
        let digitRatio = Double(digits) / Double(total)
        if letterRatio >= 0.7 { score += 1.0 }
        if letterRatio < 0.4 { score -= 1.0 }
        if digitRatio > 0.3 { score -= 1.5 }

        let isAllCaps = trimmed == trimmed.uppercased() && letterRatio > 0.5
        let isTitleCase = words.allSatisfy { word in
            guard let first = word.first else { return false }
            return String(first) == String(first).uppercased()
        }
        if isTitleCase { score += 0.8 }
        if isAllCaps { score += 0.5 }

        return score
    }

    private func normalizeTitleCandidate(_ input: String, maxWords: Int) -> String {
        let firstLine = input.components(separatedBy: .newlines).first ?? ""
        let stripped = firstLine
            .replacingOccurrences(of: "^[\\s•\\-–—*]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\"'“”`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9\\s&\\-\\/]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }
        return stripped.split(separator: " ").prefix(maxWords).joined(separator: " ")
    }

    private func normalizeSuggestedTitle(_ raw: String, fallback: String) -> String {
        func compactAndCap(_ value: String) -> String {
            compactPascalCaseTitle(
                value
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: ":", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                maxWords: 4
            )
        }

        let normalizedFallback = compactAndCap(fallback)
        let extractedFromQuotedTitle: String = {
            let fullRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let regex = try? NSRegularExpression(pattern: #"(?i)title\s*:\s*"([^"]+)""#),
                  let match = regex.firstMatch(in: raw, options: [], range: fullRange),
                  match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: raw) else {
                return raw
            }
            return String(raw[groupRange])
        }()

        let stripped = extractedFromQuotedTitle
            .replacingOccurrences(of: "^(?i)\\s*(suggested\\s+)?(document\\s+)?title\\s*[:\\-]\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if stripped.isEmpty {
            return normalizedFallback
        }
        let cleaned = stripped
            .replacingOccurrences(of: "(?i)\\btitle\\b", with: "", options: .regularExpression)
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return normalizedFallback
        }
        if isMetadataLine(cleaned) {
            return normalizedFallback
        }
        let words = cleaned.split { $0.isWhitespace }
        if words.count > 14 || cleaned.count > 90 {
            return normalizedFallback
        }

        let normalized = compactAndCap(cleaned)
        return normalized.isEmpty ? normalizedFallback : normalized
    }

    private func buildNamingSeed(from pages: [OCRPage], fallback: String) -> String {
        let structured = buildStructuredText(from: pages, includePageLabels: false)
        let source = structured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : structured
        let prefix = extractHeadingsAndFirstParagraph(from: source)
        return String((prefix.isEmpty ? source : prefix).prefix(800))
    }

    private func extractHeadingsAndFirstParagraph(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let paragraphs = trimmed
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else { return trimmed }
        if paragraphs.count == 1 { return paragraphs[0] }
        return paragraphs[0] + "\n\n" + paragraphs[1]
    }
    
    private func openDocumentPreview(document: Document) {
        documentManager.updateLastAccessed(id: document.id)
        if isProtectedPDFPreview(document, documentManager: documentManager) {
            protectedUnlockError = ""
            protectedUnlockPassword = ""
            protectedUnlockTarget = document
            return
        }
        openDocumentPreview(document: document, password: nil)
    }

    private func openProtectedDocumentPreview(document: Document) {
        let password = protectedUnlockPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            protectedUnlockError = "Password is required."
            return
        }
        protectedUnlockError = ""
        openDocumentPreview(document: document, password: password)
    }

    private func openDocumentPreview(document: Document, password: String?) {
        isOpeningPreview = true
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExt = getFileExtension(for: document.type)
        let tempURL = tempDirectory.appendingPathComponent("preview_\(document.id).\(fileExt)")
        
        func present(url: URL) {
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.protectedUnlockTarget = nil
                    self.protectedUnlockPassword = ""
                    self.protectedUnlockError = ""
                    self.onOpenPreview(document, url)
                    self.isOpeningPreview = false
                }
            }
        }
        
        // Prefer original file, then PDF, then first image fallback
        if let data = documentManager.anyFileData(for: document.id) {
            do {
                if isProtectedPDFPreview(document, documentManager: documentManager) {
                    guard let pdf = PDFDocument(data: data), pdf.isEncrypted else {
                        throw NSError(domain: "ProtectedPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read encrypted PDF."])
                    }
                    guard let password, pdf.unlock(withPassword: password) else {
                        throw NSError(domain: "ProtectedPreview", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incorrect password."])
                    }
                    guard let decryptedData = pdf.dataRepresentation() else {
                        throw NSError(domain: "ProtectedPreview", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to decrypt PDF."])
                    }
                    try decryptedData.write(to: tempURL)
                } else {
                    try data.write(to: tempURL)
                }
                present(url: tempURL)
            } catch {
                AppLogger.ui.error("Error creating temp file: \(error.localizedDescription)")
                if isProtectedPDFPreview(document, documentManager: documentManager) {
                    protectedUnlockError = "Wrong password. Try again."
                }
                isOpeningPreview = false
            }
        } else {
            // Fallback: show content in a simple text preview via summary sheet
            self.isOpeningPreview = false
            self.onShowSummary(document)
            isOpeningPreview = false
        }
    }
    
    private func getFileExtension(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf:
            return "pdf"
        case .docx:
            return "docx"
        case .ppt:
            return "ppt"
        case .pptx:
            return "pptx"
        case .xls:
            return "xls"
        case .xlsx:
            return "xlsx"
        case .text:
            return "txt"
        case .scanned:
            return "pdf"
        case .image:
            return "jpg"
        case .zip:
            return "zip"
        }
    }

    private func shareSelectedDocuments() {
        let docs = documentManager.documents.filter { selectedDocumentIds.contains($0.id) }
        shareDocuments(docs)
    }

    private func shareDocuments(_ documents: [Document]) {
        let urls = documents.compactMap { makeShareURL(for: $0) }
        guard !urls.isEmpty else { return }
        presentShare(urls: urls)
    }

    private func makeShareURL(for document: Document) -> URL? {
        let parts = splitDisplayTitle(document.title)
        let safeBase = parts.base.replacingOccurrences(of: "/", with: "-")
        let base = safeBase.isEmpty ? "Document" : safeBase
        let ext = parts.ext.isEmpty ? getFileExtension(for: document.type) : parts.ext
        let filename = parts.ext.isEmpty ? "\(base).\(ext)" : "\(base).\(parts.ext)"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        if let data = documentManager.anyFileData(for: document.id) {
            do {
                try data.write(to: tempURL)
            } catch {
                AppLogger.ui.error("Failed to write share file data: \(error.localizedDescription)")
                return nil
            }
            return tempURL
        }

        if !document.content.isEmpty, let data = document.content.data(using: .utf8) {
            do {
                try data.write(to: tempURL)
            } catch {
                AppLogger.ui.error("Failed to write share content data: \(error.localizedDescription)")
                return nil
            }
            return tempURL
        }

        return nil
    }

    private func presentShare(urls: [URL]) {
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activity, animated: true)
    }
}
