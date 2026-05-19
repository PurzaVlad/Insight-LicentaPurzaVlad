import Foundation

enum SensitiveDataFlag: String, Codable, CaseIterable {
    case iban
    case cnp
    case financialAmount
    case email
    case phoneNumber

    var label: String {
        switch self {
        case .iban:            return "IBAN"
        case .cnp:             return "Personal ID (CNP)"
        case .financialAmount: return "Financial Data"
        case .email:           return "Email Addresses"
        case .phoneNumber:     return "Phone Numbers"
        }
    }

    var icon: String {
        switch self {
        case .iban:            return "creditcard.fill"
        case .cnp:             return "person.text.rectangle.fill"
        case .financialAmount: return "banknote.fill"
        case .email:           return "envelope.fill"
        case .phoneNumber:     return "phone.fill"
        }
    }
}

struct SensitiveDataDetector {

    private static let compiledPatterns: [(SensitiveDataFlag, NSRegularExpression)] = {
        let raw: [(SensitiveDataFlag, String)] = [

            // IBAN: 2-letter country code + 2 check digits + 8-30 alphanumeric (spaces/dashes between groups OK)
            (.iban,
             #"(?i)\b[A-Z]{2}\d{2}[\s\-]?(?:[A-Z0-9]{4}[\s\-]?){2,7}[A-Z0-9]{1,4}\b"#),

            // CNP: exactly 13-digit Romanian personal ID, first digit 1-9, no surrounding digits
            (.cnp,
             #"(?<!\d)[1-9]\d{12}(?!\d)"#),

            // Financial amounts: number + currency keyword or keyword + number
            // Matches: 5000 RON, 1.500,00 lei, EUR 200, $99.99, 500€, etc.
            (.financialAmount,
             #"(?i)\b\d[\d.,]*\s*(?:lei|ron|eur|usd|gbp|chf|€|\$|£)\b|\b(?:lei|ron|eur|usd|gbp|chf|€|\$|£)\s*\d[\d.,]*"#),

            // Email addresses
            (.email,
             #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),

            // Phone numbers:
            // – Romanian compact:  0721123456 / 0212345678
            // – Romanian spaced:   0721 123 456 / 021 312 3456 / 0721.123.456
            // – International:     +40 721 123 456 / (+40) 721 123 456 / +1 212 555 1234
            (.phoneNumber,
             #"(?<!\d)(?:0[2-9]\d{8}|0[2-9]\d{1,2}[\s.\-]\d{2,4}[\s.\-]\d{3,4}|\(?\+\d{1,3}\)?[\s.\-]?\d{1,4}[\s.\-]\d{3,4}[\s.\-]\d{2,4})(?!\d)"#),
        ]
        return raw.compactMap { flag, pattern in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (flag, re)
        }
    }()

    static func detect(in text: String) -> Set<SensitiveDataFlag> {
        var flags = Set<SensitiveDataFlag>()
        let range = NSRange(text.startIndex..., in: text)
        for (flag, regex) in compiledPatterns {
            if regex.firstMatch(in: text, range: range) != nil {
                flags.insert(flag)
            }
        }
        return flags
    }
}
