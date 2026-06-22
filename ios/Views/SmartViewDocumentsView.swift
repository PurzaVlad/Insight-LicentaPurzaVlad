import SwiftUI
import VisionKit
import AVFoundation

// MARK: - SmartViewDocumentsView

struct SmartViewDocumentsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let title: String
    let filter: SmartView?
    let onOpenDocument: (Document) -> Void

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

    private var allDocs: [Document] {
        let base = filter == nil
            ? documentManager.documents
            : documentManager.documents.filter { filter!.matches($0) }
        return base.sorted(using: documentsSortMode)
    }

    // Delete state
    @State private var documentToDelete: Document?
    @State private var showingDeleteConfirm = false

    // Selection state
    @State private var isSelectionMode = false
    @State private var selectedDocumentIds: Set<UUID> = []
    private var hasSelection: Bool { !selectedDocumentIds.isEmpty }
    private var isAllSelected: Bool {
        !allDocs.isEmpty && allDocs.allSatisfy { selectedDocumentIds.contains($0.id) }
    }

    // Import state
    @State private var showingDocumentPicker = false
    @State private var isProcessing = false
    @State private var importBatchResult: ImportBatchResult?

    // Scan state
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText: String = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""

    // Zip / Settings
    @State private var showingZipExportSheet = false
    @State private var showingSettings = false

    var body: some View {
        Group {
            if allDocs.isEmpty && !isProcessing {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No documents")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            } else if documentManager.prefersGridLayout {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(allDocs) { document in
                            DocumentGridItemView(
                                document: document,
                                isSelected: selectedDocumentIds.contains(document.id),
                                isSelectionMode: isSelectionMode,
                                onSelectToggle: { toggleSelection(document.id) },
                                onOpen: { onOpenDocument(document) },
                                onRename: {},
                                onMoveToFolder: {},
                                onDelete: {
                                    documentToDelete = document
                                    showingDeleteConfirm = true
                                },
                                onShare: { shareDocument(document) },
                                onLongPress: {
                                    if !isSelectionMode { isSelectionMode = true }
                                    toggleSelection(document.id)
                                }
                            )
                            .environmentObject(documentManager)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            } else if isSelectionMode {
                List(selection: $selectedDocumentIds) {
                    ForEach(allDocs) { document in
                        DocumentRowView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: true,
                            usesNativeSelection: true,
                            onSelectToggle: { toggleSelection(document.id) },
                            showsMoveToFolder: false,
                            onOpen: { onOpenDocument(document) },
                            onRename: {},
                            onMoveToFolder: {},
                            onDelete: {
                                documentToDelete = document
                                showingDeleteConfirm = true
                            },
                            onShare: { shareDocument(document) }
                        )
                        .tag(document.id)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                    }
                }
                .environment(\.editMode, .constant(.active))
                .listStyle(.plain)
                .hideScrollBackground()
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allDocs) { document in
                            DocumentRowView(
                                document: document,
                                isSelected: selectedDocumentIds.contains(document.id),
                                isSelectionMode: false,
                                usesNativeSelection: false,
                                onSelectToggle: { toggleSelection(document.id) },
                                showsMoveToFolder: false,
                                onOpen: { onOpenDocument(document) },
                                onRename: {},
                                onMoveToFolder: {},
                                onDelete: {
                                    documentToDelete = document
                                    showingDeleteConfirm = true
                                },
                                onShare: { shareDocument(document) }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
        }
        .toolbar(isSelectionMode ? .hidden : .visible, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { docViewToolbar }
        .navigationBarBackButtonHidden(isSelectionMode)
        .bindGlobalOperationLoading(isProcessing)
        .confirmationDialog("Delete Document", isPresented: $showingDeleteConfirm, presenting: documentToDelete) { doc in
            Button("Delete", role: .destructive) {
                documentManager.deleteDocument(doc)
                documentToDelete = nil
            }
            Button("Cancel", role: .cancel) { documentToDelete = nil }
        } message: { doc in
            Text("Delete \"\(splitDisplayTitle(doc.title).base)\"? This cannot be undone.")
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in processImportedFiles(urls) }
        }
        .sheet(item: $importBatchResult) { batch in
            ImportReviewView(result: batch)
                .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingZipExportSheet) {
            ZipExportView(
                preselectedDocumentIds: hasSelection ? selectedDocumentIds : Set(allDocs.map(\.id))
            )
            .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .modifier(SettingsSheetBackgroundModifier())
        }
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
        } message: {
            Text("Allow camera access to scan documents.")
        }
        .alert("Name Document", isPresented: $showingNamingDialog) {
            TextField("Document name", text: $customName)
            Button("Use Suggested") { finalizePendingDocument(with: suggestedName) }
            Button("Use Custom") { finalizePendingDocument(with: customName.isEmpty ? suggestedName : customName) }
            Button("Cancel", role: .cancel) {
                scannedImages.removeAll()
                extractedText = ""
                suggestedName = ""
                customName = ""
                pendingOCRPages = []
                isProcessing = false
            }
        } message: {
            Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
        }
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var docViewToolbar: some ToolbarContent {
        if isSelectionMode {
            selectionToolbar
        } else {
            normalToolbar
        }
    }

    @ToolbarContentBuilder
    private var normalToolbar: some ToolbarContent {
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
                    isSelectionMode = true
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

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(isAllSelected ? "Deselect All" : "Select All") {
                if isAllSelected {
                    selectedDocumentIds.removeAll()
                } else {
                    selectedDocumentIds = Set(allDocs.map(\.id))
                }
            }
            .disabled(allDocs.isEmpty)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Cancel") {
                isSelectionMode = false
                selectedDocumentIds.removeAll()
            }
        }

        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button { shareSelectedDocuments() } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(!hasSelection)
            Spacer()
            Button { showingZipExportSheet = true } label: {
                Label("Compress", systemImage: zipSymbolName())
            }
            .disabled(!hasSelection)
            Spacer()
            Button { deleteSelectedDocuments() } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            .disabled(!hasSelection)
            Spacer()
        }
    }

    // MARK: - Selection

    private func toggleSelection(_ id: UUID) {
        if selectedDocumentIds.contains(id) {
            selectedDocumentIds.remove(id)
        } else {
            selectedDocumentIds.insert(id)
        }
    }

    private func deleteSelectedDocuments() {
        let toDelete = selectedDocumentIds
        for id in toDelete {
            if let doc = documentManager.documents.first(where: { $0.id == id }) {
                documentManager.deleteDocument(doc)
            }
        }
        selectedDocumentIds.removeAll()
        isSelectionMode = false
    }

    private func shareSelectedDocuments() {
        let docs = allDocs.filter { selectedDocumentIds.contains($0.id) }
        let items: [URL] = docs.compactMap { doc in
            guard let data = documentManager.anyFileData(for: doc.id) else { return nil }
            let ext = fileExtension(for: doc.type)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("share_\(doc.id).\(ext)")
            try? data.write(to: url)
            return url
        }
        guard !items.isEmpty else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }

    // MARK: - Import

    private func processImportedFiles(_ urls: [URL]) {
        isProcessing = true
        Task.detached(priority: .userInitiated) {
            var processedDocuments: [Document] = []
            for url in urls {
                let didStart = url.startAccessingSecurityScopedResource()
                if let document = await self.documentManager.processFile(at: url) {
                    processedDocuments.append(document)
                }
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
            await MainActor.run {
                for document in processedDocuments {
                    self.documentManager.addDocument(document)
                    let fullText = document.content
                    DispatchQueue.global(qos: .utility).async {
                        let cat = DocumentManager.inferCategory(title: document.title, content: fullText, summary: document.summary)
                        let kw = DocumentManager.makeKeywordsResume(title: document.title, content: fullText, summary: document.summary)
                        DispatchQueue.main.async {
                            let current = self.documentManager.getDocument(by: document.id) ?? document
                            let updated = Document(
                                id: current.id, title: current.title, content: current.content,
                                summary: current.summary, ocrPages: current.ocrPages,
                                category: cat, keywordsResume: kw, tags: current.tags,
                                sourceDocumentId: current.sourceDocumentId,
                                dateCreated: current.dateCreated, folderId: current.folderId,
                                sortOrder: current.sortOrder, type: current.type,
                                imageData: current.imageData, pdfData: current.pdfData,
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

    // MARK: - Scan

    private func startScan() {
        func present() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingScanner = true }
        }
        if !VNDocumentCameraViewController.isSupported {
            scannerMode = .simple
            present()
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            scannerMode = .document
            present()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.scannerMode = .document; present() }
                    else { self.showingCameraPermissionAlert = true }
                }
            }
        default:
            showingCameraPermissionAlert = true
        }
    }

    private func prepareNamingDialog(for images: [UIImage]) {
        isProcessing = true
        scannedImages = images
        prepareScanNamingAsync(images: images) { suggested, pages, text in
            self.pendingOCRPages = pages
            self.extractedText = text
            self.suggestedName = suggested
            self.customName = suggested
            self.isProcessing = false
            self.showingNamingDialog = true
        }
    }

    private func finalizePendingDocument(with name: String) {
        let safeName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedName : name
        isProcessing = true
        let images = scannedImages
        let pages = pendingOCRPages
        let text = extractedText

        let imageDataArray: [Data] = images.compactMap { $0.jpegData(compressionQuality: 0.95) }
        let pdfData = createScannedPDF(from: images)
        let capped = FileProcessingService.truncateText(text, maxChars: 50000)

        let document = Document(
            title: normalizedScanTitle(safeName),
            content: capped,
            summary: "Processing summary...",
            ocrPages: pages.isEmpty ? nil : pages,
            category: .general,
            keywordsResume: "",
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: nil,
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.documentManager.addDocument(document)
            self.importBatchResult = ImportBatchResult(documentIds: [document.id], importedAt: Date())
            self.scannedImages.removeAll()
            self.extractedText = ""
            self.suggestedName = ""
            self.customName = ""
            self.pendingOCRPages = []
            self.isProcessing = false
        }
    }

    private func processScannedText(_ text: String) {
        isProcessing = true
        extractedText = text
        generateAIDocumentName(from: text) { name in
            self.suggestedName = name
            self.customName = name
            self.isProcessing = false
            self.showingNamingDialog = true
        }
    }

    // MARK: - Share

    private func shareDocument(_ document: Document) {
        guard let data = documentManager.anyFileData(for: document.id) else { return }
        let ext = fileExtension(for: document.type)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share_\(document.id).\(ext)")
        try? data.write(to: url)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }

    private func fileExtension(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf, .scanned: return "pdf"
        case .docx: return "docx"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .xls: return "xls"
        case .xlsx: return "xlsx"
        case .text: return "txt"
        case .image: return "jpg"
        case .zip: return "zip"
        }
    }
}

// MARK: - Sort helper

private extension Array where Element == Document {
    func sorted(using mode: DocumentsSortMode) -> [Document] {
        switch mode {
        case .dateNewest: return sorted { $0.dateCreated > $1.dateCreated }
        case .dateOldest: return sorted { $0.dateCreated < $1.dateCreated }
        case .nameAsc: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .nameDesc: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .accessNewest: return sorted { $0.dateCreated > $1.dateCreated }
        case .accessOldest: return sorted { $0.dateCreated < $1.dateCreated }
        }
    }
}
