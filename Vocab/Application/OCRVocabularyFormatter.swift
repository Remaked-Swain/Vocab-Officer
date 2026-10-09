import CoreGraphics
import Foundation

struct OCRTextToken {
    let text: String
    let boundingBox: CGRect
}

struct OCRVocabularyFormattingResult {
    let text: String
    let suspectedMissingNumbers: [String]

    func unresolvedMissingNumbers(in editedText: String) -> [String] {
        let presentNumbers = Set(IntakeNumberSequenceAnalyzer.numberPrefixes(in: editedText))
        return suspectedMissingNumbers.filter { !presentNumbers.contains($0) }
    }
}

enum OCRVocabularyFormatter {
    static func format(_ tokens: [OCRTextToken]) throws -> String {
        let entries = extractEntries(from: tokens).entries
        guard !entries.isEmpty else { throw OCRVocabularyFormatError.noVocabularyRows }
        return format(entries)
    }

    static func formatPages(_ pages: [[OCRTextToken]]) throws -> String {
        try formatPagesWithDiagnostics(pages).text
    }

    static func formatPagesWithDiagnostics(_ pages: [[OCRTextToken]]) throws -> OCRVocabularyFormattingResult {
        let pageExtractions = pages.map(extractEntries)
        let entries = pageExtractions.flatMap(\.entries)
        guard !entries.isEmpty else { throw OCRVocabularyFormatError.noVocabularyRows }
        let text = format(entries)
        let rejectedNumbers = pageExtractions.flatMap {
            $0.rejectedNumberTexts + $0.boundaryMissingNumberTexts
        }
        let sequenceGaps = IntakeNumberSequenceAnalyzer.missingNumbers(in: text, limit: 100)
        let suspectedMissingNumbers = Array(
            orderedUnique(rejectedNumbers + sequenceGaps).prefix(8)
        )
        return OCRVocabularyFormattingResult(
            text: text,
            suspectedMissingNumbers: suspectedMissingNumbers
        )
    }

    private static func format(_ entries: [VocabularyEntry]) -> String {
        entries
            .map { "\($0.numberText)-\($0.term)-\($0.meaning)" }
            .joined(separator: "\n")
    }

    private static func extractEntries(from tokens: [OCRTextToken]) -> PageExtraction {
        let normalized = tokens.map { NormalizedToken(text: clean($0.text), boundingBox: $0.boundingBox) }
            .filter { !$0.text.isEmpty && isContentToken($0) }
        let numbers = normalized.compactMap { token -> (token: NormalizedToken, number: Int, text: String)? in
            guard let numberText = normalizedNumberText(token.text), let number = Int(numberText) else {
                return nil
            }
            return (token, number, numberText)
        }
        let columnCenters = inferredColumnCenters(from: numbers.map(\.token))
        let columnSpacings = inferredColumnSpacings(
            from: numbers.map(\.token),
            columnCenters: columnCenters
        )
        var entriesByNumber: [Int: VocabularyEntry] = [:]

        for number in numbers {
            guard let entry = entry(
                for: number,
                tokens: normalized,
                numbers: numbers,
                columnCenters: columnCenters,
                columnSpacings: columnSpacings
            ) else {
                continue
            }
            if let existing = entriesByNumber[number.number], existing.score <= entry.score {
                continue
            }
            entriesByNumber[number.number] = entry
        }

        let entries = entriesByNumber.values.sorted(by: readingOrder)
        let acceptedNumbers = Set(entries.map(\.number))
        let rejectedNumberTexts = orderedUnique(
            numbers
                .filter { !acceptedNumbers.contains($0.number) }
                .map(\.text)
        )
        let boundaryMissingNumberTexts = inferredBoundaryMissingNumberTexts(
            normalizedTokens: normalized,
            numbers: numbers,
            columnCenters: columnCenters
        )
        return PageExtraction(
            entries: entries,
            rejectedNumberTexts: rejectedNumberTexts,
            boundaryMissingNumberTexts: boundaryMissingNumberTexts
        )
    }

    private static func entry(
        for number: (token: NormalizedToken, number: Int, text: String),
        tokens: [NormalizedToken],
        numbers: [(token: NormalizedToken, number: Int, text: String)],
        columnCenters: [CGFloat],
        columnSpacings: [CGFloat?]
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
        var lowerBound = lowerNumber.map {
            $0.centerY + max(0.004, $0.height * 0.25)
        } ?? max(CGFloat(0.02), number.token.centerY - 0.075)
        if let spacing = columnSpacings[columnIndex],
           let lowerNumber,
           number.token.centerY - lowerNumber.centerY > spacing * 1.45 {
            lowerBound = max(lowerBound, number.token.centerY - spacing * 0.9)
        }
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

        let meaningTokens = nearestMeaningLine(
            in: rowTokens.filter {
                isMeaningToken($0.text) &&
                $0 !== termToken &&
                !belongsToHigherRow($0, number: number.token, higherNumber: higherNumber)
            },
            to: termToken
        )
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

    private static func inferredColumnSpacings(
        from numberTokens: [NormalizedToken],
        columnCenters: [CGFloat]
    ) -> [CGFloat?] {
        columnCenters.indices.map { columnIndex in
            let positions = numberTokens
                .filter { nearestColumnIndex(to: $0.centerX, centers: columnCenters) == columnIndex }
                .map(\.centerY)
                .sorted(by: >)
            let uniquePositions = positions.reduce(into: [CGFloat]()) { result, value in
                guard result.last.map({ abs($0 - value) > 0.006 }) ?? true else { return }
                result.append(value)
            }
            let gaps = zip(uniquePositions, uniquePositions.dropFirst())
                .map { $0 - $1 }
                .filter { $0 > 0.015 }
                .sorted()
            guard !gaps.isEmpty else { return nil }
            return gaps[(gaps.count - 1) / 2]
        }
    }

    private static func inferredBoundaryMissingNumberTexts(
        normalizedTokens: [NormalizedToken],
        numbers: [(token: NormalizedToken, number: Int, text: String)],
        columnCenters: [CGFloat]
    ) -> [String] {
        let hasDayHeader = normalizedTokens.contains {
            $0.text.range(of: #"^DAY\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        guard hasDayHeader, columnCenters.count == 2 else { return [] }

        let leftValues = Set(numbers.compactMap { item in
            nearestColumnIndex(to: item.token.centerX, centers: columnCenters) == 0
                ? item.number
                : nil
        })
        let rightValues = Set(numbers.compactMap { item in
            nearestColumnIndex(to: item.token.centerX, centers: columnCenters) == 1
                ? item.number
                : nil
        })
        let observedValues = leftValues.union(rightValues)
        guard leftValues.count >= 6,
              rightValues.count >= 6,
              observedValues.count >= 16,
              observedValues.count < 20 else {
            return []
        }

        var candidateStarts: Set<Int> = []
        if let leftMinimum = leftValues.min() {
            candidateStarts.insert(leftMinimum)
        }
        if let rightMinimum = rightValues.min(), rightMinimum > 10 {
            candidateStarts.insert(rightMinimum - 10)
        }
        guard let start = candidateStarts.max(by: {
            pageLayoutMatchScore(start: $0, leftValues: leftValues, rightValues: rightValues) <
            pageLayoutMatchScore(start: $1, leftValues: leftValues, rightValues: rightValues)
        }) else {
            return []
        }

        let expectedValues = Set(start..<(start + 20))
        guard observedValues.isSubset(of: expectedValues) else { return [] }
        let missingValues = expectedValues.subtracting(observedValues).sorted()
        guard missingValues.count == 20 - observedValues.count, missingValues.count <= 4 else {
            return []
        }
        let width = numbers.map { $0.text.count }.max() ?? 4
        return missingValues.map { String(format: "%0\(width)d", $0) }
    }

    private static func pageLayoutMatchScore(
        start: Int,
        leftValues: Set<Int>,
        rightValues: Set<Int>
    ) -> Int {
        let expectedLeft = Set(start..<(start + 10))
        let expectedRight = Set((start + 10)..<(start + 20))
        return leftValues.intersection(expectedLeft).count +
            rightValues.intersection(expectedRight).count
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
        abs(token.centerY - number.centerY) + abs(token.minX - number.minX) * 0.3
    }

    private static func nearestMeaningLine(
        in tokens: [NormalizedToken],
        to term: NormalizedToken
    ) -> [NormalizedToken] {
        let sorted = tokens.sorted {
            if $0.centerY != $1.centerY {
                return $0.centerY > $1.centerY
            }
            return $0.minX < $1.minX
        }
        guard let first = sorted.first else { return [] }

        var lines: [[NormalizedToken]] = [[first]]
        for token in sorted.dropFirst() {
            guard let reference = lines.last?.first else { continue }
            let tolerance = max(CGFloat(0.008), max(reference.height, token.height) * 0.65)
            if abs(reference.centerY - token.centerY) <= tolerance {
                lines[lines.count - 1].append(token)
            } else {
                lines.append([token])
            }
        }

        guard let nearestIndex = lines.indices.min(by: {
            meaningLineScore(lines[$0], term: term) < meaningLineScore(lines[$1], term: term)
        }) else {
            return []
        }
        return lines[nearestIndex...].flatMap { line in
            line.sorted { $0.minX < $1.minX }
        }
    }

    private static func belongsToHigherRow(
        _ token: NormalizedToken,
        number: NormalizedToken,
        higherNumber: NormalizedToken?
    ) -> Bool {
        guard higherNumber != nil else { return false }
        return token.centerY > number.centerY + max(0.012, number.height * 0.6)
    }

    private static func meaningLineScore(_ tokens: [NormalizedToken], term: NormalizedToken) -> CGFloat {
        guard let first = tokens.first else { return .greatestFiniteMagnitude }
        let verticalDistance = abs(first.centerY - term.centerY)
        let aboveTermPenalty: CGFloat = first.centerY > term.centerY + 0.012 ? 0.025 : 0
        return verticalDistance + aboveTermPenalty
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
            .replacingOccurrences(of: #"\s*[•·]\s*"#, with: "·", options: .regularExpression)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    private static func normalizedNumberText(_ value: String) -> String? {
        let corrected = value
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "o", with: "0")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard corrected.range(of: #"^[0-9]{4,8}[.]?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let digits = corrected.filter(\.isNumber)
        guard digits.count >= 4, digits.count <= 8 else { return nil }
        return String(digits)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
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
            if let headword = headwordBeforeUnbracketedPronunciation(in: words) {
                return headword
            }
            return trimmed
        }

        let words = trimmed.split(separator: " ").map(String.init)
        let validPrefix = words.prefix { isEnglishTerm($0) }
        guard !validPrefix.isEmpty, validPrefix.count < words.count else { return nil }
        return validPrefix.joined(separator: " ")
    }

    private static func headwordBeforeUnbracketedPronunciation(in words: [String]) -> String? {
        guard words.count >= 2, words.count <= 6 else { return nil }
        var bestMatch: (headword: String, similarity: Double)?
        for splitIndex in 1..<words.count {
            let headword = words[..<splitIndex].joined(separator: " ")
            let pronunciation = words[splitIndex...].joined()
            let similarity = normalizedEditSimilarity(headword, pronunciation)
            let headwordLength = headword.filter(\.isLetter).count
            let hasBracketOCRArtifacts = hasLikelyBracketOCRArtifacts(
                pronunciation,
                comparedWith: headword
            )
            guard (headwordLength >= 6 && similarity >= 0.48) || hasBracketOCRArtifacts else {
                continue
            }
            if bestMatch == nil || similarity > (bestMatch?.similarity ?? 0) {
                bestMatch = (headword, similarity)
            }
        }
        return bestMatch?.headword
    }

    private static func hasLikelyBracketOCRArtifacts(
        _ pronunciation: String,
        comparedWith headword: String
    ) -> Bool {
        let normalized = pronunciation.lowercased().filter(\.isLetter)
        let headwordLength = headword.filter(\.isLetter).count
        guard normalized.count >= 4,
              headwordLength >= 4,
              normalized.first == "i",
              normalized.last == "i" || normalized.last == "l" else {
            return false
        }
        let lengthRatio = Double(normalized.count) / Double(headwordLength)
        return lengthRatio >= 0.6 && lengthRatio <= 1.7
    }

    private static func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = lhs.lowercased().filter(\.isLetter)
        let right = rhs.lowercased().filter(\.isLetter)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let maximumLength = max(left.count, right.count)
        return 1 - Double(editDistance(left, right)) / Double(maximumLength)
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous.last ?? max(left.count, right.count)
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.range(of: #"[가-힣]"#, options: .regularExpression) != nil
    }

    private static func isMeaningToken(_ value: String) -> Bool {
        containsHangul(value) && !isEnglishTerm(value) && normalizedNumberText(value) == nil
    }
}

enum IntakeNumberSequenceAnalyzer {
    static func numberPrefixes(in text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "-") else { return nil }
            let prefix = trimmed[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
            return String(prefix)
        }
    }

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

private struct PageExtraction {
    let entries: [VocabularyEntry]
    let rejectedNumberTexts: [String]
    let boundaryMissingNumberTexts: [String]
}
