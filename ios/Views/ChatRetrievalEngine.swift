import Foundation

extension NativeChatView {
    func recentChatContext(excludingLastUser: Bool, question: String) -> String {
        let history = excludingLastUser ? Array(messages.dropLast()) : messages
        if history.isEmpty { return "None." }

        let topicShifted = isTopicShift(question: question, history: history)
        let sliceCount = topicShifted ? min(2, history.count) : min(historyLimit, history.count)
        let tail = Array(history.suffix(sliceCount))
        if tail.isEmpty { return "None." }
        return tail.map { msg in
            let role = msg.role.capitalized
            let text = cleanLine(msg.text)
            return "\(role): \(text)"
        }.joined(separator: "\n")
    }

    func recentExchangeContext(question: String) -> String {
        let history = messages
        if history.isEmpty { return "None." }
        let topicShifted = isTopicShift(question: question, history: history)
        if topicShifted { return "None." }

        let lastUsers = history.filter { $0.role == "user" }.suffix(3)
        let lastAssistant = history.last(where: { $0.role == "assistant" })

        let userLines = lastUsers.map { cleanLine(String($0.text.prefix(220))) }
        let assistantLine = lastAssistant.map { cleanLine(String($0.text.prefix(320))) } ?? ""

        if userLines.isEmpty && assistantLine.isEmpty { return "None." }
        let usersBlock = userLines.isEmpty ? "" : userLines.enumerated().map { idx, text in
            "LastUser\(idx + 1): \(text)"
        }.joined(separator: "\n")
        let assistantBlock = assistantLine.isEmpty ? "" : "LastAssistant: \(assistantLine)"

        if usersBlock.isEmpty { return assistantBlock }
        if assistantBlock.isEmpty { return usersBlock }
        return """
        \(usersBlock)
        \(assistantBlock)
        """
    }

    func isTopicShift(question: String, history: [ChatMessage]) -> Bool {
        guard let lastUser = history.last(where: { $0.role == "user" }) else { return true }
        let recent = cleanLine(lastUser.text)
        let qTokens = tokenSet(question)
        let rTokens = tokenSet(recent)
        if qTokens.isEmpty || rTokens.isEmpty { return false }
        let overlap = qTokens.intersection(rTokens).count
        let union = qTokens.union(rTokens).count
        if union == 0 { return false }
        let jaccard = Double(overlap) / Double(union)
        return jaccard < 0.12
    }

    func tokenSet(_ text: String) -> Set<String> {
        let tokens = cleanLine(text)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 }
        return Set(tokens)
    }

    func normalizeSpacedLetters(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z](?: [A-Z]){2,}\b"#) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let matched = nsText.substring(with: match.range)
            mutable.replaceCharacters(in: match.range, with: matched.replacingOccurrences(of: " ", with: ""))
        }
        return String(mutable)
    }

    func cleanLine(_ text: String) -> String {
        normalizeSpacedLetters(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func folderPathMap() -> [UUID: String] {
        let byId = Dictionary(uniqueKeysWithValues: documentManager.folders.map { ($0.id, $0) })
        var cache: [UUID: String] = [:]

        func path(for folderId: UUID) -> String {
            if let cached = cache[folderId] { return cached }
            var parts: [String] = []
            var currentId: UUID? = folderId
            var safety = 0
            while let cid = currentId, let folder = byId[cid], safety < 20 {
                parts.append(folder.name)
                currentId = folder.parentId
                safety += 1
            }
            let fullPath = parts.reversed().joined(separator: "/")
            cache[folderId] = fullPath
            return fullPath
        }

        for folder in documentManager.folders {
            _ = path(for: folder.id)
        }
        return cache
    }

    func buildFolderIndex() -> String {
        if documentManager.folders.isEmpty { return "No folders." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        return documentManager.folders.map { folder in
            let path = pathMap[folder.id] ?? folder.name
            return """
            FolderId: \(folder.id.uuidString)
            Path: \(path)
            Created: \(formatter.string(from: folder.dateCreated))
            """
        }.joined(separator: "\n---\n")
    }

    func buildDocumentIndex() -> String {
        let docs = documentManager.conversationEligibleDocuments()
        if docs.isEmpty { return "No documents." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        return docs.map { doc in
            let folderPath = doc.folderId.flatMap { pathMap[$0] } ?? "Root"
            return """
            DocId: \(doc.id.uuidString)
            Title: \(doc.title)
            Folder: \(folderPath)
            Tags: \(doc.tags.joined(separator: ", "))
            Date: \(formatter.string(from: doc.dateCreated))
            """
        }.joined(separator: "\n---\n")
    }

    func buildStructuredOCRText(from pages: [OCRPage]) -> String {
        guard !pages.isEmpty else { return "" }
        var output: [String] = []
        for page in pages {
            let blocks = page.blocks.sorted { $0.order < $1.order }
            let combined = blocks.map { $0.text }.joined(separator: " ")
            output.append("Page \(page.pageIndex + 1):\n\(combined)")
        }
        return output.joined(separator: "\n\n")
    }

    struct ChunkHit {
        let document: Document
        let chunk: OCRChunk
        let bm25Score: Double
        let exactMatchScore: Double
        let recencyScore: Double
        let finalScore: Double
    }

    private static let retrievalStopwords: Set<String> = [
        "a","an","and","or","the","of","to","in","on","for","with","without","from","at","by","as",
        "is","are","was","were","be","been","being","this","that","these","those","it","its","you",
        "your","we","our","they","their","them","i","me","my","do","does","did","can","could","should",
        "would","will","about","into","over","under","between","among","what","which","who","whom","when",
        "where","why","how","please"
    ]

    private static let anchorStopwords: Set<String> = [
        "the","a","an","and","or","to","of","for","with","in","on","at","by","from",
        "is","are","was","were","be","been","it","this","that","these","those","they","them",
        "how","what","which","who","when","where","why","anything","about"
    ]

    func retrievalTokenArray(_ text: String) -> [String] {
        let cleaned = cleanLine(text)
        let lowered = cleaned.lowercased()
        let originalTokens = cleaned
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let tokens = lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        
        return zip(tokens, originalTokens).compactMap { (token, original) in
            // Keep stopwords filter
            if Self.retrievalStopwords.contains(token) { return nil }
            
            // NEW: Keep short tokens if they're all caps, numeric, or alphanumeric IDs
            if token.count < 3 {
                let hasDigit = token.contains(where: { $0.isNumber })
                let hasLetter = token.contains(where: { $0.isLetter })
                let isAllCaps = original == original.uppercased() && hasLetter
                if hasDigit || isAllCaps {
                    return token  // Keep "id", "a1", "q2", etc.
                }
                return nil
            }
            
            // NEW: Don't stem if token has digits or is likely acronym
            if token.contains(where: { $0.isNumber }) {
                return token  // Keep "2024", "123abc" intact
            }
            if token.count <= 4 && original == original.uppercased() && original.contains(where: { $0.isLetter }) {
                return token  // Keep "http", "json" intact (from "HTTP", "JSON")
            }
            
            // Improved stemming: only if length >= 6 and ends in 's' (not 'ss')
            if token.count >= 6 && token.hasSuffix("s") && !token.hasSuffix("ss") {
                return String(token.dropLast())
            }
            
            return token
        }
    }

    func retrievalTokens(_ text: String) -> Set<String> {
        Set(retrievalTokenArray(text))
    }

    func normalizedForTrigrams(_ text: String) -> String {
        cleanLine(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func characterTrigrams(for text: String) -> Set<String> {
        let normalized = normalizedForTrigrams(text)
        if normalized.isEmpty { return [] }
        if normalized.count < 3 { return [normalized] }
        let chars = Array(normalized)
        guard chars.count >= 3 else { return [] }
        var grams = Set<String>()
        for i in 0...(chars.count - 3) {
            let endIndex = i + 2
            guard endIndex < chars.count else { break }
            grams.insert(String(chars[i...endIndex]))
        }
        return grams
    }

    func trigramJaccardScore(queryTrigrams: Set<String>, chunkTrigrams: Set<String>) -> Double {
        if queryTrigrams.isEmpty || chunkTrigrams.isEmpty { return 0 }
        let intersection = queryTrigrams.intersection(chunkTrigrams).count
        if intersection == 0 { return 0 }
        let union = queryTrigrams.union(chunkTrigrams).count
        return Double(intersection) / Double(max(1, union))
    }

    /// Build a short contextual header from document metadata for BM25 enrichment.
    /// This is Anthropic's "Contextual Retrieval" technique — injecting document-level
    /// tokens into each chunk so keyword matching can associate chunks with their source.
    func contextualChunkHeader(for doc: Document) -> String {
        var parts: [String] = [doc.title]
        if !doc.tags.isEmpty {
            parts.append(doc.tags.joined(separator: " "))
        }
        return parts.joined(separator: " | ") + " — "
    }

    struct ChunkLexicalFeatures {
        let tokens: [String]
        let tokenSet: Set<String>
        let termFreq: [String: Int]
        let length: Int
        let trigrams: Set<String>
    }

    func buildChunkLexicalFeatures(for text: String) -> ChunkLexicalFeatures {
        let tokens = retrievalTokenArray(text)
        var termFreq: [String: Int] = [:]
        for token in tokens {
            termFreq[token, default: 0] += 1
        }
        return ChunkLexicalFeatures(
            tokens: tokens,
            tokenSet: Set(tokens),
            termFreq: termFreq,
            length: max(1, tokens.count),
            trigrams: characterTrigrams(for: text)
        )
    }

    func bm25Score(
        queryTokens: Set<String>,
        termFreq: [String: Int],
        docLength: Int,
        documentFrequency: [String: Int],
        totalDocs: Int,
        averageDocLength: Double
    ) -> Double {
        if queryTokens.isEmpty || termFreq.isEmpty || totalDocs == 0 { return 0 }
        let k1 = 1.2
        let b = 0.75
        let avgdl = max(1.0, averageDocLength)

        var score = 0.0
        for token in queryTokens {
            let tf = Double(termFreq[token] ?? 0)
            if tf <= 0 { continue }
            let df = Double(documentFrequency[token] ?? 0)
            let n = Double(totalDocs)
            let idf = log(1.0 + ((n - df + 0.5) / (df + 0.5)))
            let denominator = tf + k1 * (1.0 - b + b * (Double(docLength) / avgdl))
            if denominator > 0 {
                score += idf * ((tf * (k1 + 1.0)) / denominator)
            }
        }

        return score
    }

    func anchorTokens(from question: String) -> [String] {
        let rawTokens = question.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        let anchors = rawTokens.filter { token in
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            if isShortAcronymToken(t) { return true }
            if t.count < 5 { return false }
            if Self.anchorStopwords.contains(t.lowercased()) { return false }
            let hasUpper = t.rangeOfCharacter(from: .uppercaseLetters) != nil
            let hasDigit = t.rangeOfCharacter(from: .decimalDigits) != nil
            let hasHyphen = t.contains("-")
            let isDistinctive = t.count >= 5
            return hasUpper || hasDigit || hasHyphen || isDistinctive
        }
        var seen = Set<String>()
        return anchors.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Check if text contains an anchor via exact substring or trigram fuzzy match
    func textContainsAnyAnchor(_ text: String, anchors: [String]) -> Bool {
        let lower = text.lowercased()
        return anchors.contains { anchor in
            let anchorLower = anchor.lowercased()
            // Exact substring match (fast path)
            if lower.contains(anchorLower) { return true }
            // Fuzzy match: trigram overlap for tokens >= 6 chars
            if anchorLower.count >= 6 {
                let anchorTrigrams = characterTrigrams(for: anchorLower)
                let textTrigrams = characterTrigrams(for: lower)
                let score = trigramJaccardScore(queryTrigrams: anchorTrigrams, chunkTrigrams: textTrigrams)
                return score >= 0.25
            }
            return false
        }
    }

    func anchorFilteredDocuments(question: String, docs: [Document]) -> [Document] {
        let anchors = anchorTokens(from: question)
        if anchors.isEmpty { return docs }

        let filtered = docs.filter { doc in
            let contentSample = compact(doc.content, maxChars: 1500)
            let rawOCRSample = doc.ocrChunks
                .prefix(4)
                .map(\.text)
                .joined(separator: " ")
            let ocrSample = compact(rawOCRSample, maxChars: 1500)
            let blob = "\(doc.title) \(doc.tags.joined(separator: " ")) \(doc.summary) \(contentSample) \(ocrSample)"
            return textContainsAnyAnchor(blob, anchors: anchors)
        }

        // Return all docs if filtering is too aggressive (removes >80% of docs)
        let removalRate = docs.isEmpty ? 0 : Double(docs.count - filtered.count) / Double(docs.count)
        if filtered.isEmpty || removalRate > 0.8 {
            return docs
        }
        return filtered
    }

    func expandQuery(_ question: String) -> String {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return question }
        let tokens = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasStrongAnchor = !anchorTokens(from: question).isEmpty

        func hasAnyToken(_ terms: [String]) -> Bool {
            !tokens.intersection(Set(terms)).isEmpty
        }

        func hasAnyPhrase(_ phrases: [String]) -> Bool {
            phrases.contains { q.contains($0) }
        }

        var extras: [String] = []

        // DATE/TIME
        if hasAnyToken(["date", "start", "end", "from", "to", "period", "year", "month"]) ||
            hasAnyPhrase(["when", "effective date"]) {
            extras.append("date start end from to period year month effective")
        }

        // LOCATION
        if !hasStrongAnchor &&
            (hasAnyToken(["city", "country", "location", "based", "region", "address"]) ||
            hasAnyPhrase(["where", "based in"])) {
            extras.append("location city country region address")
        }

        // ENTITY
        if hasAnyToken(["who", "party", "person", "company", "organization", "client", "vendor", "employee", "employer"]) {
            extras.append("party person company organization client vendor employee employer")
        }

        // AMOUNT
        if hasAnyToken(["amount", "total", "price", "cost", "fee", "value", "eur", "usd", "currency"]) {
            extras.append("amount total price cost fee value eur usd currency")
        }

        // IDENTIFIER
        if hasAnyToken(["id", "identifier", "number", "reference", "ref", "code", "account", "email", "phone", "passport", "tax", "iban"]) {
            extras.append("id identifier number reference ref code account email phone passport tax")
        }

        if extras.isEmpty { return question }
        return question + "\n\nQuery hints: " + extras.joined(separator: " ")
    }

    func expandQueryWithAnalysis(_ question: String, analysis: QueryAnalysis?) -> String {
        // If we have LLM analysis, use its focus_terms and soft_expansions
        if let analysis = analysis {
            var enrichedQuery = question
            
            // Add focus terms (key entities/concepts)
            if !analysis.focusTerms.isEmpty {
                let focusHints = analysis.focusTerms.joined(separator: " ")
                enrichedQuery += "\n\nFocus: \(focusHints)"
            }
            
            // Add soft expansions (synonyms/paraphrases)
            if !analysis.softExpansions.isEmpty {
                let expansionHints = analysis.softExpansions.joined(separator: " ")
                enrichedQuery += "\n\nExpansions: \(expansionHints)"
            }
            
            return enrichedQuery
        }
        
        // Fallback to heuristic-based expansion
        return expandQuery(question)
    }

    func predictField(for question: String) -> Document.DocumentCategory {
        DocumentManager.inferCategory(title: "", content: question, summary: question)
    }

    func semanticOverlapScore(questionTokens: Set<String>, chunkTokens: Set<String>) -> Double {
        if questionTokens.isEmpty || chunkTokens.isEmpty { return 0 }
        let overlap = questionTokens.intersection(chunkTokens).count
        return Double(overlap) / Double(max(1, questionTokens.count))
    }

    func normalizedMatchScore(questionTokens: Set<String>, text: String) -> Double {
        if questionTokens.isEmpty { return 0 }
        let targetTokens = retrievalTokens(text)
        if targetTokens.isEmpty { return 0 }
        let overlap = questionTokens.intersection(targetTokens).count
        return Double(overlap) / Double(max(1, questionTokens.count))
    }

    func normalizedAlphaNumericText(_ text: String) -> String {
        let lowered = cleanLine(text).lowercased()
        let mapped = lowered.map { char -> Character in
            if char.isLetter || char.isNumber || char.isWhitespace {
                return char
            }
            return " "
        }
        return " " + String(mapped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    func exactQueryTokens(from question: String) -> [String] {
        let rawTokens = cleanLine(question)
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for raw in rawTokens {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "")
            if normalized.isEmpty { continue }

            let isShortAcronym = isShortAcronymToken(trimmed)
            let hasDigitOrHyphen =
                trimmed.rangeOfCharacter(from: .decimalDigits) != nil ||
                trimmed.contains("-")
            let minLen = (isShortAcronym || hasDigitOrHyphen) ? 2 : 4

            if normalized.count < minLen { continue }
            if Self.retrievalStopwords.contains(normalized) { continue }

            if seen.insert(normalized).inserted {
                out.append(normalized)
            }
        }
        return out
    }

    func isShortAcronymToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 2 || t.count > 5 { return false }
        let lower = t.lowercased()
        if Self.anchorStopwords.contains(lower) || Self.retrievalStopwords.contains(lower) { return false }
        return t.allSatisfy { $0.isLetter }
    }

    func exactQueryPhrases(from question: String) -> [String] {
        let source = normalizedAlphaNumericText(question)
        let words = source
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                if token.count < 2 { return false }
                if Self.retrievalStopwords.contains(token) { return false }
                return true
            }

        if words.count < 2 { return [] }
        var seen = Set<String>()
        var phrases: [String] = []

        for n in 2...3 {
            if words.count < n { continue }
            for i in 0...(words.count - n) {
                let endIndex = i + n
                guard endIndex <= words.count else { continue }
                let phrase = words[i..<endIndex].joined(separator: " ")
                if phrase.count < 6 { continue }
                if seen.insert(phrase).inserted {
                    phrases.append(phrase)
                }
            }
        }

        return phrases
    }

    func isNumberHeavyToken(_ token: String) -> Bool {
        if token.isEmpty { return false }
        let digits = token.filter { $0.isNumber }.count
        if digits == 0 { return false }
        if digits >= 3 { return true }
        return Double(digits) / Double(max(1, token.count)) >= 0.4
    }

    func containsExactToken(_ token: String, in normalizedText: String) -> Bool {
        normalizedText.contains(" \(token) ")
    }

    func exactMatchScores(
        exactTokens: [String],
        phrases: [String],
        text: String
    ) -> (exactToken: Double, phrase: Double, numeric: Double) {
        if exactTokens.isEmpty && phrases.isEmpty {
            return (0, 0, 0)
        }

        let normalizedText = normalizedAlphaNumericText(text)
        var exactMatched = 0
        var numericTotal = 0
        var numericMatched = 0

        for token in exactTokens {
            let matched = containsExactToken(token, in: normalizedText)
            if matched { exactMatched += 1 }
            if isNumberHeavyToken(token) {
                numericTotal += 1
                if matched { numericMatched += 1 }
            }
        }

        var phraseMatched = 0
        for phrase in phrases {
            if normalizedText.contains(" \(phrase) ") {
                phraseMatched += 1
            }
        }

        let exactScore = exactTokens.isEmpty ? 0 : Double(exactMatched) / Double(exactTokens.count)
        let phraseScore = phrases.isEmpty ? 0 : Double(phraseMatched) / Double(phrases.count)
        let numericScore = numericTotal == 0 ? 0 : Double(numericMatched) / Double(numericTotal)
        return (exactScore, phraseScore, numericScore)
    }

    func isAnaphoraFollowUp(_ q: String) -> Bool {
        let s = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = s.split { !$0.isLetter && !$0.isNumber }.count
        if tok > 10 { return false }

        let cues = [
            "which", "what", "when", "where", "who", "why", "how",
            "those", "that", "these", "this", "they", "them", "it", "there"
        ]
        return cues.contains(where: { s.contains($0) })
    }

    func compact(_ text: String, maxChars: Int) -> String {
        let t = cleanLine(text)
        if t.count <= maxChars { return t }
        return String(t.prefix(maxChars))
    }

    func makeThreadAnchor(history: [ChatMessage]) -> String? {
        // Get last user+assistant pair
        guard let lastAssistantIdx = history.lastIndex(where: { $0.role == "assistant" }) else { return nil }
        let lastAssistant = history[lastAssistantIdx].text
        let lastUser = history[..<lastAssistantIdx].last(where: { $0.role == "user" })?.text ?? ""

        let u = compact(lastUser, maxChars: 140)
        let a = compact(lastAssistant, maxChars: 180)

        if u.isEmpty && a.isEmpty { return nil }
        return "Thread context:\nUser: \(u)\nAssistant: \(a)\n\n"
    }

    func isLowSignalChitChat(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return true }

        let normalized = q
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let chit = ["hi", "hello", "hey", "thanks", "thank you", "ok", "okay", "are you ok", "you ok", "sup", "yo"]
        if chit.contains(normalized) { return true }

        if normalized.split(separator: " ").count <= 4,
           chit.contains(where: { normalized.hasPrefix($0 + " ") || normalized.hasSuffix(" " + $0) }) {
            return true
        }

        let tokens = retrievalTokens(question)
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        return tokens.isEmpty && exactTokens.isEmpty && phrases.isEmpty
    }

    func isExplicitSmallTalkPrompt(_ question: String) -> Bool {
        let normalized = cleanLine(question).lowercased()
        if normalized.isEmpty { return false }

        let direct = [
            "hi", "hello", "hey", "thanks", "thank you", "ok", "okay",
            "how are you", "how are you doing", "are you ok", "you ok", "sup", "yo"
        ]
        if direct.contains(normalized) { return true }

        // Emoji-only / symbol-only prompt with no letters or numbers.
        let hasAlphaNum = normalized.contains { $0.isLetter || $0.isNumber }
        if !hasAlphaNum { return true }
        return false
    }

    func isMetaDispute(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }

        let tokenCount = q.split { !$0.isLetter && !$0.isNumber }.count
        guard tokenCount <= 6 else { return false }

        if q.contains("check again") { return true }
        let tokens = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let cues: Set<String> = ["sure", "really", "yes", "no", "wrong"]
        return !tokens.intersection(cues).isEmpty
    }

    func isChallenge(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }
        let cues = [
            "are you sure",
            "how can you",
            "that's wrong",
            "you said",
            "but you",
            "clearly",
            "check again",
            "look again"
        ]
        return cues.contains(where: { q.contains($0) })
    }

    func lastContentfulUserQuestion(_ history: [ChatMessage]) -> String? {
        for msg in history.reversed() where msg.role == "user" {
            let text = cleanLine(msg.text)
            let tokenCount = text.split { !$0.isLetter && !$0.isNumber }.count
            if tokenCount < 4 { continue }
            if isChallenge(text) { continue }
            return text
        }
        return nil
    }

    func smallTalkReply(_ question: String) -> String {
        let s = cleanLine(question).lowercased()
        if s.contains("how are") { return "I'm good - what can I help you find in your documents?" }
        if s.contains("are you") {
            return "Yep. What do you want to do - search, summarize, or extract something?"
        }
        if s.contains("hello") || s.contains("hi") { return "Hey! What do you need help with?" }
        return "I'm here. What do you need?"
    }

    func updateSessionState(from primaryDocument: Document?) {
        sessionState.lastReferencedDocumentId = primaryDocument?.id
    }



    func rankedChunkHits(
        question: String,
        retrievalQuery: String? = nil,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool,
        queryAnalysis: QueryAnalysis? = nil
    ) -> [ChunkHit] {
        let queryForRetrieval = retrievalQuery ?? expandQueryWithAnalysis(question, analysis: queryAnalysis)
        let questionTokens = retrievalTokens(queryForRetrieval)
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        
        let scorer = QueryClassifier.makeScorerFor(QueryClassifier.classifyQuery(question))

        var rankedCandidates: [(document: Document, chunk: OCRChunk, features: ChunkLexicalFeatures)] = []
        var documentFrequency: [String: Int] = [:]
        var totalTokenCount = 0

        for doc in allDocs {
            let chunks = doc.ocrChunks.isEmpty
                ? [OCRChunk(documentId: doc.id, pageNumber: nil, text: doc.content)]
                : doc.ocrChunks

            for chunk in chunks {
                let features = buildChunkLexicalFeatures(for: chunk.text)
                if features.tokenSet.isEmpty { continue }
                rankedCandidates.append((document: doc, chunk: chunk, features: features))
                totalTokenCount += features.length
                for token in features.tokenSet {
                    documentFrequency[token, default: 0] += 1
                }
            }
        }

        let totalDocs = rankedCandidates.count
        let averageDocLength = totalDocs == 0 ? 1.0 : Double(totalTokenCount) / Double(totalDocs)
        var bm25ByChunkId: [UUID: Double] = [:]
        var maxBM25 = 0.0
        for candidate in rankedCandidates {
            let rawBM25 = bm25Score(
                queryTokens: questionTokens,
                termFreq: candidate.features.termFreq,
                docLength: candidate.features.length,
                documentFrequency: documentFrequency,
                totalDocs: totalDocs,
                averageDocLength: averageDocLength
            )
            bm25ByChunkId[candidate.chunk.chunkId] = rawBM25
            if rawBM25 > maxBM25 { maxBM25 = rawBM25 }
        }

        var hits: [ChunkHit] = []

        for candidate in rankedCandidates {
            let doc = candidate.document
            let chunk = candidate.chunk
            
            // Normalize BM25 score
            let normalizedBM25 = maxBM25 > 0 ? ((bm25ByChunkId[chunk.chunkId] ?? 0) / maxBM25) : 0
            
            // Calculate exact match score
            let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: chunk.text)
            let combinedExactMatch = max(exact.exactToken, exact.phrase, exact.numeric)
            
            let domainScore = scorer.score(
                normalizedBM25: normalizedBM25,
                exactMatchScore: combinedExactMatch,
                chunkText: chunk.text,
                question: question
            )
            
            // Add recency boost
            let isRecentDocument = applyLastDocumentBias && (preferredDocumentId == doc.id)
            let recencyScore = isRecentDocument ? 1.0 : 0.0
            let finalScore = domainScore + (recencyWeight * recencyScore)
            
            // Skip chunks with no meaningful signal
            if finalScore <= 0 {
                continue
            }

            hits.append(
                ChunkHit(
                    document: doc,
                    chunk: chunk,
                    bm25Score: normalizedBM25,
                    exactMatchScore: combinedExactMatch,
                    recencyScore: recencyScore,
                    finalScore: finalScore
                )
            )
        }

        return hits.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.bm25Score != rhs.bm25Score { return lhs.bm25Score > rhs.bm25Score }
            return lhs.document.dateCreated > rhs.document.dateCreated
        }
    }

    struct PassBHitScore {
        let hit: ChunkHit
        let score: Double
    }

    func isCountQuestion(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }
        return q.contains("how many") || q.contains("number of") || q.contains("count") || q.contains("total")
    }

    func normalizedForMatching(_ text: String) -> String {
        cleanLine(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    func strongestSubjectAnchorToken(from question: String) -> String? {
        anchorTokens(from: question).first.map { normalizedForMatching($0) }
    }

    func passBFeatures(
        for hit: ChunkHit,
        subjectToken: String?,
        questionTokens: Set<String>
    ) -> (subjectMatch: Bool, queryKeywordMatches: Int) {
        let chunkNormalized = normalizedForMatching(hit.chunk.text)
        let subjectMatch = subjectToken.map { chunkNormalized.contains($0) } ?? false
        let chunkTokens = retrievalTokens(hit.chunk.text)
        let queryKeywordMatches = questionTokens.intersection(chunkTokens).count
        return (subjectMatch, queryKeywordMatches)
    }

    func chunkContainsDigits(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    func passAChunkCandidates(from hits: [ChunkHit]) -> [ChunkHit] {
        if hits.isEmpty { return [] }
        let perDocLimit = 10
        let candidateCap = 80

        var docOrder: [UUID] = []
        var grouped: [UUID: [ChunkHit]] = [:]
        for hit in hits {
            let docId = hit.document.id
            if grouped[docId] == nil {
                grouped[docId] = []
                docOrder.append(docId)
            }
            grouped[docId]?.append(hit)
        }

        var merged: [ChunkHit] = []
        merged.reserveCapacity(candidateCap)
        for docId in docOrder {
            guard let docHits = grouped[docId] else { continue }
            merged.append(contentsOf: docHits.prefix(perDocLimit))
            if merged.count >= candidateCap { break }
        }

        if merged.count > candidateCap {
            return Array(merged.prefix(candidateCap))
        }
        return merged
    }

    func passBRerankScore(
        for hit: ChunkHit,
        scorer: QueryScorer,
        subjectToken: String?,
        questionTokens: Set<String>
    ) -> Double {
        let baseScore = scorer.score(
            normalizedBM25: hit.bm25Score,
            exactMatchScore: hit.exactMatchScore,
            chunkText: hit.chunk.text,
            question: ""
        )

        let features = passBFeatures(
            for: hit,
            subjectToken: subjectToken,
            questionTokens: questionTokens
        )

        // Gradient subject bonus instead of binary cliff:
        // - Exact subject match: +0.50
        // - Keyword coverage bonus: scales with how many query tokens appear (up to +0.40)
        // - Original Pass A score (finalScore) preserved as tiebreaker via baseScore
        let subjectBonus = features.subjectMatch ? 0.50 : 0.0
        let keywordCoverage = questionTokens.isEmpty ? 0.0
            : min(1.0, Double(features.queryKeywordMatches) / Double(max(1, questionTokens.count)))
        let keywordBonus = 0.40 * keywordCoverage

        return baseScore + subjectBonus + keywordBonus
    }

    func twoPassContextHits(from hits: [ChunkHit], question: String) -> [ChunkHit] {
        let passA = passAChunkCandidates(from: hits)
        if passA.isEmpty { return [] }

        let scorer = QueryClassifier.makeScorerFor(QueryClassifier.classifyQuery(question))
        let subjectToken = strongestSubjectAnchorToken(from: question)
        let questionTokens = retrievalTokens(question)

        let reranked = passA.map { hit in
            PassBHitScore(
                hit: hit,
                score: passBRerankScore(
                    for: hit,
                    scorer: scorer,
                    subjectToken: subjectToken,
                    questionTokens: questionTokens
                )
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.finalScore != rhs.hit.finalScore { return lhs.hit.finalScore > rhs.hit.finalScore }
            return lhs.hit.document.dateCreated > rhs.hit.document.dateCreated
        }
        return Array(reranked.prefix(passBTopEvidenceLimit).map(\.hit))
    }

    func expandedHitsWithNeighbors(from hits: [ChunkHit], allHits: [ChunkHit]) -> [ChunkHit] {
        if hits.isEmpty { return [] }
        var byChunkId: [UUID: ChunkHit] = [:]
        for hit in allHits {
            if let existing = byChunkId[hit.chunk.chunkId], existing.finalScore >= hit.finalScore {
                continue
            }
            byChunkId[hit.chunk.chunkId] = hit
        }

        var output: [ChunkHit] = []
        var seen = Set<UUID>()

        // Phase 1: Guarantee ALL seeds get a slot first
        for seed in hits {
            if seen.insert(seed.chunk.chunkId).inserted {
                output.append(seed)
            }
        }

        // Phase 2: Add neighbors with remaining budget
        if output.count < expandedEvidenceLimit {
            for seed in hits {
                let chunks = seed.document.ocrChunks.isEmpty ? [seed.chunk] : seed.document.ocrChunks
                guard let centerIndex = chunks.firstIndex(where: { $0.chunkId == seed.chunk.chunkId }) else {
                    continue
                }

                for offset in [-1, 1] {
                    let idx = centerIndex + offset
                    guard idx >= 0, idx < chunks.count else { continue }
                    let candidateChunk = chunks[idx]
                    if let seedPage = seed.chunk.pageNumber, let candidatePage = candidateChunk.pageNumber, seedPage != candidatePage {
                        continue
                    }
                    let resolved = byChunkId[candidateChunk.chunkId] ?? seed
                    if seen.insert(resolved.chunk.chunkId).inserted {
                        output.append(resolved)
                        if output.count >= expandedEvidenceLimit { break }
                    }
                }
                if output.count >= expandedEvidenceLimit { break }
            }
        }

        return output.isEmpty ? hits : output
    }

    func passesAdaptiveEvidenceThreshold(_ hits: [ChunkHit]) -> Bool {
        guard !hits.isEmpty else { return false }
        let sortedScores = hits.map(\.finalScore).sorted(by: >)
        let best = sortedScores[0]
        if best >= evidenceAbsoluteFloor { return true }
        let median = sortedScores[sortedScores.count / 2]
        if best >= (median + evidenceMedianMargin) { return true }
        let second = sortedScores.count > 1 ? sortedScores[1] : best
        let gap = best - second
        return gap >= evidenceGapThreshold
    }

    func selectDocumentsByChunkRanking(
        question: String,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool,
        retrievalQuery: String? = nil,
        queryAnalysis: QueryAnalysis? = nil
    ) -> DocumentSelectionResult {
        if allDocs.isEmpty {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: []
            )
        }
        let candidateDocs = anchorFilteredDocuments(question: question, docs: allDocs)

        let hits = rankedChunkHits(
            question: question,
            retrievalQuery: retrievalQuery,
            allDocs: candidateDocs,
            preferredDocumentId: preferredDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            queryAnalysis: queryAnalysis
        )
        if hits.isEmpty {
            let fallbackScored = fallbackScoredSelection(
                question: question,
                allDocs: candidateDocs,
                retrievalQuery: retrievalQuery
            )
            let fallbackDocs = fallbackScored.map { $0.document }
            let fallbackScores = Dictionary(
                uniqueKeysWithValues: fallbackScored.map { ($0.document.id, max($0.score, 0.0001)) }
            )
            return DocumentSelectionResult(
                documents: fallbackDocs,
                primaryDocument: fallbackDocs.first,
                topScoreByDocumentId: fallbackScores,
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }
        if !passesAdaptiveEvidenceThreshold(hits) {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }

        let contextHits = expandedHitsWithNeighbors(
            from: twoPassContextHits(from: hits, question: question),
            allHits: hits
        )
        if contextHits.isEmpty {
            let fallbackScored = fallbackScoredSelection(
                question: question,
                allDocs: candidateDocs,
                retrievalQuery: retrievalQuery
            )
            let fallbackDocs = fallbackScored.map { $0.document }
            let fallbackScores = Dictionary(
                uniqueKeysWithValues: fallbackScored.map { ($0.document.id, max($0.score, 0.0001)) }
            )
            return DocumentSelectionResult(
                documents: fallbackDocs,
                primaryDocument: fallbackDocs.first,
                topScoreByDocumentId: fallbackScores,
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }

        var selected: [Document] = []
        var seenDocIds = Set<UUID>()
        var topScoreByDocumentId: [UUID: Double] = [:]

        for hit in contextHits {
            let docId = hit.document.id
            topScoreByDocumentId[docId] = max(topScoreByDocumentId[docId] ?? 0, hit.finalScore)
            if seenDocIds.contains(docId) { continue }
            seenDocIds.insert(docId)
            selected.append(hit.document)
            if selected.count >= selectionMaxDocs { break }
        }

        if selected.isEmpty {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: contextHits,
                allRankedHits: hits
            )
        }

        let primaryDocId = contextHits.first?.document.id
        let primaryDocument = primaryDocId.flatMap { id in selected.first { $0.id == id } } ?? selected.first
        let selectedScores = Dictionary(
            uniqueKeysWithValues: selected.map { doc in
                (doc.id, max(topScoreByDocumentId[doc.id] ?? 0.0001, 0.0001))
            }
        )
        return DocumentSelectionResult(
            documents: selected,
            primaryDocument: primaryDocument,
            topScoreByDocumentId: selectedScores,
            retrievalQueryUsed: retrievalQuery,
            selectedHits: contextHits,
            allRankedHits: hits
        )
    }

    func logRetrievalTrace(
        question: String,
        selection: DocumentSelectionResult
    ) {
        let hits = selection.selectedHits
        let globalHits = selection.allRankedHits
        let topK = 10

        // PRIVACY: entire trace is gated to debug builds — it prints user questions
        // and document snippets which must never appear in production/release logs.
        #if DEBUG
        print("================ RETRIEVAL TRACE ================")
        print("Question: \"\(cleanLine(question))\"")
        print("")
        print("Top K Global Chunks (pre Pass A, K = \(topK)):")
        print("")

        if globalHits.isEmpty {
            print("(no chunk hits)")
            print("")
        } else {
            for (index, hit) in globalHits.prefix(topK).enumerated() {
                let page = hit.chunk.pageNumber.map { "Page \($0)" } ?? "Page ?"
                let snippet = trimToCharBudget(hit.chunk.text, maxChars: 520)

                print("[\(index + 1)] Score: \(String(format: "%.2f", hit.finalScore))")
                print("Doc: \(hit.document.title)")
                print("Chunk: \(hit.chunk.chunkId.uuidString) \(page)")
                print("----------------------------------------")
                print("\"\(snippet)\"")
                print("----------------------------------------")
                print("")
            }
        }

        print("Top K Selected Evidence Chunks (post Pass B, K = \(topK)):")
        print("")

        if hits.isEmpty {
            print("(no selected evidence chunks)")
            print("")
        } else {
            for (index, hit) in hits.prefix(topK).enumerated() {
                let page = hit.chunk.pageNumber.map { "Page \($0)" } ?? "Page ?"
                let snippet = trimToCharBudget(hit.chunk.text, maxChars: 520)

                print("[\(index + 1)] Score: \(String(format: "%.2f", hit.finalScore))")
                print("Doc: \(hit.document.title)")
                print("Chunk: \(hit.chunk.chunkId.uuidString) \(page)")
                print("----------------------------------------")
                print("\"\(snippet)\"")
                print("----------------------------------------")
                print("")
            }
        }

        let scores = globalHits.map(\.finalScore).sorted(by: >)
        let best = scores.first ?? 0
        let median = scores.isEmpty ? 0 : scores[scores.count / 2]
        let second = scores.count > 1 ? scores[1] : best
        let gap = best - second
        print("AdaptiveThreshold floor=\(String(format: "%.2f", evidenceAbsoluteFloor)) median+margin=\(String(format: "%.2f", evidenceMedianMargin)) gap=\(String(format: "%.2f", evidenceGapThreshold))")
        print("EvidenceStats best=\(String(format: "%.2f", best)) median=\(String(format: "%.2f", median)) gap=\(String(format: "%.2f", gap))")
        print("=================================================")
        #endif
    }

    func retrySelectionWithExpandedQueryIfNeeded(
        question: String,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool,
        currentSelection: DocumentSelectionResult,
        queryAnalysis: QueryAnalysis? = nil
    ) -> DocumentSelectionResult {
        if !currentSelection.selectedHits.isEmpty { return currentSelection }

        let expanded = expandQueryWithAnalysis(question, analysis: queryAnalysis)
        if cleanLine(expanded).lowercased() == cleanLine(question).lowercased() {
            return currentSelection
        }

        let retried = selectDocumentsByChunkRanking(
            question: question,
            allDocs: allDocs,
            preferredDocumentId: preferredDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            retrievalQuery: expanded,
            queryAnalysis: queryAnalysis
        )
        // If the retry still found no selected hits but the initial run had ranked hits,
        // keep the initial selection so its allRankedHits are not discarded.
        if retried.selectedHits.isEmpty && !currentSelection.allRankedHits.isEmpty {
            return currentSelection
        }
        return retried
    }

    struct RankedSnippet {
        let text: String
        let score: Double
    }

    func shouldIncludeOCR(question: String, document: Document, rank: Int) -> Bool {
        let q = cleanLine(question).lowercased()
        let triggers = [
            "ocr", "text", "verbatim", "quote", "exact", "page", "line", "paragraph"
        ]
        let explicitTrigger = triggers.contains { q.contains($0) }
        let hasOCRData = !(document.ocrPages?.isEmpty ?? true) || !document.ocrChunks.isEmpty
        if !hasOCRData { return false }
        if explicitTrigger { return true }
        if rank < defaultOCRDocCount { return true }
        if document.type == .scanned || document.type == .image { return true }
        let compactContent = cleanLine(document.content)
        if compactContent.count < lowExtractedTextThreshold { return true }
        return false
    }

    func trimToCharBudget(_ text: String, maxChars: Int) -> String {
        if maxChars <= 0 { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        
        // Use limitedBy for safe indexing
        guard let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxChars, limitedBy: trimmed.endIndex) else {
            return trimmed
        }
        
        let prefix = String(trimmed[..<cutoff])
        if let lastBoundary = prefix.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            return String(prefix[..<lastBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func contentSnippetCandidates(_ text: String) -> [String] {
        let compact = cleanLine(text)
        if compact.isEmpty { return [] }

        let paragraphs = text
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { $0.count >= 24 }
        if !paragraphs.isEmpty {
            return Array(paragraphs.prefix(60))
        }

        if compact.count <= maxSnippetChars {
            return [compact]
        }

        var chunks: [String] = []
        var start = compact.startIndex
        while start < compact.endIndex {
            let end = compact.index(start, offsetBy: maxSnippetChars, limitedBy: compact.endIndex) ?? compact.endIndex
            let chunk = String(compact[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            if end == compact.endIndex { break }
            start = end
        }
        return chunks
    }

    func snippetRelevanceScore(
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        text: String
    ) -> Double {
        let semantic = semanticOverlapScore(
            questionTokens: questionTokens,
            chunkTokens: retrievalTokens(text)
        )
        let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: text)
        let combinedExact = max(exact.exactToken, exact.phrase, exact.numeric)
        return (0.70 * semantic) + (0.25 * combinedExact)
    }

    func topRankedSnippets(
        candidates: [String],
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        limit: Int
    ) -> [String] {
        if candidates.isEmpty { return [] }
        let ranked = candidates.prefix(90).map { snippet in
            RankedSnippet(
                text: trimToCharBudget(snippet, maxChars: maxSnippetChars),
                score: snippetRelevanceScore(
                    questionTokens: questionTokens,
                    exactTokens: exactTokens,
                    phrases: phrases,
                    text: snippet
                )
            )
        }
        let sorted = ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.text.count > rhs.text.count
        }
        var seen = Set<String>()
        var out: [String] = []
        for snippet in sorted {
            if out.count >= limit { break }
            let key = snippet.text.lowercased()
            if key.isEmpty { continue }
            if seen.insert(key).inserted {
                out.append(snippet.text)
            }
        }
        return out
    }

    func buildDocumentContextBlock(
        document: Document,
        rank: Int,
        question: String,
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        pathMap: [UUID: String],
        formatter: DateFormatter
    ) -> String {
        let folderPath = document.folderId.flatMap { pathMap[$0] } ?? "Root"
        let summary = trimToCharBudget(document.summary, maxChars: maxSummaryCharsPerDoc)
        let includeOCR = shouldIncludeOCR(question: question, document: document, rank: rank)

        let contentCandidates = contentSnippetCandidates(document.content)
        let contentSnippets = topRankedSnippets(
            candidates: contentCandidates,
            questionTokens: questionTokens,
            exactTokens: exactTokens,
            phrases: phrases,
            limit: maxSnippetsPerDoc
        )

        let ocrCandidates: [String] = includeOCR
            ? document.ocrChunks.map { chunk in
                let pagePrefix = chunk.pageNumber.map { "Page \($0): " } ?? ""
                return "\(pagePrefix)\(chunk.text)"
            }
            : []
        let ocrSnippets = topRankedSnippets(
            candidates: ocrCandidates,
            questionTokens: questionTokens,
            exactTokens: exactTokens,
            phrases: phrases,
            limit: maxOCRSnippetsPerDoc
        )

        let contentSection = contentSnippets.isEmpty
            ? "ContentSnippets: None"
            : "ContentSnippets:\n" + contentSnippets.map { "- \($0)" }.joined(separator: "\n")
        let ocrSection = ocrSnippets.isEmpty
            ? "OCRSnippets: None"
            : "OCRSnippets:\n" + ocrSnippets.map { "- \($0)" }.joined(separator: "\n")

        return """
        DocId: \(document.id.uuidString)
        Title: \(document.title)
        Folder: \(folderPath)
        Type: \(document.type.rawValue)
        Tags: \(document.tags.joined(separator: ", "))
        Date: \(formatter.string(from: document.dateCreated))
        Summary: \(summary)
        \(contentSection)
        \(ocrSection)
        """
    }

    func contextBudgetShares(
        selected: [Document],
        topScoreByDocumentId: [UUID: Double]
    ) -> [Double] {
        if selected.isEmpty { return [] }
        if selected.count == 1 { return [1.0] }

        let rankShares: [Double]
        if selected.count == 2 {
            rankShares = [0.65, 0.35]
        } else {
            let tailShare = 0.30 / Double(selected.count - 2)
            rankShares = [0.45, 0.25] + Array(repeating: tailShare, count: selected.count - 2)
        }

        let rawScores = selected.map { max(topScoreByDocumentId[$0.id] ?? 0, 0) }
        let scoreSum = rawScores.reduce(0, +)
        let scoreShares = scoreSum > 0
            ? rawScores.map { $0 / scoreSum }
            : rankShares

        let blended = zip(rankShares, scoreShares).map { rankShare, scoreShare in
            (0.7 * rankShare) + (0.3 * scoreShare)
        }
        let blendedSum = blended.reduce(0, +)
        guard blendedSum > 0 else { return rankShares }
        return blended.map { $0 / blendedSum }
    }

    func buildSelectedDocumentContext(
        selected: [Document],
        question: String,
        topScoreByDocumentId: [UUID: Double]
    ) -> String {
        if selected.isEmpty { return "No relevant documents selected." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        let questionTokens = retrievalTokens(expandQuery(question))
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        let shares = contextBudgetShares(selected: selected, topScoreByDocumentId: topScoreByDocumentId)

        var remainingBudget = activeContextCharBudget
        var blocks: [String] = []

        for (index, doc) in selected.enumerated() {
            if remainingBudget <= minContextReserveChars { break }
            let block = buildDocumentContextBlock(
                document: doc,
                rank: index,
                question: question,
                questionTokens: questionTokens,
                exactTokens: exactTokens,
                phrases: phrases,
                pathMap: pathMap,
                formatter: formatter
            )
            let share = index < shares.count ? shares[index] : (1.0 / Double(max(1, selected.count)))
            let targetBudget = max(900, Int(Double(activeContextCharBudget) * share))
            let blockBudget = min(remainingBudget, targetBudget)
            let trimmedBlock = trimToCharBudget(block, maxChars: blockBudget)
            if trimmedBlock.isEmpty { continue }
            blocks.append(trimmedBlock)
            remainingBudget -= (trimmedBlock.count + 8)
        }

        if blocks.isEmpty, let first = selected.first {
            let fallback = """
            DocId: \(first.id.uuidString)
            Title: \(first.title)
            Summary: \(trimToCharBudget(first.summary, maxChars: maxSummaryCharsPerDoc))
            """
            return trimToCharBudget(fallback, maxChars: activeContextCharBudget)
        }

        return blocks.joined(separator: "\n---\n")
    }

    func fallbackScoredSelection(
        question: String,
        allDocs: [Document],
        limit: Int = 6,
        retrievalQuery: String? = nil
    ) -> [(document: Document, score: Double)] {
        if allDocs.isEmpty { return [] }
        let candidateDocs = anchorFilteredDocuments(question: question, docs: allDocs)
        let expanded = retrievalQuery ?? expandQuery(question)
        let questionTokens = retrievalTokens(expanded)
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        let scored = candidateDocs.map { doc -> (Document, Double) in
            let metadata = "\(doc.title) \(doc.tags.joined(separator: " ")) \(doc.summary)"
            let lexical = normalizedMatchScore(questionTokens: questionTokens, text: metadata)
            let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: metadata)
            let combinedExact = max(exact.exactToken, exact.phrase, exact.numeric)
            let score = lexical + (0.25 * combinedExact)
            return (doc, score)
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.dateCreated > b.0.dateCreated
        }
        let top = sorted.prefix(limit).map { (document: $0.0, score: $0.1) }
        let maxScore = top.map { $0.score }.max() ?? 0
        if maxScore <= 0 {
            return []
        }
        return top
    }

    func buildAnswerPrompt(
        question: String,
        selectedDocs: [Document],
        topScoreByDocumentId: [UUID: Double],
        selectedHits: [ChunkHit]
    ) -> String {
        let evidence = buildEvidenceFromSelectedHits(selectedHits, maxChars: activeContextCharBudget)
        let historyBlock = buildConversationHistoryBlock()

        return """
        SYSTEM:
        \(chatPreprompt)
        \(historyBlock)
        QUESTION:
        \(question)

        PASSAGES:
        \(evidence)
        """
    }

    func buildConversationHistoryBlock() -> String {
        let prior = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard prior.count >= 2 else { return "" }
        let turns = prior.suffix(8) // up to 4 user+assistant pairs
        var lines = "\n\nCONVERSATION_HISTORY:\n"
        for msg in turns {
            let label = msg.role == "user" ? "User" : "Assistant"
            let trimmed = String(msg.text.prefix(300))
            lines += "\(label): \(trimmed)\n"
        }
        return lines
    }

    func buildEvidenceFromSelectedHits(_ hits: [ChunkHit], maxChars: Int) -> String {
        if hits.isEmpty { return "None" }

        // Deduplicate overlapping chunks (neighbor expansion can create near-duplicates)
        let dedupedHits = deduplicateChunkHits(hits)

        // Group by document for clearer context
        var grouped: [(title: String, chunks: [String])] = []
        var docOrder: [UUID] = []
        var byDoc: [UUID: [String]] = [:]

        for hit in dedupedHits {
            let docId = hit.document.id
            if byDoc[docId] == nil {
                docOrder.append(docId)
                byDoc[docId] = []
            }
            let text = trimToCharBudget(normalizeSpacedLetters(hit.chunk.text), maxChars: 420)
            byDoc[docId]?.append(text)
        }

        for docId in docOrder {
            let title = dedupedHits.first(where: { $0.document.id == docId })?.document.title ?? "Unknown"
            grouped.append((title: title, chunks: byDoc[docId] ?? []))
        }

        // Build output with document grouping
        var out: [String] = []
        for group in grouped {
            let header = "[\(group.title)]"
            let body = group.chunks.joined(separator: "\n\n")
            out.append("\(header)\n\(body)")
        }

        let joined = out.joined(separator: "\n\n")
        return trimToCharBudget(joined, maxChars: maxChars)
    }

    /// Remove near-duplicate chunks based on token overlap (Jaccard > 0.75)
    func deduplicateChunkHits(_ hits: [ChunkHit]) -> [ChunkHit] {
        if hits.count <= 1 { return hits }
        var result: [ChunkHit] = []
        var seenTokenSets: [Set<String>] = []

        for hit in hits {
            let tokens = retrievalTokens(hit.chunk.text)
            let isDuplicate = seenTokenSets.contains { existing in
                let intersection = tokens.intersection(existing).count
                let union = tokens.union(existing).count
                return union > 0 && Double(intersection) / Double(union) > 0.75
            }
            if !isDuplicate {
                result.append(hit)
                seenTokenSets.append(tokens)
            }
        }
        return result
    }

    func buildPrompt(for question: String) -> String {
        """
        SYSTEM:
        \(chatPreprompt)

        USER:
        \(question)
        """
    }

    /// Re-examination prompt: used when the user challenges or disputes a previous answer.
    /// Gives the model full context of the prior exchange and instructs it to try harder
    /// before we fall back to showing raw chunks.
    func buildReexaminationPrompt(
        question: String,
        originalQuestion: String?,
        lastResponse: String?,
        selectedHits: [ChunkHit]
    ) -> String {
        let evidence = buildEvidenceFromSelectedHits(selectedHits, maxChars: activeContextCharBudget)
        let historyBlock = buildConversationHistoryBlock()

        let reexamInstruction: String
        if let orig = originalQuestion, let last = lastResponse {
            reexamInstruction = """

            PRIOR_EXCHANGE:
            User asked: \(compact(orig, maxChars: 200))
            You answered: \(compact(last, maxChars: 200))

            The user is now questioning or following up on that answer. Re-examine the passages carefully. Correct any mistake you made or give a fuller explanation. Answer directly and specifically based only on what the passages say.
            """
        } else {
            reexamInstruction = "\nLook carefully through every passage and give a direct, specific answer."
        }

        return """
        SYSTEM:
        \(chatPreprompt)
        \(historyBlock)
        \(reexamInstruction)

        QUESTION:
        \(question)

        PASSAGES:
        \(evidence)
        """
    }

    /// Exploratory prompt: used when the user challenges a previous answer or when
    /// the standard prompt failed. Asks the LLM to write a short intro, then we
    /// append the raw chunk quotes so the user can see the evidence directly.
    func buildExploratoryPrompt(
        question: String,
        originalQuestion: String?,
        lastResponse: String?,
        selectedHits: [ChunkHit]
    ) -> String {
        let evidence = buildEvidenceFromSelectedHits(selectedHits, maxChars: activeContextCharBudget)

        let contextBlock: String
        if let orig = originalQuestion, let last = lastResponse {
            contextBlock = """
            Previous question: \(compact(orig, maxChars: 200))
            Previous answer: \(compact(last, maxChars: 200))
            User's follow-up: \(question)
            """
        } else {
            contextBlock = "Question: \(question)"
        }

        return """
        SYSTEM:
        The user is looking for specific information. You found some relevant sections in their documents. Write a SHORT intro (1 sentence) like "I found these relevant sections:" or "I'm not sure about the exact answer, but here are the closest matches:" — then write STOP.

        Do NOT try to answer the question yourself. Just write the intro sentence and STOP. The evidence will be shown separately.

        EVIDENCE:
        \(evidence)

        CONTEXT:
        \(contextBlock)
        """
    }

    /// Build a direct-quote response: short LLM intro + raw chunk text in quotes.
    /// This bypasses LLM extraction entirely — the user sees the actual evidence.
    func buildDirectQuoteResponse(
        introReply: String,
        selectedHits: [ChunkHit]
    ) -> String {
        let dedupedHits = deduplicateChunkHits(selectedHits)
        let count = min(3, dedupedHits.count)

        // Hardcoded intro — no LLM text to avoid rambling
        var parts: [String] = ["I found \(count) relevant section\(count == 1 ? "" : "s"):\n"]
        for (i, hit) in dedupedHits.prefix(3).enumerated() {
            let chunkText = trimToCharBudget(hit.chunk.text, maxChars: 500)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("\(i + 1).\n>>>\n\(chunkText)\n<<<\n")
        }

        return parts.joined(separator: "\n")
    }

    func extractFirstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find first sentence ending
        if let range = trimmed.range(of: #"[.!?]"#, options: .regularExpression) {
            return String(trimmed[...range.lowerBound]) + "."
        }
        // No sentence ending found — take first 120 chars
        return String(trimmed.prefix(120))
    }

    /// Check if the LLM response is a "not found" variant
    func isNotFoundResponse(_ reply: String) -> Bool {
        let lower = reply.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let notFoundPhrases = [
            "not specified in the documents",
            "not found in the documents",
            "not mentioned in the",
            "no relevant information",
            "i couldn't find",
            "i could not find",
            "does not contain",
            "no information about",
            "not available in the"
        ]
        return notFoundPhrases.contains { lower.contains($0) }
    }

    func analyzeQueryIntent(edgeAI: EdgeAI, question: String, recentContext: String) async throws -> QueryAnalysis? {
        let analysisPrompt = """
        Analyze this user query and return ONLY valid JSON (no markdown, no explanation).

        Recent conversation:
        \(recentContext)

        Current query: "\(question)"

        Return JSON with this exact structure:
        {
          "intent": "ask_doc_fact" | "followup_clarification" | "challenge_dispute" | "smalltalk" | "new_topic",
          "rewritten_query": "standalone version of the query",
          "focus_terms": ["term1", "term2"],
          "soft_expansions": ["synonym1", "paraphrase1"],
          "language": "en",
          "needs_previous_doc_bias": false,
          "expected_answer_type": "paragraph",
          "must_not_answer": false
        }

        Rules:
        - "rewritten_query": Rewrite the current query as a STANDALONE search query that includes all necessary context from the conversation. If the user says "and when was it signed?" after asking about a document, rewrite as "When was the document signed?". If the query is already standalone, copy it as-is.
        - "intent": "challenge_dispute" if questioning previous answer; "followup_clarification" if refining previous question; "smalltalk" if greeting; "new_topic" if unrelated to conversation; else "ask_doc_fact"
        - "focus_terms": 2-6 key search tokens (entities, proper nouns, numbers)
        - "soft_expansions": 1-4 synonyms (e.g., "EU" → "European Union")
        - "needs_previous_doc_bias": true only for direct follow-ups about the same document
        - "must_not_answer": true only for "that's wrong" / "check again" type challenges

        Return ONLY the JSON object.
        """

        let response = try await callLLM(edgeAI: edgeAI, prompt: analysisPrompt)

        // Extract JSON from response (handle potential markdown wrapping)
        let jsonString: String
        if let jsonStart = response.range(of: "{"),
           let jsonEnd = response.range(of: "}", options: .backwards),
           jsonStart.lowerBound < jsonEnd.upperBound {
            let extractedRange = jsonStart.lowerBound..<jsonEnd.upperBound
            jsonString = String(response[extractedRange])
        } else {
            print("[QueryAnalysis] Failed to extract JSON from response: \(response.prefix(200))")
            return nil
        }

        guard let jsonData = jsonString.data(using: .utf8) else {
            print("[QueryAnalysis] Failed to convert JSON string to data")
            return nil
        }

        do {
            let analysis = try JSONDecoder().decode(QueryAnalysis.self, from: jsonData)
            print("[QueryAnalysis] Intent: \(analysis.intent), Rewritten: \(analysis.rewrittenQuery)")
            print("[QueryAnalysis] Focus: \(analysis.focusTerms.joined(separator: ", "))")
            print("[QueryAnalysis] Expansions: \(analysis.softExpansions.joined(separator: ", "))")
            return analysis
        } catch {
            print("[QueryAnalysis] JSON decode failed: \(error)")
            return nil
        }
    }

    func callChatLLM(edgeAI: EdgeAI, question: String) async throws -> ChatLLMResult {
        if let statsAnswer = buildStatsAnswerIfNeeded(for: question) {
            return ChatLLMResult(reply: statsAnswer, primaryDocument: nil, rewrittenQuery: nil)
        }
        let scopedDocsRaw = !scopedDocumentIds.isEmpty ? scopedDocumentsForSelection() : []
        let docsInScopeCount = !scopedDocumentIds.isEmpty
            ? scopedDocsRaw.count
            : documentManager.conversationEligibleDocuments().count

        // STEP 1: LLM-based query analysis (before heuristics)
        let recentContext = messages.suffix(3).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let queryAnalysis: QueryAnalysis?

        let needsLLMAnalysis: Bool = {
            let wordCount = question.split(separator: " ").count
            if wordCount >= 8 { return true }
            let lower = question.lowercased()
            let pronounPatterns = [#"\bit\b"#, #"\bthey\b"#, #"\bthis\b"#, #"\bthat\b"#,
                                   #"\bits\b"#, #"\bhe\b"#, #"\bshe\b"#, #"\bthem\b"#, #"\btheir\b"#]
            if pronounPatterns.contains(where: { (try? NSRegularExpression(pattern: $0))?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil }) {
                return true
            }
            return ["vs", "versus", "compared", "between", "differ", "difference"].contains(where: { lower.contains($0) })
        }()

        do {
            queryAnalysis = needsLLMAnalysis
                ? try await analyzeQueryIntent(edgeAI: edgeAI, question: question, recentContext: recentContext)
                : nil
        } catch {
            AppLogger.ui.warning("Query intent analysis failed: \(error.localizedDescription)")
            queryAnalysis = nil
        }
        
        // STEP 2: Detect challenge/dispute — but don't skip retrieval.
        // Instead, proceed with retrieval using the rewritten query and use
        // an exploratory prompt that shows what was found.
        let isChallengeDispute = queryAnalysis?.intent == "challenge_dispute" || queryAnalysis?.mustNotAnswer == true || isChallenge(question) || isMetaDispute(question)

        // STEP 3: Use LLM-rewritten query for retrieval (replaces old anaphora/thread-anchor heuristics)
        let hasThreadHistory = messages.contains { $0.role == "assistant" } && messages.contains { $0.role == "user" }

        // The rewritten query is the standalone search query from the LLM analysis.
        // For new_topic intent, always use the raw question — the rewrite can contaminate
        // retrieval with prior-turn terms and pull the same chunks for different subjects.
        // Fall back to heuristic thread-anchor approach only when LLM analysis fails.
        let effectiveQuestion: String
        let isNewTopic = queryAnalysis?.intent == "new_topic"
        if !isNewTopic, let rewritten = queryAnalysis?.rewrittenQuery, !rewritten.isEmpty {
            effectiveQuestion = rewritten
            print("[QueryRewrite] Using LLM rewrite: \(rewritten)")
        } else if isNewTopic {
            effectiveQuestion = question
            print("[QueryRewrite] New topic — using raw question")
        } else {
            // Heuristic fallback: thread anchor for short follow-ups
            let anchorFollowUp = isAnaphoraFollowUp(question) ||
                (hasThreadHistory && cleanLine(question).split { !$0.isLetter && !$0.isNumber }.count <= 6)
            let questionAnchors = anchorTokens(from: question)
            if questionAnchors.isEmpty, anchorFollowUp, let anchor = makeThreadAnchor(history: self.messages) {
                effectiveQuestion = anchor + question
            } else {
                effectiveQuestion = question
            }
            print("[QueryRewrite] Using heuristic fallback: \(effectiveQuestion.prefix(120))")
        }

        // Check for smalltalk via analysis
        if queryAnalysis?.intent == "smalltalk" {
            return ChatLLMResult(reply: smallTalkReply(question), primaryDocument: nil, rewrittenQuery: nil)
        }
        if docsInScopeCount == 0 && isLowSignalChitChat(question) {
            return ChatLLMResult(reply: smallTalkReply(question), primaryDocument: nil, rewrittenQuery: nil)
        }
        if docsInScopeCount > 0 && !hasThreadHistory && isExplicitSmallTalkPrompt(question) {
            return ChatLLMResult(reply: smallTalkReply(question), primaryDocument: nil, rewrittenQuery: nil)
        }

        let allDocs = !scopedDocumentIds.isEmpty
            ? scopedDocsRaw
            : documentManager.conversationEligibleDocuments()

        // Use analysis to determine bias (prioritize LLM analysis over heuristics).
        // New topics must never inherit the previous document's bias.
        let applyLastDocumentBias: Bool
        if isNewTopic {
            applyLastDocumentBias = false
        } else if let analysis = queryAnalysis {
            applyLastDocumentBias = analysis.needsPreviousDocBias
        } else {
            let questionAnchors = anchorTokens(from: question)
            let anchorFollowUp = isAnaphoraFollowUp(question) ||
                (hasThreadHistory && cleanLine(question).split { !$0.isLetter && !$0.isNumber }.count <= 6)
            applyLastDocumentBias = questionAnchors.count < 2 || anchorFollowUp
        }
        let initialSelection = selectDocumentsByChunkRanking(
            question: effectiveQuestion,
            allDocs: allDocs,
            preferredDocumentId: sessionState.lastReferencedDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            queryAnalysis: queryAnalysis
        )
        let selection = retrySelectionWithExpandedQueryIfNeeded(
            question: effectiveQuestion,
            allDocs: allDocs,
            preferredDocumentId: sessionState.lastReferencedDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            currentSelection: initialSelection,
            queryAnalysis: queryAnalysis
        )

        logRetrievalTrace(
            question: effectiveQuestion,
            selection: selection
        )

        // Log retrieval for debugging and evaluation
        let hitLogs = selection.allRankedHits.map { hit in
            ChunkHitLog(
                documentId: hit.document.id,
                chunkId: hit.chunk.chunkId,
                finalScore: hit.finalScore,
                bm25Score: hit.bm25Score,
                exactMatchScore: hit.exactMatchScore,
                recencyScore: hit.recencyScore,
                chunkText: hit.chunk.text,
                pageNumber: hit.chunk.pageNumber
            )
        }
        RetrievalLogger.shared.log(
            question: effectiveQuestion,
            hits: hitLogs,
            selectedDocIds: selection.documents.map(\.id),
            primaryDocId: selection.primaryDocument?.id
        )

        // Determine hits to use: prefer selectedHits, fall back to top allRankedHits,
        // only bail out with hardcoded message when there are truly zero chunks.
        let hitsToUse: [ChunkHit]
        var docsToUse: [Document]
        var topScoresToUse: [UUID: Double]
        if !selection.selectedHits.isEmpty {
            hitsToUse = selection.selectedHits
            docsToUse = selection.documents
            topScoresToUse = selection.topScoreByDocumentId
        } else if !selection.allRankedHits.isEmpty {
            hitsToUse = Array(selection.allRankedHits.prefix(4))
            var seenIds = Set<UUID>()
            docsToUse = hitsToUse.compactMap { hit -> Document? in
                guard !seenIds.contains(hit.document.id) else { return nil }
                seenIds.insert(hit.document.id)
                return hit.document
            }
            topScoresToUse = hitsToUse.reduce(into: [:]) { result, hit in
                result[hit.document.id] = max(result[hit.document.id] ?? 0, max(hit.finalScore, 0.0001))
            }
        } else {
            return ChatLLMResult(reply: "Not specified in the documents.", primaryDocument: nil, rewrittenQuery: queryAnalysis?.rewrittenQuery)
        }

        // Always show the user's original question to the model — effectiveQuestion is for retrieval only.
        let finalReply: String
        if isChallengeDispute || queryAnalysis?.intent == "followup_clarification" {
            // Try harder first: give the model full context of the prior exchange and ask it to re-examine.
            let reexamPrompt = buildReexaminationPrompt(
                question: question,
                originalQuestion: sessionState.lastOriginalQuestion,
                lastResponse: sessionState.lastAssistantResponse,
                selectedHits: hitsToUse
            )
            let reexamReply = try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(reexamPrompt))
            // Only fall back to raw chunks if the model genuinely can't find the answer.
            if isNotFoundResponse(reexamReply) {
                finalReply = buildDirectQuoteResponse(introReply: reexamReply, selectedHits: hitsToUse)
            } else {
                finalReply = reexamReply
            }
        } else {
            let prompt = buildAnswerPrompt(
                question: question,
                selectedDocs: docsToUse,
                topScoreByDocumentId: topScoresToUse,
                selectedHits: hitsToUse
            )
            finalReply = try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(prompt))
        }

        // Store for future challenge/dispute handling
        sessionState.lastOriginalQuestion = question
        sessionState.lastAssistantResponse = finalReply

        return ChatLLMResult(reply: finalReply, primaryDocument: selection.primaryDocument, rewrittenQuery: queryAnalysis?.rewrittenQuery)
    }

    func buildStatsAnswerIfNeeded(for question: String) -> String? {
        let q = question.lowercased()
        let wantsCount = q.contains("how many") || q.contains("number of") || q.contains("count of") || q.contains("total")
        let mentionsDocs = q.contains("document") || q.contains("docs") || q.contains("files") || q.contains("uploaded")
        let mentionsFolders = q.contains("folder")
        if !wantsCount { return nil }
        if mentionsDocs || mentionsFolders {
            let docCount = documentManager.documents.count
            let folderCount = documentManager.folders.count
            if mentionsDocs && mentionsFolders {
                return "You currently have \(docCount) documents and \(folderCount) folders."
            }
            if mentionsDocs {
                return "You currently have \(docCount) documents."
            }
            return "You currently have \(folderCount) folders."
        }
        return nil
    }

    func scopedDocumentsForSelection() -> [Document] {
        let folderIds = Set(documentManager.folders.map { $0.id })
        let selectedFolderIds = scopedDocumentIds.intersection(folderIds)
        let selectedDocIds = scopedDocumentIds.subtracting(folderIds)

        var docs = documentManager.documents.filter { selectedDocIds.contains($0.id) }

        if !selectedFolderIds.isEmpty {
            var allFolderIds = Set<UUID>()
            for folderId in selectedFolderIds {
                allFolderIds.insert(folderId)
                allFolderIds.formUnion(documentManager.descendantFolderIds(of: folderId))
            }
            let folderDocs = documentManager.documents.filter { doc in
                guard let folderId = doc.folderId else { return false }
                return allFolderIds.contains(folderId)
            }
            docs.append(contentsOf: folderDocs)
        }

        var seen = Set<UUID>()
        let uniqueDocs = docs.filter { seen.insert($0.id).inserted }
        return uniqueDocs
            .filter { documentManager.isConversationEligible($0) }
            .sorted { $0.dateCreated > $1.dateCreated }
    }

    func wrapChatPrompt(_ prompt: String) -> String {
        let nPredictMarker: String
        if isScopeActive && scopedDocuments.count == 1 {
            nPredictMarker = "<<<N_PREDICT:350>>>"
        } else if isScopeActive {
            nPredictMarker = "<<<N_PREDICT:250>>>"
        } else {
            nPredictMarker = "<<<N_PREDICT:220>>>"
        }
        return "<<<CHAT_DETAIL>>>" + nPredictMarker + prompt
    }

    func callLLM(edgeAI: EdgeAI, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let finalPrompt = useNoHistoryForChat ? "<<<NO_HISTORY>>>" + prompt : prompt
            edgeAI.generate(finalPrompt, resolver: { result in
                continuation.resume(returning: result as? String ?? "")
            }, rejecter: { _, message, _ in
                continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
            })
        }
    }
}
