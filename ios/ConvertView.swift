import SwiftUI
import Foundation
import UIKit
import AVFoundation
import PDFKit
import SSZipArchive
import OSLog

struct ConvertView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @AppStorage("pendingConvertDeepLink") private var pendingConvertDeepLink = ""
    @State private var deepLinkConfig: ConvertDeepLinkConfig?
    @State private var showDeepLinkFlow = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            ConvertSectionHeader(title: "From PDF")
                            ConvertRow(title: "PDF to DOCX", icon: .pdfToDocx) {
                                ConvertFlowView(
                                    targetFormat: .docx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to PPTX", icon: .pdfToPptx) {
                                ConvertFlowView(
                                    targetFormat: .pptx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to XLSX", icon: .pdfToXlsx) {
                                ConvertFlowView(
                                    targetFormat: .xlsx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to JPG", icon: .pdfToJpg) {
                                ConvertFlowView(
                                    targetFormat: .image,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }

                            ConvertSectionHeader(title: "To PDF")
                            ConvertRow(title: "DOCX to PDF", icon: .docxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.docx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PPTX to PDF", icon: .pptxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.pptx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "XLSX to PDF", icon: .xlsxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.xlsx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "JPG to PDF", icon: .jpgToPdf, showsDivider: false) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.image]
                                )
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
            .navigationTitle("Convert")
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
            .onChange(of: pendingConvertDeepLink) { _ in
                handlePendingDeepLinkIfNeeded()
            }
            .navigationDestination(isPresented: $showDeepLinkFlow) {
                if let config = deepLinkConfig {
                    ConvertFlowView(
                        targetFormat: config.targetFormat,
                        allowedSourceTypes: config.allowedSourceTypes
                    )
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

    private struct ConvertDeepLinkConfig {
        let targetFormat: ConversionView.DocumentFormat
        let allowedSourceTypes: Set<Document.DocumentType>
    }

    private func handlePendingDeepLinkIfNeeded() {
        guard !pendingConvertDeepLink.isEmpty else { return }
        guard let config = convertDeepLinkConfig(for: pendingConvertDeepLink) else {
            pendingConvertDeepLink = ""
            return
        }
        pendingConvertDeepLink = ""
        deepLinkConfig = config
        showDeepLinkFlow = false
        DispatchQueue.main.async {
            showDeepLinkFlow = true
        }
    }

    private func convertDeepLinkConfig(for id: String) -> ConvertDeepLinkConfig? {
        switch id {
        case "convert-pdf-docx":
            return ConvertDeepLinkConfig(targetFormat: .docx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-pptx":
            return ConvertDeepLinkConfig(targetFormat: .pptx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-xlsx":
            return ConvertDeepLinkConfig(targetFormat: .xlsx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-jpg":
            return ConvertDeepLinkConfig(targetFormat: .image, allowedSourceTypes: [.pdf, .scanned])
        case "convert-docx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.docx])
        case "convert-pptx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.pptx])
        case "convert-xlsx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.xlsx])
        case "convert-jpg-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.image])
        default:
            return nil
        }
    }
}

struct ConvertRow<Destination: View>: View {
    let title: String 
    let icon: ConvertIconType
    let destination: Destination
    let showsDivider: Bool

    init(title: String, icon: ConvertIconType, showsDivider: Bool = true, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.icon = icon
        self.destination = destination()
        self.showsDivider = showsDivider
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                ConvertIcon(type: icon)

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

private struct ConvertFlowView: View {
    let targetFormat: ConversionView.DocumentFormat
    let allowedSourceTypes: Set<Document.DocumentType>
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: UUID? = nil
    @State private var selectionSet: Set<UUID> = []
    @State private var isAdjustingSelection = false
    @State private var isConverting = false
    @State private var isGlobalLoadingActive = false
    @State private var searchText = ""
    @State private var showScannedPDFChoice = false
    @State private var pendingScannedChoiceDocument: Document? = nil
    @State private var showServerUploadConsent = false
    @State private var pendingConsentDocument: Document? = nil
    @State private var pendingConsentMode: PDFToOfficeMode = .ocrEditable
    @AppStorage("alwaysAllowServerConversionUpload") private var alwaysAllowServerConversionUpload = false
    @State private var conversionErrorMessage: String? = nil
    @State private var showConversionError = false
    @AppStorage("useLibreOfficeEngine") private var useLibreOfficeEngine = false

    private var documents: [Document] {
        documentManager.documents.filter { allowedSourceTypes.contains($0.type) }
    }

    private var filteredDocuments: [Document] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return documents }
        let needle = trimmed.lowercased()
        return documents.filter { doc in
            splitDisplayTitle(doc.title).base.lowercased().contains(needle)
        }
    }

    private var selectedDocument: Document? {
        guard let selectedId else { return nil }
        return documentManager.getDocument(by: selectedId)
    }

    var body: some View {
        List(selection: $selectionSet) {
            if filteredDocuments.isEmpty {
                Text("No documents available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredDocuments) { document in
                    DocumentRowView(
                        document: document,
                        isSelected: selectionSet.contains(document.id),
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
        .navigationTitle("Select Document")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search documents")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Convert") {
                    startConversion()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedId == nil || isConverting)
            }
        }
        .onAppear {
            selectionSet = selectedId.map { [$0] } ?? []
        }
        .onChange(of: selectionSet) { newSet in
            if isAdjustingSelection { return }
            isAdjustingSelection = true
            defer { isAdjustingSelection = false }

            if newSet.isEmpty {
                // Radio-button: prevent deselection once something is selected
                if let current = selectedId {
                    selectionSet = [current]
                }
            } else {
                // Pick the newly added item (not the previously selected one)
                let added = newSet.subtracting(selectedId.map { [$0] } ?? [])
                let pick = added.first ?? newSet.first!
                selectionSet = [pick]
                selectedId = pick
            }
        }
        .onDisappear {
            if isGlobalLoadingActive {
                GlobalLoadingBridge.setOperationLoading(false)
                isGlobalLoadingActive = false
            }
        }
        .alert("Scanned PDF Detected", isPresented: $showScannedPDFChoice, presenting: pendingScannedChoiceDocument) { _ in
            Button("Extracted OCR (editable)") {
                if let doc = pendingScannedChoiceDocument {
                    pendingScannedChoiceDocument = nil
                    requestConsentOrConvert(for: doc, mode: .ocrEditable)
                }
            }
            Button("Visual quality (non-editable)") {
                if let doc = pendingScannedChoiceDocument {
                    pendingScannedChoiceDocument = nil
                    requestConsentOrConvert(for: doc, mode: .visualImage)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingScannedChoiceDocument = nil
            }
        } message: { _ in
            Text("This PDF comes from a scanned document. Choose conversion mode:\n\n• Extracted OCR (lower visual quality, editable text)\n• Visual quality (higher fidelity, image-based, non-editable text)")
        }
        .alert("Secure Upload Required", isPresented: $showServerUploadConsent, presenting: pendingConsentDocument) { doc in
            Button("Continue Once") {
                let mode = pendingConsentMode
                pendingConsentDocument = nil
                performConversion(for: doc, mode: mode)
            }
            Button("Always Allow") {
                alwaysAllowServerConversionUpload = true
                let mode = pendingConsentMode
                pendingConsentDocument = nil
                performConversion(for: doc, mode: mode)
            }
            Button("Cancel", role: .cancel) {
                pendingConsentDocument = nil
            }
        } message: { _ in
            Text(
                "This file will be securely uploaded to the conversion server for processing.\n\n" +
                "\(ConversionPrivacyPolicy.uploadedDataDescription)\n" +
                "\(ConversionPrivacyPolicy.serverRetentionDescription)\n" +
                "\(ConversionPrivacyPolicy.authScopeDescription)"
            )
        }
        .alert("Conversion Failed", isPresented: $showConversionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(conversionErrorMessage ?? "Unknown error")
        }
    }

    private func startConversion() {
        AppLogger.conversion.debug("startConversion: selectedId=\(selectedId?.uuidString ?? "nil")")
        guard NetworkMonitor.shared.isConnected else {
            conversionErrorMessage = "No internet connection. File conversion requires a server connection."
            showConversionError = true
            return
        }
        guard let document = selectedDocument else {
            AppLogger.conversion.error("startConversion: selectedDocument is nil — no document selected")
            return
        }
        let sourceFormat = conversionFormatFromDocumentType(document.type)
        AppLogger.conversion.debug("startConversion: doc=\(document.title) sourceFormat=\(String(describing: sourceFormat)) targetFormat=\(String(describing: targetFormat))")

        if sourceFormat == .pdf,
           isOfficeTarget(targetFormat),
           isScannedPDFSource(document) {
            AppLogger.conversion.debug("startConversion: scanned PDF detected — showing choice sheet")
            pendingScannedChoiceDocument = document
            showScannedPDFChoice = true
            return
        }

        requestConsentOrConvert(for: document, mode: .ocrEditable)
    }

    private func requestConsentOrConvert(for document: Document, mode: PDFToOfficeMode) {
        let sourceFormat = conversionFormatFromDocumentType(document.type)
        let needsUpload = requiresServerUpload(sourceFormat: sourceFormat, targetFormat: targetFormat, mode: mode)
        AppLogger.conversion.debug("requestConsentOrConvert: needsServerUpload=\(needsUpload) alwaysAllow=\(alwaysAllowServerConversionUpload) libreOfficeMode=\(useLibreOfficeEngine)")
        if needsUpload, !alwaysAllowServerConversionUpload, !useLibreOfficeEngine {
            AppLogger.conversion.debug("requestConsentOrConvert: showing consent alert")
            pendingConsentDocument = document
            pendingConsentMode = mode
            showServerUploadConsent = true
            return
        }
        performConversion(for: document, mode: mode)
    }

    private func performConversion(for document: Document, mode: PDFToOfficeMode) {
        AppLogger.conversion.debug("performConversion: starting for doc=\(document.title) mode=\(String(describing: mode))")
        isConverting = true
        if !isGlobalLoadingActive {
            GlobalLoadingBridge.setOperationLoading(true)
            isGlobalLoadingActive = true
        }

        let sourceFormat = conversionFormatFromDocumentType(document.type)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = convertDocument(
                documentManager: documentManager,
                document: document,
                from: sourceFormat,
                to: targetFormat,
                pdfToOfficeMode: mode
            )
            DispatchQueue.main.async {
                isConverting = false
                if result.success {
                    AppLogger.conversion.debug("performConversion: success")
                    saveConversionResult(
                        result: result,
                        documentManager: documentManager,
                        sourceFormat: sourceFormat,
                        sourceDocument: document
                    ) {
                        GlobalLoadingBridge.showOperationSuccess()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                            if isGlobalLoadingActive {
                                GlobalLoadingBridge.setOperationLoading(false)
                                isGlobalLoadingActive = false
                            }
                            dismiss()
                        }
                    }
                } else {
                    AppLogger.conversion.error("performConversion: failed — \(result.message)")
                    if isGlobalLoadingActive {
                        GlobalLoadingBridge.setOperationLoading(false)
                        isGlobalLoadingActive = false
                    }
                    conversionErrorMessage = result.message
                    showConversionError = true
                }
            }
        }
    }

    private func requiresServerUpload(sourceFormat: ConversionView.DocumentFormat, targetFormat: ConversionView.DocumentFormat, mode: PDFToOfficeMode) -> Bool {
        switch (sourceFormat, targetFormat) {
        case (.docx, .pdf),
             (.pptx, .pdf),
             (.xlsx, .pdf),
             (.pdf, .pptx),
             (.pdf, .xlsx):
            return true
        case (.pdf, .docx):
            return mode == .ocrEditable
        default:
            return false
        }
    }

    private func isScannedPDFSource(_ document: Document) -> Bool {
        var current: Document? = document
        var visited = Set<UUID>()
        while let doc = current, !visited.contains(doc.id) {
            visited.insert(doc.id)
            if doc.type == .scanned {
                return true
            }
            guard let sourceId = doc.sourceDocumentId,
                  let next = documentManager.getDocument(by: sourceId) else {
                break
            }
            current = next
        }
        return false
    }

    private func isOfficeTarget(_ format: ConversionView.DocumentFormat) -> Bool {
        format == .docx || format == .pptx || format == .xlsx
    }
}

enum ConvertIconType {
    case pdfToDocx
    case pdfToPptx
    case pdfToXlsx
    case pdfToJpg
    case docxToPdf
    case pptxToPdf
    case xlsxToPdf
    case jpgToPdf
}

struct ConvertIcon: View {
    let type: ConvertIconType

    var body: some View {
        switch type {
        case .pdfToDocx:
            pdfToDocxIcon
        case .pdfToPptx:
            pdfToPptxIcon
        case .pdfToXlsx:
            pdfToXlsxIcon
        case .pdfToJpg:
            pdfToJpgIcon
        case .docxToPdf:
            docxToPdfIcon
        case .pptxToPdf:
            pptxToPdfIcon
        case .xlsxToPdf:
            xlsxToPdfIcon
        case .jpgToPdf:
            jpgToPdfIcon
        }
    }

    private var pdfToDocxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 8, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToPptxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToXlsxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "tablecells")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToJpgIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var docxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pptxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var xlsxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "tablecells.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var jpgToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "photo.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
}

struct ConvertSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

#Preview {
  ConvertView()
}

