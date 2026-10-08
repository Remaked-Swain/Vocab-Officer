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
            .map { "\($0.numberText)-\($0.term)-\($0.meaning)" }
            .joined(separator: "\n")
    }

    private static func extractEntries(from tokens: [OCRTextToken]) -> [VocabularyEntry] {
        let normalized = tokens.map { NormalizedToken(text: clean($0.text), boundingBox: $0.boundingBox) }
            .filter { !$0.text.isEmpty && isContentToken($0) }
        let numbers = normalized.compactMap { token -> (token: NormalizedToken, number: Int, text: String)? in
            guard let numberText = normalizedNumberText(token.text), let number = Int(numberText) else {
                return nil
            }
            return (token, number, numberText)
        }
        let columnCenters = inferredColumnCenters(from: numbers.map(\.token))
        var entriesByNumber: [Int: VocabularyEntry] = [:]

        for number in numbers {
            guard let entry = entry(
                for: number,
                tokens: normalized,
                numbers: numbers,
                columnCenters: columnCenters
            ) else {
                continue
            }
            if let existing = entriesByNumber[number.number], existing.score <= entry.score {
                continue
            }
            entriesByNumber[number.number] = entry
        }

        return entriesByNumber.values.sorted(by: readingOrder)
    }

    private static func entry(
        for number: (token: NormalizedToken, number: Int, text: String),
        tokens: [NormalizedToken],
        numbers: [(token: NormalizedToken, number: Int, text: String)],
        columnCenters: [CGFloat]
    ) -> VocabularyEntry? {
        let columnIndex = nearestColumnIndex(to: number.token.centerX, centers: columnCenters)
        let column = columnBounds(at: columnIndex, centers: columnCenters)
        let higherNumber = numbers
            .map(\.token)
            .filter {
                $0 !== number.token &&
                nearestColumnIndex(to: $0.centerX, centers: columnCenters) == columnIndex &&
                $0.centerY > number.token.centerY
            }
            .min { $0.centerY < $1.centerY }
        let lowerNumber = numbers
            .map(\.token)
            .filter {
                $0 !== number.token &&
                nearestColumnIndex(to: $0.centerX, centers: columnCenters) == columnIndex &&
                $0.centerY < number.token.centerY
            }
            .max { $0.centerY < $1.centerY }
        let upperBound = higherNumber.map {
            ($0.centerY + number.token.centerY) / 2
        } ?? min(CGFloat(0.98), number.token.centerY + 0.075)
        let lowerBound = lowerNumber.map {
            $0.centerY + max(0.004, $0.height * 0.25)
        } ?? max(CGFloat(0.02), number.token.centerY - 0.075)
        let broadRowTokens = tokens.filter {
            $0 !== number.token &&
            $0.centerX >= column.minX &&
            $0.centerX <= column.maxX &&
            $0.centerY <= upperBound &&
            $0.centerY > lowerBound
        }
        let preferredUpperBound = min(
            upperBound,
            number.token.centerY + 0.022
        )
        let preferredRowTokens = broadRowTokens.filter { $0.centerY <= preferredUpperBound }
        let rowTokens = containsVocabularyContent(preferredRowTokens)
            ? preferredRowTokens
            : broadRowTokens

        let termMatches = rowTokens.compactMap { token -> (NormalizedToken, String)? in
            guard let term = englishTerm(from: token.text) else { return nil }
            return (token, term)
        }
        guard let termMatch = termMatches.min(by: {
            termScore($0.0, number: number.token) < termScore($1.0, number: number.token)
        }) else {
            return nil
        }
        let termToken = termMatch.0

        let meaningTokens = rowTokens
            .filter { isMeaningToken($0.text) && $0 !== termToken }
            .sorted { $0.minX < $1.minX }
        guard !meaningTokens.isEmpty else { return nil }

        let meaning = meaningTokens.map(\.text).joined(separator: " ")
        let score = entryScore(number: number.token, term: termToken, meanings: meaningTokens, numberText: number.text)
        return VocabularyEntry(
            number: number.number,
            numberText: number.text,
            term: termMatch.1.lowercased(),
            meaning: meaning,
            score: score,
            columnIndex: columnIndex,
            centerY: number.token.centerY
        )
    }

    private static func inferredColumnCenters(from numberTokens: [NormalizedToken]) -> [CGFloat] {
        let sorted = numberTokens.map(\.centerX).sorted()
        guard let first = sorted.first else { return [0.5] }
        var clusters: [[CGFloat]] = [[first]]
        for value in sorted.dropFirst() {
            guard let previous = clusters.last?.last else { continue }
            if value - previous > 0.16 {
                clusters.append([value])
            } else {
                clusters[clusters.count - 1].append(value)
            }
        }
        return clusters.map { $0.reduce(0, +) / CGFloat($0.count) }
    }

    private static func nearestColumnIndex(to value: CGFloat, centers: [CGFloat]) -> Int {
        centers.indices.min { abs(centers[$0] - value) < abs(centers[$1] - value) } ?? 0
    }

    private static func columnBounds(at index: Int, centers: [CGFloat]) -> (minX: CGFloat, maxX: CGFloat) {
        let minX = index == centers.startIndex ? 0.02 : (centers[index - 1] + centers[index]) / 2
        let maxX = index == centers.index(before: centers.endIndex) ? 0.98 : (centers[index] + centers[index + 1]) / 2
        return (minX, maxX)
    }

    private static func readingOrder(_ lhs: VocabularyEntry, _ rhs: VocabularyEntry) -> Bool {
        if lhs.columnIndex != rhs.columnIndex {
            return lhs.columnIndex < rhs.columnIndex
        }
        if lhs.centerY != rhs.centerY {
            return lhs.centerY > rhs.centerY
        }
        return lhs.number < rhs.number
    }

    private static func termScore(_ token: NormalizedToken, number: NormalizedToken) -> CGFloat {
        abs(token.centerY - number.centerY) + abs(token.minX - number.maxX) * 0.12
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
        token.centerY > 0.03 && token.centerY < 0.95 && token.centerX > 0.02 && token.centerX < 0.98
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
        guard digits.count >= 4, digits.count <= 8 else { return nil }
        return String(digits)
    }

    private static func isEnglishTerm(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z][A-Za-z' -]*$"#, options: .regularExpression) != nil else { return false }
        return !value.localizedCaseInsensitiveContains("day")
    }

    private static func containsVocabularyContent(_ tokens: [NormalizedToken]) -> Bool {
        tokens.contains { englishTerm(from: $0.text) != nil } &&
        tokens.contains { isMeaningToken($0.text) }
    }

    private static func englishTerm(from value: String) -> String? {
        let pronunciationSeparators = ["[", "(", "|"]
        let prefix = pronunciationSeparators
            .compactMap { separator in value.range(of: separator)?.lowerBound }
            .min()
            .map { String(value[..<$0]) } ?? value
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEnglishTerm(trimmed) {
            let words = trimmed.split(separator: " ").map(String.init)
            if words.count == 2, isLikelyUnbracketedPronunciation(words[1]) {
                return words[0]
            }
            return trimmed
        }

        let words = trimmed.split(separator: " ").map(String.init)
        let validPrefix = words.prefix { isEnglishTerm($0) }
        guard !validPrefix.isEmpty, validPrefix.count < words.count else { return nil }
        return validPrefix.joined(separator: " ")
    }

    private static func isLikelyUnbracketedPronunciation(_ value: String) -> Bool {
        if value.first == "I" { return true }
        return value.lowercased().hasPrefix("ti") && value.lowercased().contains("mp")
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.range(of: #"[가-힣]"#, options: .regularExpression) != nil
    }

    private static func isMeaningToken(_ value: String) -> Bool {
        containsHangul(value) && !isEnglishTerm(value) && normalizedNumberText(value) == nil
    }
}

enum IntakeNumberSequenceAnalyzer {
    static func missingNumbers(in text: String, limit: Int = 8) -> [String] {
        guard limit > 0 else { return [] }
        let values = text.components(separatedBy: .newlines).compactMap(numberPrefix)
        guard values.count >= 2 else { return [] }

        var missing: [String] = []
        var previous = values[0]
        for current in values.dropFirst() {
            defer { previous = current }
            guard current.value > previous.value else { continue }
            guard current.value - previous.value > 1 else { continue }
            let width = max(previous.width, current.width)
            for value in (previous.value + 1)..<current.value {
                missing.append(String(format: "%0\(width)d", value))
                guard missing.count < limit else { return missing }
            }
        }
        return missing
    }

    private static func numberPrefix(from line: String) -> (value: Int, width: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "-") else { return nil }
        let prefix = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber), let value = Int(prefix) else {
            return nil
        }
        return (value, prefix.count)
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
    let columnIndex: Int
    let centerY: CGFloat
}
