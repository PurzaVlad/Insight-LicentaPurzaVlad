import SwiftUI
import UIKit
import PDFKit
import OSLog

struct OldDocumentPreviewView: View {
    let document: Document
    @EnvironmentObject private var documentManager: DocumentManager
    @Binding var showingDocumentInfo: Bool
    @State private var isGeneratingSummary = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Document Preview
            Group {
                if let pdfData = documentManager.pdfData(for: document.id) {
                    // PDF first page preview
                    PDFFirstPageView(data: pdfData)
                        .background(Color(.systemBackground))

                } else if let imageDataArray = documentManager.imageData(for: document.id),
                          !imageDataArray.isEmpty,
                          let firstImageData = imageDataArray.first,
                          let uiImage = UIImage(data: firstImageData) {
                    // First scanned page preview
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color(.systemBackground))
                    
                } else {
                    // Text document preview
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(document.content.prefix(500) + (document.content.count > 500 ? "..." : ""))
                                .font(.body)
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                    .background(Color(.systemBackground))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Document Info") {
                        showingDocumentInfo = true
                    }
                    
                    if document.type != .image {
                        Button("Generate AI Summary") {
                            generateAISummary()
                        }
                    }
                    
                    if documentManager.imageData(for: document.id) != nil || documentManager.pdfData(for: document.id) != nil {
                        Button("Full View") {
                            // Navigate to full document view - would need NavigationLink here
                        }
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showingDocumentInfo) {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    // Document Information
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Document Information")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        InfoRow(label: "Name", value: document.title)
                        InfoRow(label: "Date Added", value: DateFormatter.shortDate.string(from: document.dateCreated))
                        InfoRow(label: "Source", value: document.type == .scanned ? "Scanned" : "Manually Added")
                        InfoRow(label: "Type", value: document.type.rawValue)

                        if let imageData = documentManager.imageData(for: document.id) {
                            InfoRow(label: "Pages", value: "\(imageData.count)")
                        }
                        
                        if !document.content.isEmpty {
                            InfoRow(label: "Content Length", value: "\(document.content.count) characters")
                        }
                    }
                    
                    Divider()
                    
                    // Content Preview
                    if !document.content.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Content Preview")
                                .font(.headline)
                            
                            Text(document.content.prefix(200) + (document.content.count > 200 ? "..." : ""))
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("Document Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingDocumentInfo = false
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                // AI Summary Button
                if document.type != .image {
                    Button(action: {
                        generateAISummary()
                    }) {
                        HStack {
                            if isGeneratingSummary {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                            } else {
                                Image(systemName: "brain.head.profile")
                            }
                            Text(isGeneratingSummary ? "Generating..." : "AI Summary")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.blue)
                        .clipShape(Capsule())
                    }
                    .disabled(isGeneratingSummary)
                }
            }
            .padding()
        }
    }
    
    private func generateAISummary() {
        AppLogger.ui.debug("OldDocumentPreviewView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        documentManager.generateSummary(for: document, force: true)
    }

    private var tagsText: String {
        let tags = document.tags
        if tags.isEmpty { return "None" }
        return tags.joined(separator: ", ")
    }
}

// MARK: - Helper Views
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.body)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

struct PDFFirstPageView: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.displayMode = .singlePage
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(true)
        pdfView.pageShadowsEnabled = false
        pdfView.isUserInteractionEnabled = false  // Disable interaction for preview
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data {
            uiView.document = PDFDocument(data: data)
        }
        // Always show first page
        if let document = uiView.document, let firstPage = document.page(at: 0) {
            uiView.go(to: firstPage)
        }
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct PDFViewRepresentable: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.autoScales = false  // Disable auto scaling to control it manually
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor.systemBackground
        
        // Set initial scale to fit width
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfView.minScaleFactor = fitScale * 0.9  // Allow slight zoom out
            pdfView.maxScaleFactor = fitScale * 4.0  // Allow zoom in up to 4x
        }
        
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Ensure proper scaling is maintained
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor < fitScale * 0.9 {
                pdfView.scaleFactor = fitScale
            }
            // Update min scale factor in case view size changed
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }
    }
}

struct SearchablePDFView: UIViewRepresentable {
    let url: URL
    /// Kept for API compatibility; the native find bar handles search internally.
    @Binding var searchQuery: String
    @Binding var searchRequestID: Int
    @Binding var nextRequestID: Int
    @Binding var previousRequestID: Int
    @Binding var matchSummary: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor.systemBackground
        pdfView.tintColor = primaryTintColor()
        pdfView.usePageViewController(false)

        // Enable the native iOS find bar (UIFindInteraction) on the PDFView.
        pdfView.isFindInteractionEnabled = true

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        } else {
            do {
                let data = try Data(contentsOf: url)
                if let document = PDFDocument(data: data) {
                    pdfView.document = document
                }
            } catch {
                AppLogger.ui.error("Failed to read PDF data from URL: \(error.localizedDescription)")
            }
        }

        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }

        context.coordinator.attach(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(pdfView)
        pdfView.tintColor = primaryTintColor()
        applyPrimaryTint(to: pdfView)

        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor < fitScale * 0.9 {
                pdfView.scaleFactor = fitScale
            }
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }
    }

    final class Coordinator {
        var parent: SearchablePDFView
        weak var pdfView: PDFView?
        var onPageChanged: ((Int, Int) -> Void)?
        private var pageChangeObserver: NSObjectProtocol?
        private var retintTimer: Timer?

        init(parent: SearchablePDFView) {
            self.parent = parent
        }

        func attach(_ pdfView: PDFView) {
            if self.pdfView !== pdfView {
                if let pageChangeObserver {
                    NotificationCenter.default.removeObserver(pageChangeObserver)
                    self.pageChangeObserver = nil
                }
                self.pdfView = pdfView
                pageChangeObserver = NotificationCenter.default.addObserver(
                    forName: Notification.Name.PDFViewPageChanged,
                    object: pdfView,
                    queue: .main
                ) { [weak self] _ in
                    self?.emitPageState()
                }
            } else {
                self.pdfView = pdfView
            }
            emitPageState()
        }

        /// Present the native system find panel.
        func presentFindNavigator() {
            guard let pdfView else { return }
            pdfView.tintColor = primaryTintColor()
            applyPrimaryTint(to: pdfView)
            pdfView.findInteraction.presentFindNavigator(showingReplace: false)
            startRetintTimer()
        }

        private func startRetintTimer() {
            retintTimer?.invalidate()
            var count = 0
            retintTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] timer in
                guard let self, let pdfView = self.pdfView else { timer.invalidate(); return }
                retintNativeFindNavigator(from: pdfView)
                count += 1
                if count >= 25 { timer.invalidate() } // ~2 seconds total
            }
        }

        /// Dismiss the native system find panel.
        func dismissFindNavigator() {
            retintTimer?.invalidate()
            retintTimer = nil
            guard let pdfView else { return }
            pdfView.findInteraction.dismissFindNavigator()
        }

        private func emitPageState() {
            guard let pdfView,
                  let document = pdfView.document,
                  let page = pdfView.currentPage else {
                onPageChanged?(0, 0)
                return
            }
            onPageChanged?(document.index(for: page) + 1, document.pageCount)
        }

        deinit {
            retintTimer?.invalidate()
            if let pageChangeObserver {
                NotificationCenter.default.removeObserver(pageChangeObserver)
            }
        }
    }
}

/// Thin wrapper around `SearchablePDFView` that exposes the coordinator
/// so the container can call `presentFindNavigator()` from its toolbar.
struct SearchablePDFPreviewView: UIViewRepresentable {
    let url: URL
    let onCoordinatorReady: (SearchablePDFView.Coordinator) -> Void

    func makeCoordinator() -> SearchablePDFView.Coordinator {
        SearchablePDFView.Coordinator(parent: SearchablePDFView(
            url: url,
            searchQuery: .constant(""),
            searchRequestID: .constant(0),
            nextRequestID: .constant(0),
            previousRequestID: .constant(0),
            matchSummary: .constant("")
        ))
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor.systemBackground
        pdfView.tintColor = primaryTintColor()
        pdfView.usePageViewController(false)

        // Enable the native iOS find bar (UIFindInteraction).
        pdfView.isFindInteractionEnabled = true

        if let document = PDFDocument(url: url) {
            pdfView.document = document
        } else {
            do {
                let data = try Data(contentsOf: url)
                if let document = PDFDocument(data: data) {
                    pdfView.document = document
                }
            } catch {
                AppLogger.ui.error("Failed to read PDF data from URL for preview: \(error.localizedDescription)")
            }
        }

        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }

        context.coordinator.attach(pdfView)
        DispatchQueue.main.async {
            self.onCoordinatorReady(context.coordinator)
        }
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.tintColor = primaryTintColor()
        applyPrimaryTint(to: pdfView)
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor < fitScale * 0.9 {
                pdfView.scaleFactor = fitScale
            }
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }
    }
}

private func primaryTintColor() -> UIColor {
    UIColor(Color("Primary"))
}

private func applyPrimaryTint(to view: UIView) {
    let tint = primaryTintColor()
    view.tintColor = tint

    var current: UIView? = view
    while let host = current {
        host.tintColor = tint
        current = host.superview
    }

    if let window = view.window {
        window.tintColor = tint
        window.rootViewController?.view.tintColor = tint
    }
}

private func retintNativeFindNavigator(from sourceView: UIView) {
    guard let windowScene = sourceView.window?.windowScene else { return }
    let tint = primaryTintColor()
    for window in windowScene.windows {
        window.tintColor = tint
        retintFindViews(in: window, inFindContext: false)
    }
}

private func retintFindViews(in view: UIView, inFindContext: Bool) {
    let typeName = String(describing: type(of: view)).lowercased()
    let nowInFindContext = inFindContext
        || typeName.contains("find")
        || typeName.contains("search")
        || typeName.contains("navigator")
        || typeName.contains("panel")

    if nowInFindContext {
        let tint = primaryTintColor()
        view.tintColor = tint

        if let textField = view as? UITextField {
            textField.tintColor = tint
        } else if let searchBar = view as? UISearchBar {
            searchBar.tintColor = tint
            if let searchField = searchBar.searchTextField as UITextField? {
                searchField.tintColor = tint
            }
        }
    }

    for subview in view.subviews {
        retintFindViews(in: subview, inFindContext: nowInFindContext)
    }
}

