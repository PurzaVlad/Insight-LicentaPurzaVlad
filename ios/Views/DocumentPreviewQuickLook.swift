import SwiftUI
import UIKit
import QuickLook

// MARK: - QuickLook Document Preview
struct DocumentPreviewContainerView: View {
    let url: URL
    let document: Document?
    let onAISummary: (() -> Void)?
    let documentManager: DocumentManager?

    @Environment(\.dismiss) private var dismiss
    @State private var showingInfo = false
    @State private var showingSummary = false
    @State private var showingSearchSheet = false
    @State private var previewController: CustomQLPreviewController?
    @State private var pdfSearchCoordinator: SearchablePDFView.Coordinator?

    init(
        url: URL,
        document: Document? = nil,
        onAISummary: (() -> Void)? = nil,
        documentManager: DocumentManager? = nil
    ) {
        self.url = url
        self.document = document
        self.onAISummary = onAISummary
        self.documentManager = documentManager
    }

    private var usesSearchPopupForOfficeDocs: Bool {
        guard let type = document?.type else { return false }
        return type == .docx || type == .pptx
    }

    private var usesNativePDFPreview: Bool {
        if let type = document?.type {
            return type == .pdf || type == .scanned
        }
        return url.pathExtension.lowercased() == "pdf"
    }

    private var previewTitle: String {
        document.map { splitDisplayTitle($0.title).base } ?? "Preview"
    }


    // Match navigation-style dismissal: edge swipe from left to right only.
    private var edgeSwipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let fromLeftEdge = value.startLocation.x <= 28
                let horizontalMove = value.translation.width
                let verticalMove = abs(value.translation.height)
                let isRightSwipe = horizontalMove > 90
                let isMostlyHorizontal = verticalMove < 60 && abs(horizontalMove) > verticalMove

                if fromLeftEdge && isRightSwipe && isMostlyHorizontal {
                    dismiss()
                }
            }
    }

    @ToolbarContentBuilder
    private var previewBottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if document != nil {
                Button {
                    showingInfo = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            }

            Button {
                shareCurrent()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                triggerSearch()
            } label: {
                Label("Search", systemImage: "text.magnifyingglass")
            }

        }
    }

    @ToolbarContentBuilder
    private var previewTopToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .tint(.primary)
        }
        ToolbarItem(placement: .principal) {
            Text(previewTitle)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        if onAISummary != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if document != nil, documentManager != nil {
                        showingSummary = true
                    } else {
                        onAISummary?()
                    }
                } label: {
                    Label("AI Summary", systemImage: "brain.head.profile")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if usesNativePDFPreview {
                    SearchablePDFPreviewView(url: url) { coordinator in
                        pdfSearchCoordinator = coordinator
                    }
                    .ignoresSafeArea()
                } else {
                    DocumentPreviewNavControllerView(
                        url: url,
                        title: previewTitle,
                        onControllerReady: { controller in
                            previewController = controller
                        }
                    )
                    .ignoresSafeArea()
                }
            }
            .navigationTitle(previewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                previewTopToolbar
                previewBottomToolbar
            }
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .bottomBar)
            .toolbarBackground(.visible, for: .bottomBar)
        }
        .interactiveDismissDisabled(true)
        .simultaneousGesture(edgeSwipeToDismiss)
        .sheet(isPresented: $showingInfo) {
            if let doc = document, let manager = documentManager {
                DocumentInsightsView(document: doc, fileURL: url)
                    .environmentObject(manager)
            }
        }
        .sheet(isPresented: $showingSummary) {
            if let doc = document, let manager = documentManager {
                DocumentSummaryView(document: doc)
                    .environmentObject(manager)
            }
        }
        .sheet(isPresented: $showingSearchSheet) {
            if let doc = document {
                SearchInDocumentSheet(document: doc)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
    
    private func triggerSearch() {
        if usesSearchPopupForOfficeDocs, document != nil {
            showingSearchSheet = true
            return
        }

        if usesNativePDFPreview {
            if let pdfSearchCoordinator {
                pdfSearchCoordinator.presentFindNavigator()
            } else {
                UIApplication.shared.sendAction(#selector(UIResponder.find(_:)), to: nil, from: nil, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pdfSearchCoordinator?.presentFindNavigator()
                }
            }
            return
        }

        // Use Quick Look's native search.
        if let previewController {
            previewController.triggerSearchDirectly()
            return
        }
        UIApplication.shared.sendAction(#selector(UIResponder.find(_:)), to: nil, from: nil, for: nil)
    }

    private func shareCurrent() {
        let item = shareURLForCurrent() ?? url
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        guard let root = topMostViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activity, animated: true)
    }

    private func shareURLForCurrent() -> URL? {
        guard let document else { return nil }
        let parts = splitDisplayTitle(document.title)
        let safeBase = parts.base.replacingOccurrences(of: "/", with: "-")
        let base = safeBase.isEmpty ? "Document" : safeBase
        let ext = parts.ext.isEmpty ? fallbackExtension(for: document) : parts.ext
        let filename = parts.ext.isEmpty ? "\(base).\(ext)" : "\(base).\(parts.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        if let data = documentManager?.anyFileData(for: document.id) {
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                AppLogger.ui.error("Failed to write share file data: \(error.localizedDescription)")
            }
        }

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            AppLogger.ui.warning("Failed to read/write share data from URL: \(error.localizedDescription)")
        }

        if !document.content.isEmpty, let data = document.content.data(using: .utf8) {
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                AppLogger.ui.error("Failed to write share content data: \(error.localizedDescription)")
            }
        }

        return nil
    }


    private func fallbackExtension(for document: Document) -> String {
        switch document.type {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .xls: return "xls"
        case .xlsx: return "xlsx"
        case .text: return "txt"
        case .scanned: return "pdf"
        case .image: return "jpg"
        case .zip: return "zip"
        }
    }

    private func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        guard let window = scene.windows.first(where: { $0.isKeyWindow }) else { return nil }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

}

struct SearchInDocumentSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [String] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if document.content.isEmpty {
                    Text("No text content available for this document.")
                        .foregroundColor(.secondary)
                        .padding()
                } else if results.isEmpty && !query.isEmpty {
                    Text("No matches found.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    List(results, id: \.self) { snippet in
                        Text(snippet)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    .listStyle(.plain)
                }

                Spacer()
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find in document"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("Primary"))
                }
            }
            .onChange(of: query) { _ in
                results = searchSnippets(in: document.content, query: query)
            }
            .onAppear {
                results = searchSnippets(in: document.content, query: query)
            }
        }
    }

    private func searchSnippets(in text: String, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        let searchTerms = tokens.isEmpty ? [trimmed.lowercased()] : tokens
        let window = 80
        var snippets: [String] = []

        for term in searchTerms.prefix(4) {
            var searchStart = lowerText.startIndex
            while snippets.count < 10,
                  let range = lowerText.range(of: term, range: searchStart..<lowerText.endIndex) {
                let start = lowerText.index(range.lowerBound, offsetBy: -window, limitedBy: lowerText.startIndex) ?? lowerText.startIndex
                let end = lowerText.index(range.upperBound, offsetBy: window, limitedBy: lowerText.endIndex) ?? lowerText.endIndex
                let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                snippets.append(snippet)
                searchStart = range.upperBound
            }
            if snippets.count >= 10 { break }
        }

        let unique = Array(NSOrderedSet(array: snippets)) as? [String] ?? snippets
        return Array(unique.prefix(10))
    }
}

struct DocumentPreviewNavControllerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onControllerReady: (CustomQLPreviewController) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let previewController = CustomQLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        
        // Notify that controller is ready
        DispatchQueue.main.async {
            self.onControllerReady(previewController)
        }
        
        return previewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
        
        // Allow search but disable editing modes
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            return .disabled
        }
        
        // Block external app opening but allow internal actions like search
        func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: QLPreviewItem) -> Bool {
            return false
        }
        
        // Remove specific unwanted toolbar items but allow search
        func previewController(_ controller: QLPreviewController, frameFor item: QLPreviewItem, inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
            return CGRect.zero
        }

    }
}

// Custom QLPreviewController to remove unwanted UI elements
class CustomQLPreviewController: QLPreviewController {
    override var canBecomeFirstResponder: Bool { true }
    
    func triggerSearchDirectly() {
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.becomeFirstResponder()

                // 1️⃣ Try UIFindInteraction on any subview first (iOS 16+).
                if self.presentFindInteractionInHierarchy(self.view) {
                    return
                }

                // 2️⃣ Fall back to the legacy responder chain approach.
                self.openFindNavigatorWithRetries(12)
            }
        }
    }

    /// Recursively look for a view with an active UIFindInteraction and present it.
    private func presentFindInteractionInHierarchy(_ root: UIView) -> Bool {
        // UIFindInteraction lives in the view's `interactions` array, not a dedicated property.
        for interaction in root.interactions {
            if let fi = interaction as? UIFindInteraction, !fi.isFindNavigatorVisible {
                fi.presentFindNavigator(showingReplace: false)
                return true
            }
        }
        for subview in root.subviews {
            if presentFindInteractionInHierarchy(subview) {
                return true
            }
        }
        return false
    }

    private func openFindNavigatorWithRetries(_ retries: Int) {
        if attemptOpenFindNavigator() { return }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.openFindNavigatorWithRetries(retries - 1)
        }
    }

    private func attemptOpenFindNavigator() -> Bool {
        let action = #selector(UIResponder.find(_:))
        if let navBar = navigationController?.navigationBar, tapSearchButtonIfPresent(in: navBar) {
            return true
        }
        if let navView = navigationController?.view, tapSearchButtonIfPresent(in: navView) {
            return true
        }
        if UIApplication.shared.sendAction(action, to: nil, from: self, for: nil) {
            return true
        }
        if let navView = navigationController?.view,
           let responder = findResponderCapableOfFind(in: navView),
           responder.canPerformAction(action, withSender: nil) {
            return UIApplication.shared.sendAction(action, to: responder, from: self, for: nil)
        }
        if let responder = findResponderCapableOfFind(in: view),
           responder.canPerformAction(action, withSender: nil) {
            return UIApplication.shared.sendAction(action, to: responder, from: self, for: nil)
        }
        return tapSearchButtonIfPresent(in: view)
    }

    private func findResponderCapableOfFind(in view: UIView) -> UIResponder? {
        if view.canPerformAction(#selector(UIResponder.find(_:)), withSender: nil) {
            return view
        }
        for subview in view.subviews {
            if let responder = findResponderCapableOfFind(in: subview) {
                return responder
            }
        }
        return nil
    }

    private func tapSearchButtonIfPresent(in view: UIView) -> Bool {
        for subview in view.subviews {
            if let button = subview as? UIButton {
                let id = (button.accessibilityIdentifier ?? "").lowercased()
                let label = (button.accessibilityLabel ?? "").lowercased()
                let typeName = String(describing: type(of: button)).lowercased()
                if id.contains("search") || label.contains("search") || typeName.contains("search") {
                    button.sendActions(for: .touchUpInside)
                    return true
                }
            }
            if tapSearchButtonIfPresent(in: subview) {
                return true
            }
        }
        return false
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
    }
}

private func topSafeAreaInset() -> CGFloat {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first else {
        return 0
    }
    return window.safeAreaInsets.top
}

extension View {
    @ViewBuilder
    func applySquareSheetCorners() -> some View {
        self.presentationCornerRadius(0)
    }
}

