import SwiftUI
import PDFKit
import UIKit
import OSLog

struct ToolsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @AppStorage("pendingToolsDeepLink") private var pendingToolsDeepLink = ""
    @State private var deepLinkTool: ToolKind?
    @State private var showDeepLinkFlow = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Organize")
                            ToolRow(
                                icon: "rectangle.portrait.on.rectangle.portrait.fill",
                                title: "Merge PDF"
                            ) {
                                ToolsFlowView(tool: .merge)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "rectangle.split.2x1.fill",
                                title: "Split PDF"
                            ) {
                                ToolsFlowView(tool: .split)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "line.3.horizontal.decrease",
                                title: "Arrange PDF"
                            ) {
                                ToolsFlowView(tool: .rearrange)
                                    .environmentObject(documentManager)
                            }

                            SectionHeader(title: "Modify")
                            ToolRow(
                                icon: "rectangle.portrait.rotate",
                                title: "Rotate PDF"
                            ) {
                                ToolsFlowView(tool: .rotate)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "arrow.down.right.and.arrow.up.left",
                                title: "Compress PDF"
                            ) {
                                ToolsFlowView(tool: .compress)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(icon: "crop", title: "Crop PDF") {
                                ToolsFlowView(tool: .crop)
                                    .environmentObject(documentManager)
                            }

                            SectionHeader(title: "Protect & Sign")
                            ToolRow(icon: "signature", title: "Sign PDF") {
                                ToolsFlowView(tool: .sign)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(icon: "lock.fill", title: "Protect PDF", showsDivider: false) {
                                ToolsFlowView(tool: .protect)
                                    .environmentObject(documentManager)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(cardBackground)
                        )
                        .padding(.horizontal, 16)

                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
            .hideScrollBackground()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SharedSettingsSheetBackgroundModifier())
            }
            .onAppear {
                handlePendingDeepLinkIfNeeded()
            }
            .onChange(of: pendingToolsDeepLink) { _ in
                handlePendingDeepLinkIfNeeded()
            }
            .navigationDestination(isPresented: $showDeepLinkFlow) {
                if let tool = deepLinkTool {
                    ToolsFlowView(tool: tool)
                        .environmentObject(documentManager)
                }
            }
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(.secondarySystemGroupedBackground)
            : Color(.systemBackground)
    }

    private func handlePendingDeepLinkIfNeeded() {
        guard !pendingToolsDeepLink.isEmpty else { return }
        guard let tool = toolKindFromDeepLinkId(pendingToolsDeepLink) else {
            pendingToolsDeepLink = ""
            return
        }
        pendingToolsDeepLink = ""
        deepLinkTool = tool
        showDeepLinkFlow = false
        DispatchQueue.main.async {
            showDeepLinkFlow = true
        }
    }

    private func toolKindFromDeepLinkId(_ id: String) -> ToolKind? {
        switch id {
        case "tool-merge": return .merge
        case "tool-split": return .split
        case "tool-arrange": return .rearrange
        case "tool-rotate": return .rotate
        case "tool-compress": return .compress
        case "tool-crop": return .crop
        case "tool-sign": return .sign
        case "tool-protect": return .protect
        default: return nil
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

struct ToolRow<Destination: View>: View {
    let icon: String
    let title: String
    let destination: Destination
    let showsDivider: Bool

    init(icon: String, title: String, showsDivider: Bool = true, @ViewBuilder destination: () -> Destination) {
        self.icon = icon
        self.title = title
        self.destination = destination()
        self.showsDivider = showsDivider
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color("Primary"))
                    .frame(width: 24)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()
            }
            .padding(.vertical, 6)
        }
        if showsDivider {
            Divider()
        }
    }
}

private enum ToolKind: String, Hashable {
    case merge
    case split
    case rearrange
    case rotate
    case compress
    case crop
    case sign
    case protect

    var title: String {
        switch self {
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .rearrange: return "Arrange PDF"
        case .rotate: return "Rotate PDF"
        case .compress: return "Compress PDF"
        case .crop: return "Crop PDF"
        case .sign: return "Sign PDF"
        case .protect: return "Protect PDF"
        }
    }

    var selectionLimit: Int {
        switch self {
        case .merge: return 3
        default: return 1
        }
    }

    var pickerTitle: String {
        selectionLimit > 1 ? "Select PDFs" : "Select PDF"
    }
}

private struct ToolsFlowView: View {
    let tool: ToolKind
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: [UUID] = []
    @State private var showEditor = false
    @State private var shouldExitToRoot = false

    private var pdfDocuments: [Document] {
        documentManager.documents.filter { isPDFDocument($0) }
    }

    var body: some View {
        ToolsPDFPickerView(
            title: tool.pickerTitle,
            documents: pdfDocuments,
            maxSelection: tool.selectionLimit,
            selectedIds: $selectedIds,
            suppressCancel: shouldExitToRoot,
            onDone: { ids in
                if ids.isEmpty {
                    dismiss()
                } else {
                    selectedIds = ids
                    showEditor = true
                }
            },
            onCancel: {
                dismiss()
            }
        )
        .navigationDestination(isPresented: $showEditor) {
            ToolsEditorView(
                tool: tool,
                selectedIds: selectedIds,
                onFinish: {
                    shouldExitToRoot = true
                    showEditor = false
                }
            )
            .environmentObject(documentManager)
        }
        .onAppear {
            if shouldExitToRoot {
                dismiss()
            }
        }
    }
}

private struct ToolsPDFPickerView: View {
    let title: String
    let documents: [Document]
    let maxSelection: Int
    @Binding var selectedIds: [UUID]
    let suppressCancel: Bool
    let onDone: ([UUID]) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""
    @State private var didAdvance = false
    @State private var selectionSet: Set<UUID> = []
    @State private var lastSelectionSet: Set<UUID> = []
    @State private var isAdjustingSelection = false

    private var filteredDocuments: [Document] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return documents }
        let needle = trimmed.lowercased()
        return documents.filter { doc in
            let base = splitDisplayTitle(doc.title).base.lowercased()
            return base.contains(needle)
        }
    }

    var body: some View {
        List(selection: $selectionSet) {
            if filteredDocuments.isEmpty {
                Text("No PDFs available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredDocuments) { document in
                    DocumentRowView(
                        document: document,
                        isSelected: selectedIds.contains(document.id),
                        isSelectionMode: true,
                        usesNativeSelection: true,
                        onSelectToggle: {},
                        onOpen: {},
                        onRename: {},
                        onMoveToFolder: {},
                        onDelete: {},
                        onShare: {}
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .hideScrollBackground()
        .scrollDismissesKeyboardIfAvailable()
        .environment(\.editMode, .constant(.active))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search PDFs")
        .toolbar {
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        selectionSet = []
                        lastSelectionSet = []
                        selectedIds.removeAll()
                    }
                    .foregroundColor(.primary)
                    .disabled(selectedIds.isEmpty)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    didAdvance = true
                    onDone(selectedIds)
                }
                .foregroundColor(.primary)
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedIds.isEmpty)
            }
        }
        .onDisappear {
            if !didAdvance && !suppressCancel {
                onCancel()
            }
        }
        .onAppear {
            selectionSet = Set(selectedIds)
            lastSelectionSet = selectionSet
        }
        .onChange(of: selectionSet) { newSet in
            if isAdjustingSelection { return }
            isAdjustingSelection = true
            defer { isAdjustingSelection = false }

            if maxSelection == 1 {
                // Radio-button: always pick the newly tapped item
                if newSet.isEmpty {
                    // Prevent deselection — keep current
                    if let current = selectedIds.first {
                        selectionSet = [current]
                        lastSelectionSet = selectionSet
                    }
                } else {
                    let added = newSet.subtracting(lastSelectionSet)
                    let pick = added.first ?? newSet.first!
                    selectionSet = [pick]
                    lastSelectionSet = selectionSet
                    selectedIds = [pick]
                }
                return
            }

            // Multi-select (merge) — existing ordered behaviour
            let added = newSet.subtracting(lastSelectionSet)
            let removed = lastSelectionSet.subtracting(newSet)
            var ordered = selectedIds

            if !removed.isEmpty {
                ordered.removeAll { removed.contains($0) }
            }
            if !added.isEmpty {
                for id in added { ordered.append(id) }
            }

            if ordered.count > maxSelection {
                ordered = Array(ordered.prefix(maxSelection))
                selectionSet = Set(ordered)
            }

            selectedIds = ordered
            lastSelectionSet = selectionSet
        }
    }
}

private struct ToolsEditorView: View {
    let tool: ToolKind
    let selectedIds: [UUID]
    let onFinish: () -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var renameQueue: [UUID] = []
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var suggestedName = ""
    @State private var renameTargetId: UUID?

    private var selectedDocuments: [Document] {
        selectedIds.compactMap { documentManager.getDocument(by: $0) }
    }

    var body: some View {
        toolView
            .alert("Rename Document", isPresented: $showingRenameDialog) {
                TextField("Document name", text: $renameText)

                Button("Use Suggested") {
                    advanceRenameQueue(shouldRename: false)
                }

                Button("Rename") {
                    advanceRenameQueue(shouldRename: true)
                }

                Button("Cancel", role: .cancel) {
                    advanceRenameQueue(shouldRename: false)
                }
            } message: {
                Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
            }
    }

    @ViewBuilder
    private var toolView: some View {
        switch tool {
        case .merge:
            MergePDFsView(
                preselectedIds: selectedIds,
                preferredOrder: selectedIds,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .split:
            SplitPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .rearrange:
            RearrangePDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .rotate:
            RotatePDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .compress:
            CompressPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .crop:
            CropPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .sign:
            SignPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .protect:
            ProtectPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        }
    }

    private func handleCompletion(_ documents: [Document]) {
        if tool == .merge {
            finishFlow()
            return
        }
        let ids = documents.map { $0.id }
        renameQueue = ids
        showNextRename()
    }

    private func showNextRename() {
        guard !renameQueue.isEmpty else {
            finishFlow()
            return
        }
        let nextId = renameQueue.removeFirst()
        guard let doc = documentManager.getDocument(by: nextId) else {
            showNextRename()
            return
        }
        renameTargetId = doc.id
        suggestedName = doc.title
        renameText = splitDisplayTitle(doc.title).base
        showingRenameDialog = true
    }

    private func advanceRenameQueue(shouldRename: Bool) {
        if shouldRename {
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let targetId = renameTargetId {
                renameDocument(id: targetId, to: trimmed)
            }
        }
        showingRenameDialog = false
        showNextRename()
    }

    private func finishFlow() {
        onFinish()
        dismiss()
    }

    private func renameDocument(id: UUID, to newBase: String) {
        guard let idx = documentManager.documents.firstIndex(where: { $0.id == id }) else { return }
        let old = documentManager.documents[idx]

        let oldParts = splitDisplayTitle(old.title)
        let typedURL = URL(fileURLWithPath: newBase)
        let typedExt = typedURL.pathExtension.lowercased()
        let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
        let sanitizedBase = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : newBase
        let finalBase = sanitizedBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalBase.isEmpty else { return }

        let newTitle = oldParts.ext.isEmpty ? finalBase : "\(finalBase).\(oldParts.ext)"

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
            originalFileData: old.originalFileData
        )
        documentManager.documents[idx] = updated
        documentManager.updateSummary(for: updated.id, to: updated.summary)
    }
}

struct CompressPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var quality: Double = 0.7

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 16) {
            if let document = selectedDocument {
                VStack(spacing: 6) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Compression quality: \(Int(quality * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(value: $quality, in: 0.4...0.9, step: 0.05)
                    .padding(.horizontal)

                if allowsPicker {
                    Button("Choose Different PDF") { showingPicker = true }
                        .foregroundColor(.secondary)
                }
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Compress PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Compressing..." : "Compress") {
                    compressSelected()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocument == nil || isSaving)
            }
        }
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .alert("Compress PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func compressSelected() {
        guard let document = selectedDocument,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else {
            alertMessage = "Please choose a PDF first."
            showingAlert = true
            return
        }

        isSaving = true
        var existingTitles = existingDocumentTitles(in: documentManager)
        let baseName = baseTitle(for: document.title)
        let preferredBase = "\(baseName)_compressed"
        let outputName = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
        existingTitles.insert(outputName.lowercased())

        let compressionQuality = quality

        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let outData = renderer.pdfData { context in
                for idx in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: idx) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    context.beginPage(withBounds: bounds, pageInfo: [:])

                    let targetSize = CGSize(width: bounds.width * compressionQuality, height: bounds.height * compressionQuality)
                    let image = page.thumbnail(of: targetSize, for: .mediaBox)
                    image.draw(in: bounds)
                }
            }

            let newDoc = makePDFDocument(
                title: outputName,
                data: outData,
                sourceDocumentId: document.id,
                sourceDocument: document
            )
            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Compressed PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
    }
}

struct ProtectPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 16) {
            if let document = selectedDocument {
                VStack(spacing: 6) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Set a password required by any PDF reader.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                    .padding(.horizontal)

                SecureField("Confirm Password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
                    .padding(.horizontal)

                if allowsPicker {
                    Button("Choose Different PDF") { showingPicker = true }
                        .foregroundColor(.secondary)
                }
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Protect PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Securing..." : "Protect") {
                    protectSelected()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocument == nil || isSaving)
            }
        }
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .alert("Protect PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func protectSelected() {
        guard let document = selectedDocument,
              let sourceData = pdfData(from: document, documentManager: documentManager) else {
            alertMessage = "Please choose a PDF first."
            showingAlert = true
            return
        }

        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "Password cannot be empty."
            showingAlert = true
            return
        }
        guard trimmed == confirmPassword else {
            alertMessage = "Passwords do not match."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            guard let pdf = PDFDocument(data: sourceData) else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to read the selected PDF."
                    showingAlert = true
                }
                return
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("protected_\(UUID().uuidString).pdf")
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: trimmed,
                .ownerPasswordOption: trimmed
            ]

            let writeOK = pdf.write(to: tempURL, withOptions: options)
            let outData: Data
            do {
                guard writeOK else { throw NSError(domain: "ToolsView", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF write failed"]) }
                outData = try Data(contentsOf: tempURL)
            } catch {
                AppLogger.ui.error("Failed to read encrypted PDF data: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to encrypt PDF."
                    showingAlert = true
                }
                return
            }
            do { try FileManager.default.removeItem(at: tempURL) } catch { AppLogger.ui.warning("Failed to remove temp PDF file: \(error.localizedDescription)") }

            guard let verifyPDF = PDFDocument(data: outData), verifyPDF.isEncrypted else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "PDF encryption failed."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_protected"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(
                title: title,
                data: outData,
                sourceDocumentId: document.id,
                sourceDocument: document
            )

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                password = ""
                confirmPassword = ""
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Password-protected PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct ComingSoonView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("\(title) is coming soon.")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("We’ll add this feature in a future update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
