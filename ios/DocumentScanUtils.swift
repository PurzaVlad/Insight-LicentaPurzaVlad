import UIKit
import Vision
import OSLog

// Shared OCR / scan utilities used by both DocumentsView and SmartViewsListView.

// MARK: - OCR

func ocrPage(image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
    guard let processed = preprocessScanImage(image),
          let cgImage = processed.cgImage else {
        return ("", OCRPage(pageIndex: pageIndex, blocks: []))
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    var recognizedText = ""
    var blocks: [OCRBlock] = []

    do {
        try handler.perform([request])
        if let results = request.results as? [VNRecognizedTextObservation] {
            for (idx, observation) in results.enumerated() {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let bbox = observation.boundingBox
                let bounding = OCRBoundingBox(x: bbox.origin.x, y: bbox.origin.y,
                                              width: bbox.size.width, height: bbox.size.height)
                blocks.append(OCRBlock(text: candidate.string,
                                       confidence: Double(candidate.confidence),
                                       bbox: bounding, order: idx))
                recognizedText += candidate.string + "\n"
            }
        }
    } catch {
        AppLogger.ui.error("OCR failed: \(error.localizedDescription)")
    }

    return (recognizedText, OCRPage(pageIndex: pageIndex, blocks: blocks))
}

func buildStructuredOCRText(from pages: [OCRPage], includePageLabels: Bool) -> String {
    var output: [String] = []
    for page in pages {
        if includePageLabels { output.append("Page \(page.pageIndex + 1):") }
        let sorted = page.blocks.sorted { $0.order < $1.order }
        for block in sorted { output.append(block.text) }
    }
    return output.joined(separator: "\n")
}

func preprocessScanImage(_ image: UIImage) -> UIImage? {
    let targetSize: CGFloat = 2560
    let scale = min(targetSize / max(image.size.width, 1), targetSize / max(image.size.height, 1))
    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    UIColor.white.setFill()
    UIRectFill(CGRect(origin: .zero, size: newSize))
    image.draw(in: CGRect(origin: .zero, size: newSize))
    let result = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return result
}

// MARK: - PDF creation

func createScannedPDF(from images: [UIImage]) -> Data? {
    let pdfData = NSMutableData()
    guard let dataConsumer = CGDataConsumer(data: pdfData) else { return nil }
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    var mediaBox = pageRect
    guard let ctx = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }
    for image in images {
        ctx.beginPDFPage(nil)
        let s = image.size
        let scale = min(612 / max(s.width, 1), 792 / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        let rect = CGRect(x: (612 - w) / 2, y: (792 - h) / 2, width: w, height: h)
        if let cg = image.cgImage { ctx.draw(cg, in: rect) }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return pdfData as Data
}

// MARK: - Title utilities

func ocrTitleCase(_ text: String) -> String {
    enforceScanTitleCase(String(text.prefix(300)))
}

func enforceScanTitleCase(_ input: String) -> String {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    let acronymWords: Set<String> = ["ai","ocr","pdf","docx","ppt","pptx","xls","xlsx","jpg","jpeg","png"]
    return normalized.split(separator: " ").map { word -> String in
        let raw = String(word)
        let plain = raw.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        if acronymWords.contains(plain) { return raw.uppercased() }
        if raw == raw.uppercased() && raw.count <= 4 { return raw }
        var result = ""
        var didCap = false
        for scalar in raw.unicodeScalars {
            let ch = Character(scalar)
            if CharacterSet.letters.contains(scalar) {
                result.append(didCap ? String(ch).lowercased() : String(ch).uppercased())
                didCap = true
            } else {
                result.append(ch)
            }
        }
        return result
    }.joined(separator: " ")
}

func compactScanTitle(_ value: String, maxWords: Int) -> String {
    let expanded = value
        .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expanded.isEmpty else { return "" }
    let acronyms: Set<String> = ["ai","ocr","pdf","docx","ppt","pptx","xls","xlsx","jpg","jpeg","png","heic","csv"]
    return expanded.split { $0.isWhitespace }.prefix(maxWords).map { token -> String in
        let raw = String(token)
        if acronyms.contains(raw.lowercased()) { return raw.uppercased() }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
    }.joined()
}

func normalizedScanTitle(_ raw: String) -> String {
    let trimmed = raw
        .replacingOccurrences(of: "^(?i)\\s*(suggested\\s+)?(document\\s+)?title\\s*[:\\-]\\s*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)\\btitle\\b", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "ScannedDocument.pdf" }
    let typedURL = URL(fileURLWithPath: trimmed)
    let typedExt = typedURL.pathExtension.lowercased()
    let knownExts: Set<String> = ["pdf","docx","ppt","pptx","xls","xlsx","txt","png","jpg","jpeg","heic"]
    let base = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : trimmed
    let cleanBase = base
        .replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    let safeBase = compactScanTitle(
        cleanBase.isEmpty ? "ScannedDocument" : cleanBase,
        maxWords: 10
    )
    return "\(safeBase.isEmpty ? "ScannedDocument" : safeBase).pdf"
}

func normalizeSuggestedScanTitle(_ raw: String, fallback: String) -> String {
    func cap(_ v: String) -> String { compactScanTitle(v.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespacesAndNewlines), maxWords: 4) }
    let normFallback = cap(fallback)

    let fullRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
    let extracted: String
    if let regex = try? NSRegularExpression(pattern: #"(?i)title\s*:\s*"([^"]+)""#),
       let match = regex.firstMatch(in: raw, options: [], range: fullRange),
       match.numberOfRanges > 1,
       let groupRange = Range(match.range(at: 1), in: raw) {
        extracted = String(raw[groupRange])
    } else {
        extracted = raw
    }

    let stripped = extracted
        .replacingOccurrences(of: "^(?i)\\s*(suggested\\s+)?(document\\s+)?title\\s*[:\\-]\\s*", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\"", with: "")
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.isEmpty { return normFallback }

    let cleaned = stripped
        .replacingOccurrences(of: "(?i)\\btitle\\b", with: "", options: .regularExpression)
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty { return normFallback }
    if isScanMetadataLine(cleaned) { return normFallback }
    let words = cleaned.split { $0.isWhitespace }
    if words.count > 14 || cleaned.count > 90 { return normFallback }
    let normalized = cap(cleaned)
    return normalized.isEmpty ? normFallback : normalized
}

// MARK: - Naming helpers

func extractScanTitleCandidates(from text: String) -> [String] {
    let lines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var scored: [(String, Double)] = []
    for (idx, line) in lines.enumerated() {
        if isScanMetadataLine(line) { continue }
        let score = scoreScanTitleLine(line, index: idx)
        if score > 0 { scored.append((line, score)) }
    }

    let top = scored.sorted { $0.1 > $1.1 }.prefix(5)
        .map { normalizeScanTitleCandidate($0.0, maxWords: 16) }
        .filter { !$0.isEmpty }
    return top.isEmpty ? [normalizeScanTitleCandidate(text, maxWords: 8)] : top
}

func isScanMetadataLine(_ line: String) -> Bool {
    let lower = line.lowercased()
    let denylist = ["abstract","keywords","references","acknowledg","copyright","doi","issn","isbn",
                    "volume","vol.","issue","no.","page","journal","proceedings","conference",
                    "university","department","faculty","publisher","press","editor",
                    "address","telephone","phone","fax"]
    return denylist.contains { lower.contains($0) }
}

func scoreScanTitleLine(_ line: String, index: Int) -> Double {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count < 4 || trimmed.count > 120 { return -1 }
    let words = trimmed.split { $0.isWhitespace }
    let letters = Double(trimmed.filter { $0.isLetter }.count)
    let digits = Double(trimmed.filter { $0.isNumber }.count)
    let total = max(1.0, Double(trimmed.count))
    var score: Double = Double(max(0, 5 - index)) * 0.35
    let wc = words.count
    if wc >= 4 && wc <= 16 { score += 2.0 }
    if wc <= 2 { score -= 1.5 }
    if wc > 20 { score -= 1.0 }
    let lr = letters / total, dr = digits / total
    if lr >= 0.7 { score += 1.0 }
    if lr < 0.4 { score -= 1.0 }
    if dr > 0.3 { score -= 1.5 }
    if words.allSatisfy({ guard let f = $0.first else { return false }; return String(f) == String(f).uppercased() }) { score += 0.8 }
    if trimmed == trimmed.uppercased() && lr > 0.5 { score += 0.5 }
    return score
}

func normalizeScanTitleCandidate(_ input: String, maxWords: Int) -> String {
    let first = input.components(separatedBy: .newlines).first ?? ""
    let stripped = first
        .replacingOccurrences(of: "^[\\s•\\-–—*]+", with: "", options: .regularExpression)
        .replacingOccurrences(of: #"["'""` ]"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "[^A-Za-z0-9\\s&\\-\\/]", with: " ", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return stripped.split(separator: " ").prefix(maxWords).joined(separator: " ")
}

func extractScanHeadingsAndFirstParagraph(from text: String) -> String {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "" }
    let paragraphs = normalized
        .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        .components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !paragraphs.isEmpty else { return normalized }
    if paragraphs.count == 1 { return paragraphs[0] }
    return paragraphs[0] + "\n\n" + paragraphs[1]
}

// MARK: - AI name generation (callback-based, no view state)

func generateAIDocumentName(from text: String, completion: @escaping (String) -> Void) {
    let base = extractScanHeadingsAndFirstParagraph(from: text)
    let seed = base.isEmpty ? text : base
    let candidates = extractScanTitleCandidates(from: seed)
    let fallbackRaw = compactScanTitle(candidates.first ?? ocrTitleCase(text), maxWords: 4)
    let fallback = fallbackRaw.isEmpty ? "ScannedDocument" : fallbackRaw
    let snippet = String(seed.prefix(300))

    let prompt = """
        Generate a short, descriptive title (2-5 words) for this document. \
        The title should capture what the document is specifically about — be specific and descriptive. \
        Output only the title in Title Case.

        HINTS:
        \(candidates.map { "- \($0)" }.joined(separator: "\n"))

        CONTENT:
        \(snippet)
        """

    EdgeAI.shared?.generate("<<<NO_HISTORY>>><<<NAME_REQUEST>>>" + prompt, resolver: { result in
        DispatchQueue.main.async {
            if let s = result as? String, !s.isEmpty {
                let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = normalizeSuggestedScanTitle(clean, fallback: fallback)
                completion(normalized.isEmpty ? fallback : normalized)
            } else {
                completion(fallback)
            }
        }
    }, rejecter: { _, _, _ in
        DispatchQueue.main.async { completion(fallback) }
    })
}

// MARK: - Full OCR + naming pipeline

/// Runs OCR on all images and calls completion with (suggestedName, ocrPages, extractedText).
func prepareScanNamingAsync(
    images: [UIImage],
    completion: @escaping (_ suggested: String, _ pages: [OCRPage], _ text: String) -> Void
) {
    guard let first = images.first else { return }

    DispatchQueue.global(qos: .userInitiated).async {
        var pages: [OCRPage] = []
        let firstResult = ocrPage(image: first, pageIndex: 0)
        let firstPageText = firstResult.text

        for (idx, img) in images.enumerated() {
            pages.append(ocrPage(image: img, pageIndex: idx).page)
        }

        let extracted = buildStructuredOCRText(from: pages, includePageLabels: true)
        let seed = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? firstPageText : extracted

        if seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback = ocrTitleCase(firstPageText)
            DispatchQueue.main.async { completion(fallback, pages, extracted) }
            return
        }

        generateAIDocumentName(from: seed) { name in
            completion(name, pages, extracted)
        }
    }
}
