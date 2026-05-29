import CoreGraphics
import Foundation

struct OCRTextToken {
    let text: String
    let boundingBox: CGRect
}

enum OCRVocabularyFormatter {
    static func format(_ tokens: [OCRTextToken]) throws -> String {
        let entries = extractEntries(from: tokens)
        guard !entries.isEmpty else { throw OCRVocabularyFormatError.noVocabularyRows }
        return format(entries)
    }

    static func formatPages(_ pages: [[OCRTextToken]]) throws -> String {
        let entries = pages.flatMap { extractEntries(from: $0) }
        guard !entries.isEmpty else { throw OCRVocabularyFormatError.noVocabularyRows }
        return format(entries)
    }

    private static func format(_ entries: [VocabularyEntry]) -> String {
        entries
            .sorted { $0.number < $1.number }
            .map { "\($0.numberText)-\($0.term)-\($0.meaning)" }
            .joined(separator: "\n")
    }

    private static func extractEntries(from tokens: [OCRTextToken]) -> [VocabularyEntry] {
        let normalized = tokens.map { NormalizedToken(text: clean($0.text), boundingBox: $0.boundingBox) }
            .filter { !$0.text.isEmpty && isContentToken($0) }
        let numbers = normalized.filter { isNumber($0.text) }
        var entries: [VocabularyEntry] = []
        var seenNumbers = Set<Int>()

        for number in numbers {
            guard let numberValue = Int(number.text), seenNumbers.insert(numberValue).inserted else { continue }
            let column = columnBounds(for: number)
            let rowTokens = normalized.filter {
                $0 !== number &&
                $0.centerX >= column.minX &&
                $0.centerX <= column.maxX &&
                abs($0.centerY - number.centerY) <= 0.036
            }

            guard let termToken = rowTokens
                .filter({ isEnglishTerm($0.text) && $0.minX > number.maxX })
                .min(by: { termScore($0, number: number) < termScore($1, number: number) }) else {
                continue
            }

            let meaningTokens = rowTokens
                .filter { containsHangul($0.text) && $0.minX >= termToken.minX - 0.02 }
                .sorted { $0.minX < $1.minX }
            guard !meaningTokens.isEmpty else { continue }
            let meaning = meaningTokens.map(\.text).joined(separator: " ")
            entries.append(VocabularyEntry(number: numberValue, numberText: number.text, term: termToken.text.lowercased(), meaning: meaning))
        }

        return entries
    }

    private static func columnBounds(for token: NormalizedToken) -> (minX: CGFloat, maxX: CGFloat) {
        token.centerX < 0.45 ? (0.08, 0.52) : (0.48, 0.91)
    }

    private static func termScore(_ token: NormalizedToken, number: NormalizedToken) -> CGFloat {
        abs(token.centerY - number.centerY) + max(0, token.minX - number.maxX) * 0.12
    }

    private static func isContentToken(_ token: NormalizedToken) -> Bool {
        token.centerY > 0.08 && token.centerY < 0.78 && token.centerX > 0.07 && token.centerX < 0.92
    }

    private static func clean(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static func isNumber(_ value: String) -> Bool {
        value.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    private static func isEnglishTerm(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z][A-Za-z' -]*$"#, options: .regularExpression) != nil else { return false }
        return !value.localizedCaseInsensitiveContains("day")
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.range(of: #"[가-힣]"#, options: .regularExpression) != nil
    }
}

enum OCRVocabularyFormatError: LocalizedError {
    case noVocabularyRows

    var errorDescription: String? {
        switch self {
        case .noVocabularyRows:
            "이미지에서 단어장 행을 찾지 못했습니다. 원본 캡쳐가 선명한지 확인하세요."
        }
    }
}

private final class NormalizedToken {
    let text: String
    let boundingBox: CGRect

    init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }

    var minX: CGFloat { boundingBox.minX }
    var maxX: CGFloat { boundingBox.maxX }
    var centerX: CGFloat { boundingBox.midX }
    var centerY: CGFloat { boundingBox.midY }
}

private struct VocabularyEntry {
    let number: Int
    let numberText: String
    let term: String
    let meaning: String
}
