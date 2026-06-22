import SwiftUI
import UIKit
import PDFKit
import QuickLook
import Foundation
import OSLog

struct DocumentDetailView: View {
    let document: Document
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var currentPage = 0
    @State private var showingTextView = false
    @State private var isGeneratingSummary = false
    @State private var showingDocumentPreview = false
    @State private var documentURL: URL?
    
    var body: some View {
        VStack(spacing: 0) {
            // Show PDF if available, otherwise show images
            if let pdfData = documentManager.pdfData(for: document.id) {
                // PDF viewer
                PDFViewRepresentable(data: pdfData)
                    .background(Color(.systemBackground))

            } else if let imageDataArray = documentManager.imageData(for: document.id), !imageDataArray.isEmpty {
                // Image viewer with proper scaling
                TabView(selection: $currentPage) {
                    ForEach(0..<imageDataArray.count, id: \.self) { index in
                        if let uiImage = UIImage(data: imageDataArray[index]) {
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
                            .tag(index)
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle())
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                
                // Page indicator and controls
                HStack {
                    Button("Text View") {
                        showingTextView = true
                    }
                    .padding()
                    
                    Button("Preview") {
                        prepareDocumentForPreview()
                    }
                    .padding()
                    
                    Spacer()
                    
                    if imageDataArray.count > 1 {
                        Text("Page \(currentPage + 1) of \(imageDataArray.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .background(Color(.systemBackground))
                
            } else {
                // Enhanced text view based on document type
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Document type indicator
                        HStack() {
                            Image(systemName: iconForDocumentType(document.type))
                                .foregroundColor(.blue)
                            Text(document.type.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        
                        // Document content with better formatting
                        VStack(alignment: .leading, spacing: 16) {
                            // Summary section (if available and not default)
                            if !document.summary.isEmpty && document.summary != "Processing..." {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "brain.head.profile")
                                            .foregroundColor(.orange)
                                        Text("AI Summary")
                                            .font(.headline)
                                    }
                                    
                                    Text(formatMarkdownText(document.summary))
                                        .foregroundColor(.primary)
                                        .padding()
                                        .background(Color(.secondarySystemBackground))
                                        .cornerRadius(12)
                                }
                                
                                Divider()
                            }
                            
                            // Content section
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.green)
                                    Text("Content")
                                        .font(.headline)
                                }
                                
                                if document.content.isEmpty {
                                    Text("No text content available")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .background(Color(.tertiarySystemBackground))
                                        .cornerRadius(12)
                                } else {
                                    Text(document.content)
                                        .font(.body)
                                        .lineSpacing(4)
                                        .padding()
                                        .background(Color(.tertiarySystemBackground))
                                        .cornerRadius(12)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal)
                        
                        Spacer(minLength: 20)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTextView) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Summary Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.headline)
                            
                            Text(formatMarkdownText(document.summary))
                                .foregroundColor(.secondary)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        
                        Divider()
                        
                        // Extracted Text
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Extracted Text")
                                .font(.headline)
                            
                            Text(document.content)
                                .font(.body)
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                        }
                        
                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Text Content")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingTextView = false
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                // Document Preview Button
                Button(action: {
                    prepareDocumentForPreview()
                }) {
                    HStack(alignment: .top) {
                        Image(systemName: "doc.magnifyingglass")
                        Text("Preview")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.green)
                    .clipShape(Capsule())
                }
                
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
        .sheet(isPresented: $showingDocumentPreview) {
            if let url = documentURL {
                DocumentPreviewContainerView(url: url, document: document)
                    .applySquareSheetCorners()
            }
        }
    }
    
    private func generateAISummary() {
        AppLogger.ui.debug("Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        documentManager.generateSummary(for: document, force: true)
    }

    private func prepareDocumentForPreview() {
        // Create a temporary file for preview
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExtension = getFileExtension(for: document.type)
        let tempFileName = "preview_\(document.id).\(fileExtension)"
        let tempURL = tempDirectory.appendingPathComponent(tempFileName)
        
        // Try to get the original document data
        if let originalData = getDocumentData() {
            do {
                try originalData.write(to: tempURL)
                documentURL = tempURL
                showingDocumentPreview = true
                AppLogger.ui.debug("Prepared document for preview at \(tempURL)")
            } catch {
                AppLogger.ui.error("Failed to prepare document for preview: \(error.localizedDescription)")
                // Fallback to text view
                showingTextView = true
            }
        } else {
            AppLogger.ui.debug("No document data available, showing text view")
            showingTextView = true
        }
    }
    
    private func getDocumentData() -> Data? {
        if let data = documentManager.anyFileData(for: document.id) {
            AppLogger.ui.debug("Retrieved \(data.count) bytes of file data")
            return data
        }
        AppLogger.ui.debug("No document data available for preview")
        return nil
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
            return "pdf"  // Scanned documents are typically saved as PDF
        case .image:
            return "jpg"
        case .zip:
            return "zip"
        }
    }
}
