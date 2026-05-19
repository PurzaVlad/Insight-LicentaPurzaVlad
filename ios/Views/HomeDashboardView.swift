import SwiftUI
import VisionKit
import AVFoundation
import PDFKit

// MARK: - HomeDashboardView

struct HomeDashboardView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void

    // Import state
    @State private var showingDocumentPicker = false
    @State private var isProcessing = false
    @State private var importBatchResult: ImportBatchResult?
    @State private var showingZipExportSheet = false
    @State private var showingSettings = false

    // Scanner state
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText: String = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""

    var body: some View {
        NavigationStack {
            Group {
                if documentManager.documents.isEmpty && !isProcessing {
                    emptyState
                } else {
                    dashboardContent
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { dashboardToolbar }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .bindGlobalOperationLoading(isProcessing)
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in processImportedFiles(urls) }
        }
        .sheet(item: $importBatchResult) { batch in
            ImportReviewView(result: batch)
                .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingZipExportSheet) {
            ZipExportView()
                .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .modifier(SettingsSheetBackgroundModifier())
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
            Text("Suggested: \"\(suggestedName)\"")
        }
        .fullScreenCover(isPresented: $showingScanner) {
            if scannerMode == .document, VNDocumentCameraViewController.isSupported {
                DocumentScannerView { images in
                    scannedImages = images
                    prepareNamingDialog(for: images)
                }
                .ignoresSafeArea()
            } else {
                SimpleCameraView { text in processScannedText(text) }
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                greetingSection
                statsSection
                recentSection
                browseSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(greeting)
                .font(.title2)
                .fontWeight(.semibold)
            Text(Date(), style: .date)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        let docs = documentManager.documents
        let total = docs.count
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let thisWeek = docs.filter { $0.dateCreated > weekAgo }.count
        let sensitive = docs.filter { !$0.sensitiveFlags.isEmpty }.count
        return HStack(spacing: 12) {
            DashboardStatCard(value: "\(total)", label: "Total", icon: "doc.on.doc.fill", color: Color("Primary"))
            DashboardStatCard(value: "\(thisWeek)", label: "This Week", icon: "calendar", color: .green)
            DashboardStatCard(
                value: "\(sensitive)",
                label: "Sensitive",
                icon: "exclamationmark.shield.fill",
                color: sensitive > 0 ? .orange : Color(.tertiaryLabel)
            )
        }
    }

    // MARK: - Recent

    private var recentDocuments: [Document] {
        documentManager.documents
            .sorted {
                let a = documentManager.lastAccessedMap[$0.id] ?? $0.dateCreated
                let b = documentManager.lastAccessedMap[$1.id] ?? $1.dateCreated
                return a > b
            }
            .prefix(10)
            .map { $0 }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentDocuments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent")
                        .font(.headline)
                    Spacer()
                    NavigationLink {
                        SmartViewDocumentsView(title: "All Documents", filter: nil, onOpenDocument: openDocument)
                            .environmentObject(documentManager)
                    } label: {
                        Text("See All")
                            .font(.subheadline)
                            .foregroundColor(Color("Primary"))
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recentDocuments) { doc in
                            DashboardRecentDocCard(document: doc) { openDocument(doc) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Browse

    private var categoryViews: [SmartView] {
        SmartView.generate(from: documentManager.documents).filter {
            if case .keyword = $0.filter { return true }
            return false
        }
    }

    private var sensitiveViews: [SmartView] {
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

    private var documentTypeViews: [SmartView] {
        Document.DocumentType.allCases.compactMap { type in
            let count = documentManager.documents.filter { $0.type == type }.count
            guard count > 0 else { return nil }
            return SmartView(
                id: "doctype_\(type.rawValue)",
                name: displayName(for: type),
                systemImage: icon(for: type),
                filter: .documentType(type)
            )
        }
    }

    private func displayName(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf: return "PDF"
        case .docx: return "Word Document"
        case .ppt: return "PowerPoint"
        case .pptx: return "PowerPoint"
        case .xls: return "Excel"
        case .xlsx: return "Excel Spreadsheet"
        case .image: return "Image"
        case .scanned: return "Scanned PDFs"
        case .text: return "Text File"
        case .zip: return "Archive"
        }
    }

    private func icon(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf, .scanned: return "doc.richtext"
        case .docx: return "doc.text"
        case .xls, .xlsx: return "tablecells"
        case .ppt, .pptx: return "play.rectangle"
        case .image: return "photo"
        case .zip: return "archivebox"
        case .text: return "doc.plaintext"
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Browse")
                .font(.title2)
                .fontWeight(.semibold)

            if !categoryViews.isEmpty {
                BrowseGroup(title: "Categories") {
                    ForEach(Array(categoryViews.enumerated()), id: \.element.id) { idx, view in
                        let count = documentManager.documents.filter { view.matches($0) }.count
                        NavigationLink {
                            SmartViewDocumentsView(title: view.name, filter: view, onOpenDocument: openDocument)
                                .environmentObject(documentManager)
                        } label: {
                            BrowseRow(name: view.name, icon: view.systemImage, iconColor: Color("Primary"), count: count)
                        }
                        .buttonStyle(.plain)
                        if idx < categoryViews.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }

            if !sensitiveViews.isEmpty {
                BrowseGroup(title: "Sensitive Information") {
                    ForEach(Array(sensitiveViews.enumerated()), id: \.element.id) { idx, view in
                        let count = documentManager.documents.filter { view.matches($0) }.count
                        NavigationLink {
                            SmartViewDocumentsView(title: view.name, filter: view, onOpenDocument: openDocument)
                                .environmentObject(documentManager)
                        } label: {
                            BrowseRow(name: view.name, icon: view.systemImage, iconColor: .orange, count: count)
                        }
                        .buttonStyle(.plain)
                        if idx < sensitiveViews.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }

            if !documentTypeViews.isEmpty {
                BrowseGroup(title: "Document Types") {
                    ForEach(Array(documentTypeViews.enumerated()), id: \.element.id) { idx, view in
                        let count = documentManager.documents.filter { view.matches($0) }.count
                        NavigationLink {
                            SmartViewDocumentsView(title: view.name, filter: view, onOpenDocument: openDocument)
                                .environmentObject(documentManager)
                        } label: {
                            BrowseRow(name: view.name, icon: view.systemImage, iconColor: Color("Primary"), count: count)
                        }
                        .buttonStyle(.plain)
                        if idx < documentTypeViews.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }

            BrowseGroup(title: "All Documents") {
                let total = documentManager.documents.count
                NavigationLink {
                    SmartViewDocumentsView(title: "All Documents", filter: nil, onOpenDocument: openDocument)
                        .environmentObject(documentManager)
                } label: {
                    BrowseRow(name: "All Documents", icon: "doc.on.doc.fill", iconColor: Color("Primary"), count: total)
                }
                .buttonStyle(.plain)

                let untaggedCount = documentManager.documents.filter { $0.tags.isEmpty && $0.keywordsResume.isEmpty }.count
                if untaggedCount > 0 {
                    Divider().padding(.leading, 52)
                    let filter = SmartView(id: "untagged", name: "Untagged", systemImage: "tag.slash", filter: .untagged)
                    NavigationLink {
                        SmartViewDocumentsView(title: "Untagged", filter: filter, onOpenDocument: openDocument)
                            .environmentObject(documentManager)
                    } label: {
                        BrowseRow(name: "Untagged", icon: "tag.slash", iconColor: Color(.secondaryLabel), count: untaggedCount)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            HStack(spacing: 2) {
                Button("Scan Document") { startScan() }
                    .buttonStyle(.borderedProminent)
                Text("or")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                Button("Import Files") { showingDocumentPicker = true }
                    .buttonStyle(.borderedProminent)
            }
            Text("to get started")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var dashboardToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { showingDocumentPicker = true } label: {
                    Label("Import Files", systemImage: "square.and.arrow.down")
                }
                Button { startScan() } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                }
                Button { showingZipExportSheet = true } label: {
                    Label("Create Zip", systemImage: zipSymbolName())
                }
            } label: {
                Image(systemName: "plus").foregroundColor(.primary)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { showingSettings = true } label: {
                    Label("Preferences", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis").foregroundColor(.primary)
            }
        }
    }

    // MARK: - Open Document

    private func openDocument(_ document: Document) {
        let ext: String
        switch document.type {
        case .pdf, .scanned: ext = "pdf"
        case .docx: ext = "docx"
        case .ppt: ext = "ppt"
        case .pptx: ext = "pptx"
        case .xls: ext = "xls"
        case .xlsx: ext = "xlsx"
        case .text: ext = "txt"
        case .image: ext = "jpg"
        case .zip: ext = "zip"
        }
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
            AppLogger.ui.error("Dashboard open error: \(error.localizedDescription)")
            onShowSummary(document)
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
}

// MARK: - DashboardStatCard

private struct DashboardStatCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 18, weight: .semibold))
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }
}

// MARK: - DashboardRecentDocCard

private struct DashboardRecentDocCard: View {
    let document: Document
    let onTap: () -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var thumbnail: UIImage?

    private static let cardWidth: CGFloat = 88
    private static let cardHeight: CGFloat = 110

    private var docIcon: String {
        switch document.type {
        case .pdf, .scanned: return "doc.richtext"
        case .docx: return "doc.text"
        case .xls, .xlsx: return "tablecells"
        case .ppt, .pptx: return "play.rectangle"
        case .image: return "photo"
        case .zip: return "archivebox"
        case .text: return "doc.plaintext"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemGroupedBackground))
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: Self.cardWidth, height: Self.cardHeight)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: docIcon)
                            .font(.system(size: 28))
                            .foregroundColor(Color("Primary").opacity(0.7))
                    }
                }
                .frame(width: Self.cardWidth, height: Self.cardHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
                )

                Text(splitDisplayTitle(document.title).base)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.cardWidth, height: 34, alignment: .topLeading)

                Text(document.dateCreated, style: .date)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: Self.cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .task(id: document.id) {
            guard thumbnail == nil else { return }
            let imgData = documentManager.imageData(for: document.id)
            let pdfBytes = documentManager.pdfData(for: document.id)
            let docType = document.type
            thumbnail = await Task.detached(priority: .utility) {
                switch docType {
                case .image:
                    guard let first = imgData?.first else { return nil }
                    return UIImage(data: first)
                case .pdf, .scanned:
                    guard let data = pdfBytes,
                          let pdfDoc = PDFDocument(data: data),
                          let page = pdfDoc.page(at: 0) else { return nil }
                    let bounds = page.bounds(for: .mediaBox)
                    guard bounds.width > 0 && bounds.height > 0 else { return nil }
                    let scale = DashboardRecentDocCard.cardWidth * 2 / bounds.width
                    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                    let renderer = UIGraphicsImageRenderer(size: size)
                    return renderer.image { ctx in
                        UIColor.white.setFill()
                        ctx.fill(CGRect(origin: .zero, size: size))
                        ctx.cgContext.translateBy(x: 0, y: size.height)
                        ctx.cgContext.scaleBy(x: scale, y: -scale)
                        page.draw(with: .mediaBox, to: ctx.cgContext)
                    }
                default:
                    return nil
                }
            }.value
        }
    }
}

// MARK: - BrowseGroup

private struct BrowseGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
    }
}

// MARK: - BrowseRow

private struct BrowseRow: View {
    let name: String
    let icon: String
    let iconColor: Color
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 14, weight: .medium))
            }
            Text(name)
                .font(.system(size: 16))
                .foregroundColor(.primary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
