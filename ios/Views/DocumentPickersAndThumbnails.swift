import SwiftUI
import UIKit
import PDFKit
import Vision
import VisionKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AVFoundation

struct PDFThumbnailView: UIViewRepresentable {
    let data: Data
    let contentMode: UIView.ContentMode

    init(data: Data, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.data = data
        self.contentMode = contentMode
    }
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
        imageView.clipsToBounds = true
        
        // Generate thumbnail from PDF
        if let document = PDFDocument(data: data),
           let firstPage = document.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let thumbnail = firstPage.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
            imageView.image = thumbnail
        }
        
        return imageView
    }
    
    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Update if needed
    }
}

struct DocumentThumbnailView: UIViewRepresentable {
    let document: Document
    let size: CGSize
    @EnvironmentObject private var documentManager: DocumentManager

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if document.type == .scanned, let imageData = documentManager.imageData(for: document.id)?.first, let uiImage = UIImage(data: imageData) {
            uiView.image = renderThumbnail(from: uiImage, size: size)
            return
        }

        if let imageData = documentManager.imageData(for: document.id)?.first, let uiImage = UIImage(data: imageData) {
            uiView.image = renderThumbnail(from: uiImage, size: size)
            return
        }

        if let pdfData = documentManager.pdfData(for: document.id), let image = thumbnailFromPDF(data: pdfData, size: size) {
            uiView.image = image
            return
        }

        var ext = splitDisplayTitle(document.title).ext
        var data: Data?

        if document.type == .scanned,
           documentManager.pdfData(for: document.id) == nil,
           documentManager.imageData(for: document.id)?.first == nil {
            data = document.content.data(using: .utf8)
            ext = "txt"
        } else {
            data = documentManager.anyFileData(for: document.id) ?? document.content.data(using: .utf8)
            if ext.isEmpty {
                ext = fileExtension(for: document.type)
            }
        }

        guard let data else {
            uiView.image = nil
            return
        }

        let fileURL = temporaryFileURL(id: document.id, ext: ext.isEmpty ? "dat" : ext)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                AppLogger.ui.error("Failed to write thumbnail data to temp file: \(error.localizedDescription)")
            }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, _, _ in
            guard let representation = representation else { return }
            DispatchQueue.main.async {
                uiView.image = representation.uiImage
            }
        }
    }

    private func thumbnailFromPDF(data: Data, size: CGSize) -> UIImage? {
        guard let document = PDFDocument(data: data), let firstPage = document.page(at: 0) else { return nil }
        return firstPage.thumbnail(of: size, for: .mediaBox)
    }

    private func renderThumbnail(from image: UIImage, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let imageSize = image.size
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            let x = (size.width - width) / 2
            let y = (size.height - height) / 2
            image.draw(in: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func temporaryFileURL(id: UUID, ext: String) -> URL {
        let safeExt = ext.isEmpty ? "dat" : ext
        return FileManager.default.temporaryDirectory.appendingPathComponent("doc_thumb_\(id.uuidString).\(safeExt)")
    }
}

// MARK: - Document Preview View
struct DocumentPicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .pdf, .rtf, .plainText, .image, .jpeg, .png, .heic,
            UTType("com.microsoft.word.doc")!,
            UTType("org.openxmlformats.wordprocessingml.document")!,
            UTType("com.microsoft.powerpoint.ppt")!,
            UTType("org.openxmlformats.presentationml.presentation")!,
            UTType("com.microsoft.excel.xls")!,
            UTType("org.openxmlformats.spreadsheetml.sheet")!,
            .spreadsheet,
            .json,
            .xml
        ], asCopy: true)
        
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.completion(urls)
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: ([UIImage]) -> Void
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        scanner.modalPresentationStyle = .fullScreen
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        
        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var scannedImages: [UIImage] = []
            
            for pageIndex in 0..<scan.pageCount {
                // Get the processed, cropped image from the scanner
                let image = scan.imageOfPage(at: pageIndex)
                scannedImages.append(image)
            }
            
            parent.completion(scannedImages)
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            AppLogger.ui.error("Document scanning failed: \(error.localizedDescription)")
            controller.dismiss(animated: true)
        }
    }
}

struct SimpleCameraView: UIViewControllerRepresentable {
    let completion: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .fullScreen
        
        // Check if camera is available
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // Fallback to photo library if camera not available (simulator)
            picker.sourceType = .photoLibrary
        }
        
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SimpleCameraView
        
        init(_ parent: SimpleCameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                let recognizedText = performOCR(on: image)
                parent.completion(recognizedText)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
        
        private func performOCR(on image: UIImage) -> String {
            guard let cgImage = image.cgImage else {
                return "Could not process image"
            }
            
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            
            var recognizedText = ""
            
            do {
                try requestHandler.perform([request])
                if let results = request.results {
                    recognizedText = results.compactMap { result in
                        result.topCandidates(1).first?.string
                    }.joined(separator: "\n")
                }
            } catch {
                recognizedText = "OCR failed: \(error.localizedDescription)"
            }
            
            return recognizedText.isEmpty ? "No text found in image" : recognizedText
        }
    }
}
