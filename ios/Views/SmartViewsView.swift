import SwiftUI
import VisionKit
import AVFoundation
import OSLog

// MARK: - SmartViews Category Sort Mode

enum SmartViewsCategorySortMode: String {
    case countDesc   // Most documents (default)
    case nameAsc     // A → Z
    case nameDesc    // Z → A
    case recentFirst // Most recently added document first
    case oldestFirst // Oldest document first
}

// MARK: - SmartView Model

struct SmartView: Identifiable {
    enum Filter {
        case keyword(String)
        case scanned
        case untagged
        case sensitiveFlag(SensitiveDataFlag)
        case anySensitiveFlag
        case documentType(Document.DocumentType)
        case topic(String)
    }

    let id: String
    let name: String
    let systemImage: String
    let filter: Filter

    func matches(_ document: Document) -> Bool {
        switch filter {
        case .keyword(let kw):
            return !document.keywordsResume.isEmpty &&
                document.keywordsResume.localizedCaseInsensitiveContains(kw)
        case .scanned:
            return document.type == .scanned
        case .untagged:
            return document.tags.isEmpty && document.keywordsResume.isEmpty
        case .sensitiveFlag(let flag):
            return document.sensitiveFlags.contains(flag)
        case .anySensitiveFlag:
            return !document.sensitiveFlags.isEmpty
        case .documentType(let type):
            return document.type == type
        case .topic(let tag):
            return document.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
        }
    }
}

extension SmartView {
    static func generate(from documents: [Document]) -> [SmartView] {
        var views: [SmartView] = []

        let keywordGroups = Dictionary(
            grouping: documents.filter { !$0.keywordsResume.isEmpty }
        ) { $0.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines) }

        for (keyword, _) in keywordGroups.sorted(by: { $0.value.count > $1.value.count }) {
            guard !keyword.isEmpty else { continue }
            views.append(SmartView(
                id: "kw_\(keyword)",
                name: keyword,
                systemImage: iconFor(keyword),
                filter: .keyword(keyword)
            ))
        }

        if documents.contains(where: { $0.type == .scanned }) {
            views.append(SmartView(id: "type_scanned", name: "Scanned", systemImage: "scanner", filter: .scanned))
        }

        if documents.contains(where: { $0.tags.isEmpty && $0.keywordsResume.isEmpty }) {
            views.append(SmartView(id: "untagged", name: "Untagged", systemImage: "tag.slash", filter: .untagged))
        }

        return views
    }

    static func generateTopics(from documents: [Document]) -> [SmartView] {
        var tagCounts: [String: Int] = [:]
        for doc in documents {
            for tag in doc.tags {
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                tagCounts[normalized, default: 0] += 1
            }
        }
        return tagCounts
            .filter { $0.value >= 2 }
            .sorted { $0.value > $1.value }
            .map { tag, _ in
                SmartView(id: "topic_\(tag)", name: tag, systemImage: iconForTopic(tag), filter: .topic(tag))
            }
    }

    static func iconForTopic(_ tag: String) -> String {
        let t = tag.lowercased()
        if t.contains("bank") || t.contains("finance") || t.contains("financial") { return "banknote" }
        if t.contains("hospital") || t.contains("clinic") || t.contains("health") { return "cross.circle" }
        if t.contains("school") || t.contains("university") || t.contains("college") { return "graduationcap" }
        if t.contains("gov") || t.contains("court") || t.contains("ministry") { return "building.columns" }
        if t.contains("insurance") { return "shield" }
        if t.contains("tech") || t.contains("software") || t.contains("digital") { return "cpu" }
        return "person.2.fill"
    }

    static func iconFor(_ keyword: String) -> String {
        let kw = keyword.lowercased()
        if kw.contains("invoice") || kw.contains("receipt") || kw.contains("bill") { return "doc.text.fill" }
        if kw.contains("contract") || kw.contains("agreement") { return "doc.badge.gearshape" }
        if kw.contains("report") { return "chart.bar.doc.horizontal" }
        if kw.contains("personal") || kw.contains("identity") || kw.contains("passport") { return "person.text.rectangle" }
        if kw.contains("financial") || kw.contains("tax") || kw.contains("finance") { return "banknote" }
        if kw.contains("medical") || kw.contains("health") { return "heart.text.square" }
        if kw.contains("legal") || kw.contains("court") { return "building.columns" }
        if kw.contains("cv") || kw.contains("resume") { return "person.crop.rectangle" }
        if kw.contains("certificate") || kw.contains("diploma") { return "medal" }
        if kw.contains("letter") || kw.contains("correspondence") { return "envelope" }
        return "doc.text"
    }
}

// MARK: - SmartViewsListView

struct SmartViewsListView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void

    private enum BrowseMode { case smart, topics }
    @State private var browseMode: BrowseMode = .smart

    // Import state
    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var isProcessing = false
    @State private var importBatchResult: ImportBatchResult?
    @State private var showingZipExportSheet = false

    // Scan naming state
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText: String = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""

    // Settings
    @State private var showingSettings = false

    @AppStorage("smartViewsCategorySortMode") private var categorySortModeRaw = SmartViewsCategorySortMode.countDesc.rawValue

    private var categorySortMode: SmartViewsCategorySortMode {
        get { SmartViewsCategorySortMode(rawValue: categorySortModeRaw) ?? .countDesc }
        nonmutating set { categorySortModeRaw = newValue.rawValue }
    }

    private var smartViews: [SmartView] {
        let views = SmartView.generate(from: documentManager.documents)
        let docs = documentManager.documents
        switch categorySortMode {
        case .countDesc:
            return views
        case .nameAsc:
            return views.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:
            return views.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .recentFirst:
            return views.sorted { a, b in
                let aDate = docs.filter { a.matches($0) }.map(\.dateCreated).max() ?? .distantPast
                let bDate = docs.filter { b.matches($0) }.map(\.dateCreated).max() ?? .distantPast
                return aDate > bDate
            }
        case .oldestFirst:
            return views.sorted { a, b in
                let aDate = docs.filter { a.matches($0) }.map(\.dateCreated).min() ?? .distantFuture
                let bDate = docs.filter { b.matches($0) }.map(\.dateCreated).min() ?? .distantFuture
                return aDate < bDate
            }
        }
    }

    private var topicViews: [SmartView] {
        let views = SmartView.generateTopics(from: documentManager.documents)
        let docs = documentManager.documents
        switch categorySortMode {
        case .countDesc:
            return views
        case .nameAsc:
            return views.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:
            return views.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .recentFirst:
            return views.sorted { a, b in
                let aDate = docs.filter { a.matches($0) }.map(\.dateCreated).max() ?? .distantPast
                let bDate = docs.filter { b.matches($0) }.map(\.dateCreated).max() ?? .distantPast
                return aDate > bDate
            }
        case .oldestFirst:
            return views.sorted { a, b in
                let aDate = docs.filter { a.matches($0) }.map(\.dateCreated).min() ?? .distantFuture
                let bDate = docs.filter { b.matches($0) }.map(\.dateCreated).min() ?? .distantFuture
                return aDate < bDate
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if documentManager.documents.isEmpty && !isProcessing {
                    emptyStateView
                } else {
                    listContent
                }
            }
            .navigationTitle("Smart Views")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { smartViewsToolbar }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .bindGlobalOperationLoading(isProcessing)
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in processImportedFiles(urls) }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .modifier(SettingsSheetBackgroundModifier())
        }
        .sheet(item: $importBatchResult) { batch in
            ImportReviewView(result: batch)
                .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingZipExportSheet) {
            ZipExportView()
                .environmentObject(documentManager)
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
    }

    // MARK: - List Content

    private var sensitiveFlagViews: [SmartView] {
        SensitiveDataFlag.allCases.compactMap { flag in
            let count = documentManager.documents.filter { $0.sensitiveFlags.contains(flag) }.count
            guard count > 0 else { return nil }
            return SmartView(
                id: "sensitive_\(flag.rawValue)",
                name: flag.label,
                systemImage: flag.icon,
                filter: .sensitiveFlag(flag)
            )
        }
    }

    private var listContent: some View {
        List {
            Section {
                Picker("Browse Mode", selection: $browseMode) {
                    Text("Smart").tag(BrowseMode.smart)
                    Text("Topics").tag(BrowseMode.topics)
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            }

            Section {
                NavigationLink {
                    SmartViewDocumentsView(
                        title: "All Documents",
                        filter: nil,
                        onOpenDocument: openDocument
                    )
                    .environmentObject(documentManager)
                } label: {
                    SmartViewRowLabel(name: "All Documents", icon: "doc.on.doc.fill", count: documentManager.documents.count)
                }
            }

            if browseMode == .smart {
                if !smartViews.isEmpty {
                    Section("By Type") {
                        ForEach(smartViews) { view in
                            NavigationLink {
                                SmartViewDocumentsView(
                                    title: view.name,
                                    filter: view,
                                    onOpenDocument: openDocument
                                )
                                .environmentObject(documentManager)
                            } label: {
                                SmartViewRowLabel(
                                    name: view.name,
                                    icon: view.systemImage,
                                    count: documentManager.documents.filter { view.matches($0) }.count
                                )
                            }
                        }
                    }
                }

                if !sensitiveFlagViews.isEmpty {
                    Section("Sensitive Data") {
                        ForEach(sensitiveFlagViews) { view in
                            NavigationLink {
                                SmartViewDocumentsView(
                                    title: view.name,
                                    filter: view,
                                    onOpenDocument: openDocument
                                )
                                .environmentObject(documentManager)
                            } label: {
                                SensitiveFlagRowLabel(
                                    name: view.name,
                                    icon: view.systemImage,
                                    count: documentManager.documents.filter { view.matches($0) }.count
                                )
                            }
                        }
                    }
                }
            } else {
                if !topicViews.isEmpty {
                    Section("Topics") {
                        ForEach(topicViews) { view in
                            NavigationLink {
                                SmartViewDocumentsView(
                                    title: view.name,
                                    filter: view,
                                    onOpenDocument: openDocument
                                )
                                .environmentObject(documentManager)
                            } label: {
                                SmartViewRowLabel(
                                    name: view.name,
                                    icon: view.systemImage,
                                    count: documentManager.documents.filter { view.matches($0) }.count
                                )
                            }
                        }
                    }
                } else {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "person.2")
                                .font(.system(size: 32))
                                .foregroundColor(.secondary)
                            Text("No topics yet")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Topics appear when 2 or more documents share the same subject or entity.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var smartViewsToolbar: some ToolbarContent {
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
                        switch categorySortMode {
                        case .nameAsc, .nameDesc: return "name"
                        case .recentFirst, .oldestFirst: return "date"
                        case .countDesc: return "count"
                        }
                    },
                    set: { group in
                        switch group {
                        case "name":
                            categorySortMode = (categorySortMode == .nameAsc) ? .nameDesc : .nameAsc
                        case "date":
                            categorySortMode = (categorySortMode == .recentFirst) ? .oldestFirst : .recentFirst
                        case "count":
                            categorySortMode = .countDesc
                        default: break
                        }
                    }
                )) {
                    let nameText = categorySortMode == .nameAsc ? "Name ↓" : categorySortMode == .nameDesc ? "Name ↑" : "Name"
                    let dateText = categorySortMode == .recentFirst ? "Date ↓" : categorySortMode == .oldestFirst ? "Date ↑" : "Date"
                    Label(nameText, systemImage: "textformat").tag("name")
                    Label(dateText, systemImage: "calendar").tag("date")
                    Label("Count", systemImage: "number").tag("count")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.primary)
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                Button("Scan Document") { startScan() }
                    .buttonStyle(.borderedProminent)
                Text("or")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                Button("Import Files") { showingDocumentPicker = true }
                    .buttonStyle(.borderedProminent)
            }
            Text("to get started")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Open Document

    private func openDocument(_ document: Document) {
        let ext = fileExtension(for: document.type)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview_\(document.id).\(ext)")
        guard let data = documentManager.anyFileData(for: document.id) else {
            onShowSummary(document)
            return
        }
        do {
            try data.write(to: tempURL)
            onOpenPreview(document, tempURL)
        } catch {
            AppLogger.ui.error("SmartViews open error: \(error.localizedDescription)")
            onShowSummary(document)
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

        var imageDataArray: [Data] = images.compactMap { $0.jpegData(compressionQuality: 0.95) }
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
}

// MARK: - SensitiveFlagRowLabel

private struct SensitiveFlagRowLabel: View {
    let name: String
    let icon: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundColor(.orange)
                    .font(.system(size: 16, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                Text("\(count) document\(count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SmartViewRowLabel

private struct SmartViewRowLabel: View {
    let name: String
    let icon: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color("Primary").opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .foregroundColor(Color("Primary"))
                    .font(.system(size: 16, weight: .medium))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                Text("\(count) document\(count == 1 ? "" : "s")")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

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
                                onConvert: {},
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
                            onOpen: { onOpenDocument(document) },
                            onRename: {},
                            onMoveToFolder: {},
                            onDelete: {
                                documentToDelete = document
                                showingDeleteConfirm = true
                            },
                            onConvert: {},
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
                                onOpen: { onOpenDocument(document) },
                                onRename: {},
                                onMoveToFolder: {},
                                onDelete: {
                                    documentToDelete = document
                                    showingDeleteConfirm = true
                                },
                                onConvert: {},
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
