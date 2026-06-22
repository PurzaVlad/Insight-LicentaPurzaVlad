import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

struct CropPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var didAutoPresent = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var workingPDF: PDFDocument?
    @State private var currentPageIndex = 0
    @State private var cropValuesByPage: [Int: PageCropValues] = [:]
    @State private var isCropMode = false
    @State private var pdfRefreshTrigger = 0

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

    private var pageCount: Int { workingPDF?.pageCount ?? 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if selectedDocument != nil, let pdf = workingPDF {
                CropScrollPDFRepresentable(
                    pdf: pdf,
                    currentPageIndex: $currentPageIndex,
                    isCropMode: isCropMode,
                    cropValues: Binding(
                        get: { cropValuesByPage[currentPageIndex] ?? .zero },
                        set: { cropValuesByPage[currentPageIndex] = $0 }
                    ),
                    refreshTrigger: pdfRefreshTrigger
                )
                .ignoresSafeArea(edges: .horizontal)

                if !isCropMode { bottomBar }
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("Primary"))
                        .padding()
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
        .navigationTitle(isCropMode ? "Page \(currentPageIndex + 1)" : "Crop PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isCropMode {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        applyVisualCropAndExit()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("Primary"))
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isSaving ? "Cropping..." : "Save") {
                        saveCroppedPDF()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color("Primary"))
                    .disabled(selectedDocument == nil || workingPDF == nil || isSaving)
                }
                if allowsPicker, selectedDocument != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Change") { showingPicker = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async { showingPicker = true }
            }
            if selectedDocument != nil && workingPDF == nil {
                loadDocument(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadDocument(for: newDoc)
        }
        .alert("Crop PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(currentPageIndex + 1) of \(pageCount)")
                    .font(.subheadline.weight(.medium))
                if let crop = cropValuesByPage[currentPageIndex],
                   crop.topFraction > 0 || crop.bottomFraction > 0 ||
                   crop.leftFraction > 0 || crop.rightFraction > 0 {
                    Text("Crop applied")
                        .font(.caption)
                        .foregroundColor(Color("Primary"))
                }
            }
            Spacer()
            Button {
                enterCropMode()
            } label: {
                Image(systemName: "crop")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("Primary"))
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func enterCropMode() {
        guard workingPDF != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isCropMode = true }
    }

    private func applyVisualCropAndExit() {
        // Update the workingPDF page bounds so the PDFView reflects the crop immediately.
        // saveCroppedPDF() always reloads from the original source data, so this is purely visual.
        if let pdf = workingPDF,
           currentPageIndex < pdf.pageCount,
           let page = pdf.page(at: currentPageIndex) {
            let mediaBox = page.bounds(for: .mediaBox)
            let cv = cropValuesByPage[currentPageIndex] ?? .zero
            let insets = cv.absoluteInsets(in: mediaBox)
            var cropRect = mediaBox.inset(by: insets)
            if cropRect.width < 8 || cropRect.height < 8 { cropRect = mediaBox }
            page.setBounds(cropRect, for: .cropBox)
            pdfRefreshTrigger += 1
        }
        withAnimation(.easeInOut(duration: 0.2)) { isCropMode = false }
    }

    private func loadDocument(for document: Document?) {
        cropValuesByPage.removeAll()
        currentPageIndex = 0
        guard let document,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else {
            workingPDF = nil
            return
        }
        workingPDF = pdf
        for index in 0..<pdf.pageCount {
            cropValuesByPage[index] = .zero
        }
    }

    private func saveCroppedPDF() {
        guard let document = selectedDocument,
              let sourceData = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: sourceData) else {
            alertMessage = "Please choose a valid PDF first."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let cropValues = cropValuesByPage

        let workItem = DispatchWorkItem {
            let croppedPDF = PDFDocument()
            for index in 0..<pdf.pageCount {
                guard let sourcePage = pdf.page(at: index),
                      let copiedPage = sourcePage.copy() as? PDFPage else { continue }

                let mediaBox = copiedPage.bounds(for: .mediaBox)
                let cropValuesForPage = cropValues[index] ?? .zero
                let insets = cropValuesForPage.absoluteInsets(in: mediaBox)
                var cropRect = mediaBox.inset(by: insets)
                if cropRect.width < 8 || cropRect.height < 8 { cropRect = mediaBox }

                copiedPage.setBounds(cropRect, for: .cropBox)
                croppedPDF.insert(copiedPage, at: croppedPDF.pageCount)
            }
            guard let outData = croppedPDF.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to crop PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_cropped"
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
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Cropped PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

// MARK: - Scrollable PDF + UIKit crop overlay

private struct CropScrollPDFRepresentable: UIViewRepresentable {
    let pdf: PDFDocument
    @Binding var currentPageIndex: Int
    let isCropMode: Bool
    @Binding var cropValues: PageCropValues
    let refreshTrigger: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.systemBackground

        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.backgroundColor = UIColor.systemBackground
        pdfView.document = pdf
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.pdfView = pdfView
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        DispatchQueue.main.async {
            let fit = pdfView.scaleFactorForSizeToFit
            if fit > 0 {
                pdfView.scaleFactor = fit
                pdfView.minScaleFactor = fit * 0.5
                pdfView.maxScaleFactor = fit * 6.0
            }
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let pdfView = context.coordinator.pdfView else { return }

        if pdfView.document !== pdf {
            pdfView.document = pdf
            DispatchQueue.main.async {
                let fit = pdfView.scaleFactorForSizeToFit
                if fit > 0 {
                    pdfView.scaleFactor = fit
                    pdfView.minScaleFactor = fit * 0.5
                    pdfView.maxScaleFactor = fit * 6.0
                }
            }
        }

        if context.coordinator.lastRefreshTrigger != refreshTrigger {
            context.coordinator.lastRefreshTrigger = refreshTrigger
            pdfView.layoutDocumentView()
        }

        if isCropMode && !context.coordinator.isCropMode {
            // Lock the crop target to the page visible when entering crop mode
            context.coordinator.lockedPageIndex = currentPageIndex
            context.coordinator.startTrackingOverlay(in: uiView)
        } else if !isCropMode && context.coordinator.isCropMode {
            context.coordinator.stopTrackingOverlay()
        }
        context.coordinator.isCropMode = isCropMode

        if isCropMode {
            // Ensure overlay exists
            if context.coordinator.cropOverlay == nil {
                let overlay = CropOverlayView()
                overlay.translatesAutoresizingMaskIntoConstraints = false
                uiView.addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.leadingAnchor.constraint(equalTo: uiView.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: uiView.trailingAnchor),
                    overlay.topAnchor.constraint(equalTo: uiView.topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: uiView.bottomAnchor)
                ])
                context.coordinator.cropOverlay = overlay
            }
            let overlay = context.coordinator.cropOverlay!
            overlay.cropValues = cropValues
            overlay.onCropChanged = { newValues in
                context.coordinator.parent.cropValues = newValues
            }
            overlay.setNeedsDisplay()
        } else {
            context.coordinator.cropOverlay?.removeFromSuperview()
            context.coordinator.cropOverlay = nil
        }
    }

    final class Coordinator: NSObject {
        var parent: CropScrollPDFRepresentable
        weak var pdfView: PDFView?
        var cropOverlay: CropOverlayView?
        var lastRefreshTrigger = 0
        var isCropMode = false
        var lockedPageIndex: Int = 0
        private var displayLink: CADisplayLink?

        init(_ parent: CropScrollPDFRepresentable) { self.parent = parent }

        func startTrackingOverlay(in container: UIView) {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(updateOverlayFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopTrackingOverlay() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc func updateOverlayFrame() {
            guard let pdfView = pdfView,
                  let doc = pdfView.document,
                  let page = doc.page(at: lockedPageIndex),
                  let overlay = cropOverlay else { return }
            // pdfView and overlay share the same coordinate space (both fill the container)
            let frame = pdfView.convert(page.bounds(for: .cropBox), from: page)
            if frame != overlay.pageFrame {
                overlay.pageFrame = frame
                overlay.setNeedsDisplay()
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            guard !isCropMode,
                  let pdfView = notification.object as? PDFView,
                  let currentPage = pdfView.currentPage,
                  let doc = pdfView.document else { return }
            let index = doc.index(for: currentPage)
            DispatchQueue.main.async {
                self.parent.currentPageIndex = index
            }
        }
    }
}

// MARK: - UIKit crop overlay — passes through touches outside the crop zone

private final class CropOverlayView: UIView {
    var pageFrame: CGRect = .zero
    var cropValues: PageCropValues = .zero
    var onCropChanged: ((PageCropValues) -> Void)?

    private let hitSize: CGFloat = 44
    private let handleLen: CGFloat = 22
    private let minKeep: Double = 0.08

    private var dragAction: DragAction = .none
    private var dragStartCrop: PageCropValues = .zero

    private enum DragAction { case none, topLeft, topRight, bottomLeft, bottomRight, interior }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Only capture touches on corners or inside crop zone — everything else falls through to PDFView
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let keep = keepRect
        let h = hitSize / 2
        let corners = [
            CGRect(x: keep.minX - h, y: keep.minY - h, width: hitSize, height: hitSize),
            CGRect(x: keep.maxX - h, y: keep.minY - h, width: hitSize, height: hitSize),
            CGRect(x: keep.minX - h, y: keep.maxY - h, width: hitSize, height: hitSize),
            CGRect(x: keep.maxX - h, y: keep.maxY - h, width: hitSize, height: hitSize)
        ]
        for r in corners { if r.contains(point) { return self } }
        if keep.contains(point) { return self }
        return nil  // fall through to PDFView → pinch zoom / scroll work naturally
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragStartCrop = cropValues
            dragAction = actionFor(point: g.location(in: self))
        case .changed:
            guard dragAction != .none, pageFrame.width > 0, pageFrame.height > 0 else { return }
            let t = g.translation(in: self)
            let dx = t.x / pageFrame.width
            let dy = t.y / pageFrame.height
            var cv = dragStartCrop
            switch dragAction {
            case .topLeft:
                cv.leftFraction = (dragStartCrop.leftFraction + dx).clamped(to: 0...(1 - dragStartCrop.rightFraction - minKeep))
                cv.topFraction  = (dragStartCrop.topFraction  + dy).clamped(to: 0...(1 - dragStartCrop.bottomFraction - minKeep))
            case .topRight:
                cv.rightFraction = (dragStartCrop.rightFraction - dx).clamped(to: 0...(1 - dragStartCrop.leftFraction   - minKeep))
                cv.topFraction   = (dragStartCrop.topFraction   + dy).clamped(to: 0...(1 - dragStartCrop.bottomFraction - minKeep))
            case .bottomLeft:
                cv.leftFraction   = (dragStartCrop.leftFraction   + dx).clamped(to: 0...(1 - dragStartCrop.rightFraction - minKeep))
                cv.bottomFraction = (dragStartCrop.bottomFraction - dy).clamped(to: 0...(1 - dragStartCrop.topFraction   - minKeep))
            case .bottomRight:
                cv.rightFraction  = (dragStartCrop.rightFraction  - dx).clamped(to: 0...(1 - dragStartCrop.leftFraction  - minKeep))
                cv.bottomFraction = (dragStartCrop.bottomFraction - dy).clamped(to: 0...(1 - dragStartCrop.topFraction   - minKeep))
            case .interior:
                let nl = (dragStartCrop.leftFraction   + dx).clamped(to: 0...1)
                let nr = (dragStartCrop.rightFraction  - dx).clamped(to: 0...1)
                let nt = (dragStartCrop.topFraction    + dy).clamped(to: 0...1)
                let nb = (dragStartCrop.bottomFraction - dy).clamped(to: 0...1)
                guard nl + nr <= 1 - minKeep, nt + nb <= 1 - minKeep else { return }
                cv.leftFraction = nl; cv.rightFraction = nr
                cv.topFraction  = nt; cv.bottomFraction = nb
            case .none: return
            }
            cv.clamp()
            cropValues = cv
            onCropChanged?(cv)
            setNeedsDisplay()
        case .ended, .cancelled:
            dragAction = .none
        default: break
        }
    }

    private func actionFor(point: CGPoint) -> DragAction {
        let keep = keepRect; let h = hitSize / 2
        if CGRect(x: keep.minX - h, y: keep.minY - h, width: hitSize, height: hitSize).contains(point) { return .topLeft }
        if CGRect(x: keep.maxX - h, y: keep.minY - h, width: hitSize, height: hitSize).contains(point) { return .topRight }
        if CGRect(x: keep.minX - h, y: keep.maxY - h, width: hitSize, height: hitSize).contains(point) { return .bottomLeft }
        if CGRect(x: keep.maxX - h, y: keep.maxY - h, width: hitSize, height: hitSize).contains(point) { return .bottomRight }
        if keep.contains(point) { return .interior }
        return .none
    }

    private var keepRect: CGRect {
        CGRect(
            x: pageFrame.minX + pageFrame.width  * cropValues.leftFraction,
            y: pageFrame.minY + pageFrame.height * cropValues.topFraction,
            width:  max(1, pageFrame.width  * (1 - cropValues.leftFraction - cropValues.rightFraction)),
            height: max(1, pageFrame.height * (1 - cropValues.topFraction  - cropValues.bottomFraction))
        )
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), pageFrame.width > 0 else { return }
        let keep = keepRect

        // Dim outside keepRect
        ctx.saveGState()
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.50).cgColor)
        ctx.addRect(rect); ctx.addRect(keep)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        // Grid 3×3
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(0.5)
        let tw = keep.width / 3; let th = keep.height / 3
        for i in 1...2 {
            ctx.move(to: CGPoint(x: keep.minX + tw * CGFloat(i), y: keep.minY))
            ctx.addLine(to: CGPoint(x: keep.minX + tw * CGFloat(i), y: keep.maxY))
            ctx.move(to: CGPoint(x: keep.minX, y: keep.minY + th * CGFloat(i)))
            ctx.addLine(to: CGPoint(x: keep.maxX, y: keep.minY + th * CGFloat(i)))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Border
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(keep)
        ctx.restoreGState()

        // Corner L-handles
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(3); ctx.setLineCap(.round)
        for (cx, cy, hd, vd): (CGFloat, CGFloat, CGFloat, CGFloat) in [
            (keep.minX, keep.minY,  1,  1), (keep.maxX, keep.minY, -1,  1),
            (keep.minX, keep.maxY,  1, -1), (keep.maxX, keep.maxY, -1, -1)
        ] {
            ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + hd * handleLen, y: cy))
            ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy + vd * handleLen))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

private struct PageCropValues {
    var topFraction: Double = 0
    var bottomFraction: Double = 0
    var leftFraction: Double = 0
    var rightFraction: Double = 0

    static let zero = PageCropValues()

    mutating func clamp() {
        topFraction = min(max(0, topFraction), 0.45)
        bottomFraction = min(max(0, bottomFraction), 0.45)
        leftFraction = min(max(0, leftFraction), 0.45)
        rightFraction = min(max(0, rightFraction), 0.45)

        if topFraction + bottomFraction > 0.9 {
            let scale = 0.9 / (topFraction + bottomFraction)
            topFraction *= scale
            bottomFraction *= scale
        }
        if leftFraction + rightFraction > 0.9 {
            let scale = 0.9 / (leftFraction + rightFraction)
            leftFraction *= scale
            rightFraction *= scale
        }
    }

    func absoluteInsets(in bounds: CGRect) -> UIEdgeInsets {
        UIEdgeInsets(
            top: bounds.height * topFraction,
            left: bounds.width * leftFraction,
            bottom: bounds.height * bottomFraction,
            right: bounds.width * rightFraction
        )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Rotate

struct RotatePDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [RotatePageItem] = []
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

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
        VStack(spacing: 12) {
            if let document = selectedDocument {
                HStack {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if allowsPicker {
                        Button("Change") { showingPicker = true }
                    }
                }
                .padding(.horizontal)
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }

            if !pageItems.isEmpty {
                List {
                    ForEach(pageItems.indices, id: \.self) { idx in
                        HStack(spacing: 12) {
                            Image(uiImage: rotatedThumbnail(for: pageItems[idx]))
                                .resizable()
                                .scaledToFit()
                                .frame(height: 70)
                                .cornerRadius(6)
                            Text("Page \(pageItems[idx].index + 1)")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                rotatePage(at: idx, delta: -90)
                            } label: {
                                Image(systemName: "rotate.left")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            Button {
                                rotatePage(at: idx, delta: 90)
                            } label: {
                                Image(systemName: "rotate.right")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .hideScrollBackground()
            }
        }
        .navigationTitle("Rotate PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Rotating..." : "Rotate") {
                    saveRotations()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocument == nil || pageItems.isEmpty || isSaving)
            }
        }
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async {
                    showingPicker = true
                }
            }
            if selectedDocument != nil && pageItems.isEmpty {
                loadPages(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadPages(for: newDoc)
        }
        .alert("Rotate PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func loadPages(for document: Document?) {
        pageItems.removeAll()
        guard let document,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else { return }

        var items: [RotatePageItem] = []
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index) {
                let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                let rotation = page.rotation
                items.append(RotatePageItem(index: index, thumbnail: thumb, rotation: rotation))
            }
        }
        pageItems = items
    }

    private func rotatePage(at index: Int, delta: Int) {
        let newRotation = (pageItems[index].rotation + delta + 360) % 360
        pageItems[index].rotation = newRotation
    }

    private func rotatedThumbnail(for item: RotatePageItem) -> UIImage {
        guard item.rotation % 360 != 0 else { return item.thumbnail }
        let radians = CGFloat(item.rotation) * .pi / 180
        let size = item.thumbnail.size
        let isQuarterTurn = (item.rotation / 90) % 2 != 0
        let newSize = isQuarterTurn ? CGSize(width: size.height, height: size.width) : size

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: radians)
            ctx.cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            item.thumbnail.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func saveRotations() {
        guard let document = selectedDocument,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else { return }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            for item in pageItems {
                if let page = pdf.page(at: item.index) {
                    page.rotation = item.rotation
                }
            }

            guard let outData = pdf.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to save rotated PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_rotated"
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
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Rotated PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct RotatePageItem: Identifiable {
    let id = UUID()
    let index: Int
    let thumbnail: UIImage
    var rotation: Int
}

// MARK: - Pickers

struct PDFSinglePickerSheet: View {
    let documents: [Document]
    @Binding var selectedDocument: Document?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if documents.isEmpty {
                    Text("No PDFs available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(documents) { document in
                        Button {
                            selectedDocument = document
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: iconForDocumentType(document.type))
                                    .foregroundColor(Color("Primary"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedDocument?.id == document.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color("Primary"))
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.primary)
                }
            }
        }
    }
}

struct PDFMultiPickerSheet: View {
    let documents: [Document]
    @Binding var selectedIds: Set<UUID>
    let maxSelection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if documents.isEmpty {
                    Text("No PDFs available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(documents) { document in
                        Button {
                            toggleSelection(for: document.id)
                        } label: {
                            HStack {
                                Image(systemName: iconForDocumentType(document.type))
                                    .foregroundColor(Color("Primary"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedIds.contains(document.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color("Primary"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < maxSelection {
            selectedIds.insert(id)
        }
    }
}

