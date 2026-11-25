import CoreGraphics
import Foundation

/// Pairs headwords with meanings on a page without printed numbers: a meaning
/// belongs to the nearest headword to its left on the same line, else to the
/// nearest left-aligned headword above it (stacked cards, wrapped meanings).
enum OCRUnnumberedLayout {
    struct Entry: Equatable {
        let term: String
        let meaning: String
    }

    /// Column starts further apart than this begin a new column.
    private static let columnGap: CGFloat = 0.16
    /// How far a stacked headword may sit above its meaning, in line heights.
    private static let maximumStackDistance: CGFloat = 3.5
    /// How far a stacked headword's left edge may drift from its meaning's.
    private static let maximumStackIndent: CGFloat = 0.08

    static func entries(from tokens: [OCRTextToken]) -> [Entry] {
        let content = layoutTokens(from: tokens)
        let meanings = content.filter { OCRTokenClassifier.isMeaningToken($0.text) }
        let terms = headwords(in: content)
        guard !terms.isEmpty, !meanings.isEmpty else { return [] }

        var meaningsByTerm: [Int: [LayoutToken]] = [:]
        for meaning in meanings {
            guard let termIndex = owningTermIndex(of: meaning, among: terms) else { continue }
            meaningsByTerm[termIndex, default: []].append(meaning)
        }

        let columnStarts = columnStarts(of: terms)
        return meaningsByTerm.keys
            .sorted { lhs, rhs in
                let left = terms[lhs].token
                let right = terms[rhs].token
                let leftColumn = columnIndex(of: left, starts: columnStarts)
                let rightColumn = columnIndex(of: right, starts: columnStarts)
                if leftColumn != rightColumn {
                    return leftColumn < rightColumn
                }
                return left.centerY > right.centerY
            }
            .compactMap { termIndex in
                guard let assigned = meaningsByTerm[termIndex] else { return nil }
                // Tiled recognition can report one meaning twice with shifted boxes.
                var seen: Set<String> = []
                var parts: [String] = []
                for token in LayoutToken.readingSequence(assigned) where seen.insert(token.text).inserted {
                    parts.append(token.text)
                }
                let meaning = parts.joined(separator: " ")
                return Entry(term: terms[termIndex].term.lowercased(), meaning: meaning)
            }
    }

    /// Whether the tokens hold any Latin headword or Korean meaning, so a
    /// failed page can say which half is missing.
    static func contentKinds(in tokens: [OCRTextToken]) -> (hasHeadwords: Bool, hasMeanings: Bool) {
        let content = layoutTokens(from: tokens)
        return (
            !headwords(in: content).isEmpty,
            content.contains { OCRTokenClassifier.isMeaningToken($0.text) }
        )
    }

    private static func layoutTokens(from tokens: [OCRTextToken]) -> [LayoutToken] {
        tokens
            .compactMap(LayoutToken.init)
            .flatMap(splitInlineEntry)
    }

    /// Vision reads `word [ipa] - 뜻` printed on one line as one token. Split it
    /// at the word holding the first Hangul character (so a leading `(…)` stays
    /// with the meaning), sharing the box in proportion to the text.
    private static func splitInlineEntry(_ token: LayoutToken) -> [LayoutToken] {
        let text = token.text
        guard let firstHangul = text.firstIndex(where: { character in
            OCRTokenClassifier.containsHangul(String(character))
        }) else {
            return [token]
        }
        let meaningStart = text[..<firstHangul].lastIndex(of: " ").map(text.index(after:)) ?? text.startIndex
        let head = text[..<meaningStart].trimmingCharacters(in: CharacterSet(charactersIn: " -:=·"))
        guard !head.isEmpty, OCRTokenClassifier.englishTerm(from: head) != nil else {
            return [token]
        }
        let split = CGFloat(text.distance(from: text.startIndex, to: meaningStart)) / CGFloat(text.count)
        let box = token.boundingBox
        let headBox = CGRect(x: box.minX, y: box.minY, width: box.width * split, height: box.height)
        let meaningBox = CGRect(x: headBox.maxX, y: box.minY, width: box.width - headBox.width, height: box.height)
        return [
            LayoutToken(text: head, boundingBox: headBox),
            LayoutToken(text: String(text[meaningStart...]), boundingBox: meaningBox)
        ]
    }

    /// English tokens that start a headword, minus a pronunciation printed
    /// right after its headword as a separate, unbracketed token.
    private static func headwords(in tokens: [LayoutToken]) -> [(token: LayoutToken, term: String)] {
        let candidates = tokens.compactMap { token -> (token: LayoutToken, term: String)? in
            guard !OCRTokenClassifier.containsHangul(token.text),
                  OCRTokenClassifier.normalizedNumberText(token.text) == nil,
                  let term = OCRTokenClassifier.englishTerm(from: token.text) else {
                return nil
            }
            return (token, term)
        }
        return candidates.filter { candidate in
            !candidates.contains { previous in
                // Compare starts, not edges: Vision pads boxes, so a pronunciation
                // can begin inside its headword's box.
                previous.token !== candidate.token &&
                    previous.token.isOnSameLine(as: candidate.token) &&
                    previous.token.minX < candidate.token.minX &&
                    OCRTokenClassifier.isUnbracketedPronunciation(candidate.term, of: previous.term)
            }
        }
    }

    private static func owningTermIndex(
        of meaning: LayoutToken,
        among terms: [(token: LayoutToken, term: String)]
    ) -> Int? {
        let sameLine = terms.indices.filter {
            let term = terms[$0].token
            return term.isOnSameLine(as: meaning) && term.maxX <= meaning.minX + 0.01
        }
        if let nearestLeft = sameLine.max(by: { terms[$0].token.maxX < terms[$1].token.maxX }) {
            return nearestLeft
        }
        let lineHeight = max(meaning.height, 0.005)
        let above = terms.indices.filter {
            let term = terms[$0].token
            return term.centerY > meaning.centerY &&
                term.centerY - meaning.centerY <= lineHeight * maximumStackDistance &&
                abs(term.minX - meaning.minX) <= maximumStackIndent
        }
        // Nearest above, and among a headword and the pronunciation beside it
        // (same height), the one aligned with the meaning's left edge.
        return above.min { stackDistance(terms[$0].token, meaning) < stackDistance(terms[$1].token, meaning) }
    }

    private static func stackDistance(_ term: LayoutToken, _ meaning: LayoutToken) -> CGFloat {
        (term.centerY - meaning.centerY) + abs(term.minX - meaning.minX)
    }

    private static func columnStarts(of terms: [(token: LayoutToken, term: String)]) -> [CGFloat] {
        var starts: [CGFloat] = []
        for minX in terms.map(\.token.minX).sorted() {
            if let last = starts.last, minX - last <= columnGap {
                continue
            }
            starts.append(minX)
        }
        return starts
    }

    private static func columnIndex(of token: LayoutToken, starts: [CGFloat]) -> Int {
        starts.lastIndex { $0 <= token.minX + 0.001 } ?? 0
    }
}

private final class LayoutToken {
    let text: String
    let boundingBox: CGRect

    /// Drops empty text and the page margins, where status bars and page
    /// numbers sit, matching the numbered layout's content area.
    convenience init?(_ token: OCRTextToken) {
        let text = OCRTokenClassifier.clean(token.text)
        let box = token.boundingBox
        guard !text.isEmpty,
              box.midY > 0.03, box.midY < 0.95,
              box.midX > 0.02, box.midX < 0.98 else {
            return nil
        }
        self.init(text: text, boundingBox: box)
    }

    init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }

    var minX: CGFloat { boundingBox.minX }
    var maxX: CGFloat { boundingBox.maxX }
    var centerY: CGFloat { boundingBox.midY }
    var height: CGFloat { boundingBox.height }

    func isOnSameLine(as other: LayoutToken) -> Bool {
        abs(centerY - other.centerY) <= max(height, other.height) * 0.6
    }

    /// Top-down lines, each left to right. Lines are built from the topmost
    /// token of each band because "same line" is not transitive and cannot be
    /// a sort comparator.
    static func readingSequence(_ tokens: [LayoutToken]) -> [LayoutToken] {
        var lines: [[LayoutToken]] = []
        for token in tokens.sorted(by: { $0.centerY > $1.centerY }) {
            if let anchor = lines.last?.first, anchor.isOnSameLine(as: token) {
                lines[lines.count - 1].append(token)
            } else {
                lines.append([token])
            }
        }
        return lines.flatMap { line in line.sorted { $0.minX < $1.minX } }
    }
}
