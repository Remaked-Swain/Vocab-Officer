import Foundation

/// Classifies OCR token text as printed number, English headword, Korean
/// meaning or pronunciation. Shared by the numbered and unnumbered layouts.
enum OCRTokenClassifier {
    static func clean(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[•·]\s*"#, with: "·", options: .regularExpression)
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    /// A 4–8 digit printed number, repairing `O`/`o` read for `0`.
    static func normalizedNumberText(_ value: String) -> String? {
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

    static func containsHangul(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// A Hangul meaning. A bracketed token with Latin letters is a
    /// pronunciation whose IPA glyphs the mixed model read as Hangul
    /// (`[dʌl]` → `[d시]`); a meaning's own brackets (`[명망]`) hold no Latin.
    static func isMeaningToken(_ value: String) -> Bool {
        let isMisreadPronunciation = value.first == "[" &&
            value.contains { $0.isASCII && $0.isLetter }
        return containsHangul(value) &&
            !isMisreadPronunciation &&
            !isEnglishTerm(value) &&
            normalizedNumberText(value) == nil
    }

    static func isEnglishTerm(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z][A-Za-z' -]*$"#, options: .regularExpression) != nil else { return false }
        return !value.localizedCaseInsensitiveContains("day")
    }

    /// The headword in a token, with any pronunciation after it removed;
    /// nil when the token does not start with an English word.
    static func englishTerm(from value: String) -> String? {
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

        // A word with IPA marks (ə, æ, ː, accents) or digits ends the headword.
        let words = trimmed.split(separator: " ").map(String.init)
        let validPrefix = words.prefix { isEnglishTerm($0) }
        guard !validPrefix.isEmpty, validPrefix.count < words.count else { return nil }
        return validPrefix.joined(separator: " ")
    }

    /// Whether `candidate`, a separate token printed right after the headword
    /// token without brackets, reads as its pronunciation. An identical
    /// spelling always does; otherwise the consonant skeletons must match with
    /// at least two consonants. Only used across token boxes: inside one token
    /// it would cut repeated-word phrases (`hip hop` → `hip`).
    static func isUnbracketedPronunciation(_ candidate: String, of headword: String) -> Bool {
        guard !candidate.contains(" ") else { return false }
        if candidate.lowercased() == headword.lowercased() {
            return true
        }
        let candidateSkeleton = consonantSkeleton(candidate)
        return candidateSkeleton.count >= 2 && candidateSkeleton == consonantSkeleton(headword)
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
            // The consonant-skeleton rule is not applied inside one token:
            // repeated-word phrases (`hip hop`, `bye bye`) match it too.
            guard (headwordLength >= 6 && similarity >= 0.48) || hasBracketOCRArtifacts else {
                continue
            }
            if bestMatch == nil || similarity > (bestMatch?.similarity ?? 0) {
                bestMatch = (headword, similarity)
            }
        }
        return bestMatch?.headword
    }

    /// Consonants in reading order with spelling variants folded the way an
    /// ASCII-read transcription writes them (`c`/`ck`/`q` → `k`, `ph` → `f`,
    /// `z` → `s`, `x` → `ks`), doubled letters collapsed and vowels dropped:
    /// `dread`/`dred`, `hide`/`haid`, `dodo`/`doudou` and `candid`/`kandid`
    /// match, while `credit card` (krdt/krd) and `in line` (n/ln) do not.
    static func consonantSkeleton(_ value: String) -> String {
        let folded = value.lowercased()
            .filter { $0.isASCII && $0.isLetter }
            .replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "x", with: "ks")
        var skeleton = ""
        var previous: Character?
        for character in folded {
            defer { previous = character }
            guard character != previous else { continue }
            switch character {
            case "a", "e", "i", "o", "u", "y":
                continue
            case "c", "q":
                skeleton.append("k")
            case "z":
                skeleton.append("s")
            default:
                skeleton.append(character)
            }
        }
        return skeleton
    }

    private static func hasLikelyBracketOCRArtifacts(
        _ pronunciation: String,
        comparedWith headword: String
    ) -> Bool {
        let normalized = pronunciation.lowercased().filter(\.isLetter)
        let headwordLength = headword.filter(\.isLetter).count
        // `[` misread as `i`/`l` brackets the transcription at both ends; a lone
        // capital `I` after a lowercase headword marks it even when Vision drops
        // the closing bracket. A lowercase `i…` word without a closing artifact
        // stays part of the headword (e.g. `make inroads`).
        let hasClosingArtifact = normalized.last == "i" || normalized.last == "l"
        let hasCapitalOpeningArtifact = pronunciation.first == "I" &&
            headword.first?.isLowercase == true
        guard normalized.count >= 4,
              headwordLength >= 4,
              normalized.first == "i",
              hasClosingArtifact || hasCapitalOpeningArtifact else {
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
}
