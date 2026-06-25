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
        let rowIndex = Dictionary(grouping: normalized) { rowKey(for: $0) }
        let numbers = normalized.compactMap { token -> (token: NormalizedToken, number: Int, text: String)? in
            guard let numberText = normalizedNumberText(token.text), let number = Int(numberText) else {
                return nil
            }
            return (token, number, numberText)
        }
        var entriesByNumber: [Int: VocabularyEntry] = [:]

        for number in numbers {
            guard let entry = entry(for: number, rowIndex: rowIndex) else {
                continue
            }
            if let existing = entriesByNumber[number.number], existing.score <= entry.score {
                continue
            }
            entriesByNumber[number.number] = entry
        }

        return Array(entriesByNumber.values)
    }

    private static func entry(
        for number: (token: NormalizedToken, number: Int, text: String),
        rowIndex: [Int: [NormalizedToken]]
    ) -> VocabularyEntry? {
        let column = columnBounds(for: number.token)
        let tolerance = max(CGFloat(0.036), number.token.height * 2.4)
        let keyRadius = max(2, Int((tolerance * 120).rounded(.up)))
        let nearbyRows = ((rowKey(for: number.token) - keyRadius)...(rowKey(for: number.token) + keyRadius))
            .flatMap { rowIndex[$0] ?? [] }
        let rowTokens = nearbyRows.filter {
            $0 !== number.token &&
            $0.centerX >= column.minX &&
            $0.centerX <= column.maxX &&
            abs($0.centerY - number.token.centerY) <= tolerance
        }

        guard let termToken = rowTokens
            .filter({ isEnglishTerm($0.text) && $0.minX > number.token.maxX })
            .min(by: { termScore($0, number: number.token) < termScore($1, number: number.token) }) else {
            return nil
        }

        let meaningTokens = rowTokens
            .filter { isMeaningToken($0.text) && $0.minX > number.token.maxX && $0 !== termToken }
            .sorted { $0.minX < $1.minX }
        guard !meaningTokens.isEmpty else { return nil }

        let meaning = meaningTokens.map(\.text).joined(separator: " ")
        let score = entryScore(number: number.token, term: termToken, meanings: meaningTokens, numberText: number.text)
        return VocabularyEntry(
            number: number.number,
            numberText: number.text,
            term: termToken.text.lowercased(),
            meaning: meaning,
            score: score
        )
    }

    private static func rowKey(for token: NormalizedToken) -> Int {
        Int((token.centerY * 120).rounded())
    }

    private static func columnBounds(for token: NormalizedToken) -> (minX: CGFloat, maxX: CGFloat) {
        token.centerX < 0.45 ? (0.08, 0.52) : (0.48, 0.91)
    }

    private static func termScore(_ token: NormalizedToken, number: NormalizedToken) -> CGFloat {
        abs(token.centerY - number.centerY) + max(0, token.minX - number.maxX) * 0.12
    }

    private static func entryScore(
        number: NormalizedToken,
        term: NormalizedToken,
        meanings: [NormalizedToken],
        numberText: String
    ) -> CGFloat {
        let meaningDistance = meanings
            .map { abs($0.centerY - number.centerY) + abs($0.minX - term.minX) * 0.04 }
            .min() ?? 1
        let cleanNumberBonus: CGFloat = numberText.allSatisfy(\.isNumber) ? 0 : 0.01
        return termScore(term, number: number) + meaningDistance + cleanNumberBonus
    }

    private static func isContentToken(_ token: NormalizedToken) -> Bool {
        token.centerY > 0.08 && token.centerY < 0.78 && token.centerX > 0.07 && token.centerX < 0.92
    }

    private static func clean(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    private static func normalizedNumberText(_ value: String) -> String? {
        let corrected = value
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
        let digits = corrected.filter(\.isNumber)
        guard digits.count >= 4, digits.count <= 6 else { return nil }
        return String(digits)
    }

    private static func isEnglishTerm(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z][A-Za-z' -]*$"#, options: .regularExpression) != nil else { return false }
        return !value.localizedCaseInsensitiveContains("day")
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.range(of: #"[가-힣]"#, options: .regularExpression) != nil
    }

    private static func isMeaningToken(_ value: String) -> Bool {
        containsHangul(value) && !isEnglishTerm(value) && normalizedNumberText(value) == nil
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
    var height: CGFloat { boundingBox.height }
}

private struct VocabularyEntry {
    let number: Int
    let numberText: String
    let term: String
    let meaning: String
    let score: CGFloat
}
