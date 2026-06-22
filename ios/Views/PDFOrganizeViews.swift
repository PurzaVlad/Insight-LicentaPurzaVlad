import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers

struct MergePDFsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var orderedSelectedIds: [UUID] = []
    @State private var pickerSelectedIds: Set<UUID> = []
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedIds: [UUID] = [],
        preferredOrder: [UUID]? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete

        let initialSet = Set(preselectedIds)
        let requestedOrder = preferredOrder ?? preselectedIds
        var ordered: [UUID] = []
        var seen = Set<UUID>()
        for id in requestedOrder where initialSet.contains(id) && seen.insert(id).inserted {
            ordered.append(id)
        }
        if ordered.count < initialSet.count {
            for id in preselectedIds where initialSet.contains(id) && seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        let capped = Array(ordered.prefix(3))
        _orderedSelectedIds = State(initialValue: capped)
        _pickerSelectedIds = State(initialValue: Set(capped))
    }

    private var pdfDocuments: [Document] {
        documentManager.documents.filter { isPDFDocument($0) }
    }

    private var selectedDocuments: [Document] {
        let docsById = Dictionary(uniqueKeysWithValues: pdfDocuments.map { ($0.id, $0) })
        return orderedSelectedIds.compactMap { docsById[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedDocuments.isEmpty {
                Text("Select up to 3 PDFs to merge.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
            } else {
                List {
                    ForEach(selectedDocuments, id: \.id) { doc in
                        HStack {
                            Text(doc.title)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                removeSelection(doc.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    .onMove { indices, newOffset in
                        orderedSelectedIds.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.plain)
                .hideScrollBackground()
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle("Merge PDFs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFMultiPickerSheet(
                documents: pdfDocuments,
                selectedIds: $pickerSelectedIds,
                maxSelection: 3
            )
        }
        .toolbar {
            if allowsPicker {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Choose PDFs") {
                        showingPicker = true
                    }
                    .foregroundColor(.primary)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Merging..." : "Merge") {
                    mergeSelected()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocuments.count < 2 || isSaving)
            }
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .onAppear {
            syncOrderedSelectionFromPicker()
        }
        .onChange(of: pickerSelectedIds) { _ in
            syncOrderedSelectionFromPicker()
        }
        .alert("Merge PDFs", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func removeSelection(_ id: UUID) {
        orderedSelectedIds.removeAll { $0 == id }
        pickerSelectedIds.remove(id)
    }

    private func syncOrderedSelectionFromPicker() {
        var ordered = orderedSelectedIds.filter { pickerSelectedIds.contains($0) }
        let existing = Set(ordered)
        let missing = pickerSelectedIds.filter { !existing.contains($0) }

        if !missing.isEmpty {
            for doc in pdfDocuments where missing.contains(doc.id) {
                ordered.append(doc.id)
            }
        }

        if ordered.count > 3 {
            ordered = Array(ordered.prefix(3))
        }

        orderedSelectedIds = ordered
        let normalized = Set(ordered)
        if pickerSelectedIds != normalized {
            pickerSelectedIds = normalized
        }
    }

    private func mergeSelected() {
        guard selectedDocuments.count >= 2 else { return }
        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)

        let workItem = DispatchWorkItem {
            let merged = PDFDocument()
            var pageIndex = 0

            for doc in selectedDocuments {
                guard let data = pdfData(from: doc, documentManager: documentManager),
                      let pdf = PDFDocument(data: data) else { continue }
                for i in 0..<pdf.pageCount {
                    if let page = pdf.page(at: i) {
                        merged.insert(page, at: pageIndex)
                        pageIndex += 1
                    }
                }
            }

            guard let data = merged.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to merge PDFs."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: selectedDocuments.first?.title ?? "PDF")
            let preferredBase = "\(base)_merged"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(
                title: title,
                data: data,
                sourceDocumentId: nil,
                sourceDocument: nil,
                inheritMetadata: false
            )

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                orderedSelectedIds.removeAll()
                pickerSelectedIds.removeAll()
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Merged PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

// MARK: - Split

struct SplitPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var ranges: [PageRangeInput] = [PageRangeInput()]
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

    private var pageCount: Int {
        guard let doc = selectedDocument,
              let data = pdfData(from: doc, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else { return 0 }
        return pdf.pageCount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let document = selectedDocument {
                    HStack {
                        Text(document.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if allowsPicker {
                            Button("Change") { showingPicker = true }
                                .buttonStyle(.bordered)
                        }
                    }
                    Text("Pages: \(pageCount)")
                        .foregroundColor(.secondary)
                } else {
                    if allowsPicker {
                        Button("Choose PDF") { showingPicker = true }
                            .buttonStyle(.bordered)
                    } else {
                        Text("No PDF selected.")
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    ForEach(ranges.indices, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                TextField("Start", text: $ranges[idx].start)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                Text("to")
                                TextField("End", text: $ranges[idx].end)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    if ranges.count > 1 {
                                        ranges.remove(at: idx)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(ranges.count > 1 ? .red : .secondary)
                                }
                                .disabled(ranges.count == 1)
                            }
                            if isInvalidRange(ranges[idx]) {
                                Text("Start must be less than or equal to end")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Button("Add Range") {
                        if ranges.count < 3 {
                            ranges.append(PageRangeInput())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("Primary"))
                    .disabled(ranges.count >= 3)
                }
            }
            .padding()
        }
        .navigationTitle("Split PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Splitting..." : "Split") {
                    splitSelected()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocument == nil || isSaving || ranges.contains(where: { isInvalidRange($0) }))
            }
        }
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .alert("Split PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func splitSelected() {
        guard let document = selectedDocument,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else { return }

        let totalPages = pdf.pageCount
        let parsedRanges = parseRanges(totalPages: totalPages)
        if parsedRanges.isEmpty {
            alertMessage = "Enter valid page ranges within 1-\(totalPages)."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)

        let workItem = DispatchWorkItem {
            var created = 0
            var newDocs: [Document] = []
            var existingTitles = initialTitles
            for (idx, range) in parsedRanges.enumerated() {
                let newPDF = PDFDocument()
                var insertIndex = 0
                for page in range.lowerBound...range.upperBound {
                    if let pdfPage = pdf.page(at: page - 1) {
                        newPDF.insert(pdfPage, at: insertIndex)
                        insertIndex += 1
                    }
                }
                guard let outData = newPDF.dataRepresentation() else { continue }
                let base = baseTitle(for: document.title)
                let preferredBase = "\(base)_split\(idx + 1)"
                let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
                existingTitles.insert(title.lowercased())
                let newDoc = makePDFDocument(
                    title: title,
                    data: outData,
                    sourceDocumentId: document.id,
                    sourceDocument: document,
                    inheritMetadata: false
                )
                newDocs.append(newDoc)
                created += 1
                if created >= 3 { break }
            }

            DispatchQueue.main.async {
                for doc in newDocs {
                    documentManager.addDocument(doc)
                }
                isSaving = false
                if let onComplete, !newDocs.isEmpty {
                    onComplete(newDocs)
                } else {
                    alertMessage = created > 0 ? "Created \(created) PDFs." : "Failed to split PDF."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func parseRanges(totalPages: Int) -> [ClosedRange<Int>] {
        ranges.compactMap { input in
            guard let start = Int(input.start), let end = Int(input.end) else { return nil }
            guard start >= 1, end >= 1, start <= end, end <= totalPages else { return nil }
            return start...end
        }.prefix(3).map { $0 }
    }

    private func isInvalidRange(_ input: PageRangeInput) -> Bool {
        guard let start = Int(input.start), let end = Int(input.end) else { return false }
        return start > end
    }
}

struct PageRangeInput {
    var start: String = ""
    var end: String = ""
}

// MARK: - Rearrange

struct RearrangePDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [PDFPageItem] = []
    @State private var editMode: EditMode = .active
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
                    ForEach(pageItems) { item in
                        HStack(spacing: 12) {
                            Image(uiImage: item.thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 70)
                                .cornerRadius(6)
                            Text("Page \(item.index + 1)")
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onMove { indices, newOffset in
                        pageItems.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .listStyle(.plain)
                .hideScrollBackground()
                .environment(\.editMode, $editMode)
            }
        }
        .navigationTitle("Rearrange PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isSaving ? "Arranging..." : "Arrange") {
                    saveRearranged()
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
        .alert("Rearrange PDF", isPresented: $showingAlert) {
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

        var items: [PDFPageItem] = []
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index) {
                let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                items.append(PDFPageItem(index: index, thumbnail: thumb))
            }
        }
        pageItems = items
    }

    private func saveRearranged() {
        guard let document = selectedDocument,
              let data = pdfData(from: document, documentManager: documentManager),
              let pdf = PDFDocument(data: data) else { return }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            let newPDF = PDFDocument()
            var insertIndex = 0
            for item in pageItems {
                if let page = pdf.page(at: item.index) {
                    newPDF.insert(page, at: insertIndex)
                    insertIndex += 1
                }
            }
            guard let outData = newPDF.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to save rearranged PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_rearranged"
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
                    alertMessage = "Rearranged PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct PDFPageItem: Identifiable {
    let id = UUID()
    let index: Int
    let thumbnail: UIImage
}
