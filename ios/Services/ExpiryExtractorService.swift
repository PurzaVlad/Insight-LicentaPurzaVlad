import Foundation

struct ExtractedExpiry {
    let date: Date
    let label: String
    let context: String
}

final class ExpiryExtractorService {
    static let shared = ExpiryExtractorService()
    private init() {}

    private static let expiryKeywords: [String] = [
        // Romanian
        "expir", "scadent", "scadenț", "valabil până la", "valabilitate până la",
        "termen de valabilitate", "reînnoire", "data expirării", "valabil pana la",
        // English
        "expires", "expiry", "expiration", "valid until", "valid through",
        "not valid after", "renewal date", "deadline", "expiry date", "expiration date"
    ]

    private static let monthsEN: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4),
        ("may", 5), ("june", 6), ("july", 7), ("august", 8),
        ("september", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4),
        ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12)
    ]

    private static let monthsRO: [(String, Int)] = [
        ("ianuarie", 1), ("februarie", 2), ("martie", 3), ("aprilie", 4),
        ("mai", 5), ("iunie", 6), ("iulie", 7), ("august", 8),
        ("septembrie", 9), ("octombrie", 10), ("noiembrie", 11), ("decembrie", 12),
        ("ian", 1), ("feb", 2), ("mar", 3), ("apr", 4),
        ("iun", 6), ("iul", 7), ("aug", 8), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12)
    ]

    private static let allMonths: [(String, Int)] = monthsEN + monthsRO

    // MARK: - Public

    func extract(from text: String) -> ExtractedExpiry? {
        let sentences = splitIntoSentences(text)
        let now = Date()
        let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now

        var best: (date: Date, label: String, context: String)?

        for sentence in sentences {
            let lower = sentence.lowercased()
            guard let keyword = Self.expiryKeywords.first(where: { lower.contains($0) }) else { continue }

            let candidates = extractDates(from: sentence)
            for candidate in candidates {
                // Discard clearly historical dates (more than 30 days ago)
                guard candidate > thirtyDaysAgo else { continue }
                // Pick earliest future/recent date across all matching sentences
                if best == nil || candidate < best!.date {
                    let label = labelFromKeyword(keyword)
                    best = (candidate, label, String(sentence.prefix(120)))
                }
            }
        }

        guard let result = best else { return nil }
        return ExtractedExpiry(date: result.date, label: result.label, context: result.context)
    }

    // MARK: - Sentence splitting

    private func splitIntoSentences(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: "\n"))
            .flatMap { $0.components(separatedBy: ". ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 15 }
    }

    // MARK: - Date extraction

    private func extractDates(from sentence: String) -> [Date] {
        var results: [Date] = []

        results += extractNumericDates(from: sentence)
        results += extractTextualDates(from: sentence)

        return results
    }

    private func extractNumericDates(from sentence: String) -> [Date] {
        var results: [Date] = []
        let cal = Calendar.current

        // Pattern 1: DD.MM.YYYY or DD/MM/YYYY or DD-MM-YYYY
        if let regex = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})[./\-](\d{1,2})[./\-](\d{4})\b"#
        ) {
            let ns = sentence as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: sentence, range: range) {
                guard match.numberOfRanges == 4,
                      let d = Int(ns.substring(with: match.range(at: 1))),
                      let m = Int(ns.substring(with: match.range(at: 2))),
                      let y = Int(ns.substring(with: match.range(at: 3))),
                      d >= 1, d <= 31, m >= 1, m <= 12, y >= 2020
                else { continue }
                var comps = DateComponents()
                comps.day = d; comps.month = m; comps.year = y
                if let date = cal.date(from: comps) { results.append(date) }
            }
        }

        // Pattern 2: YYYY-MM-DD (ISO 8601)
        if let regex = try? NSRegularExpression(
            pattern: #"\b(\d{4})[./\-](\d{1,2})[./\-](\d{1,2})\b"#
        ) {
            let ns = sentence as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: sentence, range: range) {
                guard match.numberOfRanges == 4,
                      let y = Int(ns.substring(with: match.range(at: 1))),
                      let m = Int(ns.substring(with: match.range(at: 2))),
                      let d = Int(ns.substring(with: match.range(at: 3))),
                      d >= 1, d <= 31, m >= 1, m <= 12, y >= 2020
                else { continue }
                var comps = DateComponents()
                comps.day = d; comps.month = m; comps.year = y
                if let date = cal.date(from: comps) { results.append(date) }
            }
        }

        return results
    }

    private func extractTextualDates(from sentence: String) -> [Date] {
        var results: [Date] = []
        let lower = sentence.lowercased()
        let cal = Calendar.current

        // Build month alternation string
        let monthPattern = Self.allMonths.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")

        // Pattern: DD MonthName YYYY (e.g. "31 decembrie 2026", "31 December 2026")
        if let regex = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})\s+(\#(monthPattern))\.?\s+(\d{4})\b"#,
            options: .caseInsensitive
        ) {
            let ns = lower as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: lower, range: range) {
                guard match.numberOfRanges == 4 else { continue }
                let dayStr = ns.substring(with: match.range(at: 1))
                let monthStr = ns.substring(with: match.range(at: 2))
                let yearStr = ns.substring(with: match.range(at: 3))
                guard let d = Int(dayStr),
                      let y = Int(yearStr),
                      let m = Self.allMonths.first(where: { $0.0 == monthStr })?.1,
                      d >= 1, d <= 31, y >= 2020
                else { continue }
                var comps = DateComponents()
                comps.day = d; comps.month = m; comps.year = y
                if let date = cal.date(from: comps) { results.append(date) }
            }
        }

        // Pattern: MonthName DD, YYYY (e.g. "December 31, 2026")
        if let regex = try? NSRegularExpression(
            pattern: #"\b(\#(monthPattern))\.?\s+(\d{1,2})[,\s]+(\d{4})\b"#,
            options: .caseInsensitive
        ) {
            let ns = lower as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: lower, range: range) {
                guard match.numberOfRanges == 4 else { continue }
                let monthStr = ns.substring(with: match.range(at: 1))
                let dayStr = ns.substring(with: match.range(at: 2))
                let yearStr = ns.substring(with: match.range(at: 3))
                guard let d = Int(dayStr),
                      let y = Int(yearStr),
                      let m = Self.allMonths.first(where: { $0.0 == monthStr })?.1,
                      d >= 1, d <= 31, y >= 2020
                else { continue }
                var comps = DateComponents()
                comps.day = d; comps.month = m; comps.year = y
                if let date = cal.date(from: comps) { results.append(date) }
            }
        }

        return results
    }

    // MARK: - Helpers

    private func labelFromKeyword(_ keyword: String) -> String {
        switch keyword {
        case let k where k.contains("valabil"):
            return "Valid until"
        case let k where k.contains("scaden"):
            return "Due date"
        case let k where k.contains("reînnoi"):
            return "Renewal"
        case let k where k.contains("termen"):
            return "Deadline"
        case let k where k.contains("expir"):
            return "Expiry date"
        case "deadline":
            return "Deadline"
        case "renewal date":
            return "Renewal"
        case "valid until", "valid through":
            return "Valid until"
        case "not valid after":
            return "Not valid after"
        default:
            return "Expiry date"
        }
    }
}
