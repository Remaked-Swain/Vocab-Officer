import Foundation

struct WordDraft: Identifiable {
    let id = UUID()
    var term = ""
    var meanings = ""
}

struct VocabularyRegistrationResult {
    let words: [WordRecord]
    let inputRowCount: Int
    let createdHeadwordCount: Int
    let matchedExistingHeadwordCount: Int
    let duplicateInputRowCount: Int
    let meaningsAddedToExistingHeadwords: Int
}

enum MeaningTextSplitter {
    static func split(_ text: String) -> [String] {
        var values: [String] = []
        var buffer = ""
        var parenthesisDepth = 0

        for character in text {
            switch character {
            case "(", "（":
                parenthesisDepth += 1
                buffer.append(character)
            case ")", "）":
                parenthesisDepth = max(parenthesisDepth - 1, 0)
                buffer.append(character)
            case ",", "，", "/", "\n":
                if parenthesisDepth == 0 {
                    append(buffer, to: &values)
                    buffer.removeAll(keepingCapacity: true)
                } else {
                    buffer.append(character)
                }
            default:
                buffer.append(character)
            }
        }
        append(buffer, to: &values)
        return values
    }

    private static func append(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        values.append(trimmed)
    }
}

enum DailyIntakePasteParser {
    private static let markdownFencePrefix = "```"
    private static let nonHangulMeaningStartCharacters = CharacterSet(charactersIn: "~(（")

    static func parse(_ text: String) throws -> [WordDraft] {
        var drafts: [WordDraft] = []
        drafts.reserveCapacity(100)
        var sawContent = false
        var sourceLineNumber = 0
        var parseError: PasteIntakeError?

        text.enumerateLines { line, stop in
            sourceLineNumber += 1
            let lineNumber = sourceLineNumber
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(markdownFencePrefix) else { return }
            sawContent = true

            do {
                drafts.append(try parseLine(trimmed, line: lineNumber))
            } catch let error as PasteIntakeError {
                parseError = error
                stop = true
            } catch {
                parseError = .invalidLine(lineNumber)
                stop = true
            }
        }

        if let parseError { throw parseError }
        guard sawContent else { throw PasteIntakeError.empty }
        return drafts
    }

    private static func parseLine(_ line: String, line lineNumber: Int) throws -> WordDraft {
        if let tabIndex = line.firstIndex(of: "\t") {
            let term = line[..<tabIndex]
            let meanings = line[line.index(after: tabIndex)...]
            return try draft(term: String(term), meanings: String(meanings), line: lineNumber)
        }

        let body = stripLeadingNumber(from: line)
        guard let separator = meaningSeparator(in: body) else {
            throw PasteIntakeError.invalidLine(lineNumber)
        }
        return try draft(
            term: String(body[..<separator]),
            meanings: String(body[body.index(after: separator)...]),
            line: lineNumber
        )
    }

    private static func stripLeadingNumber(from line: String) -> Substring {
        var index = line.startIndex
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        let digitStart = index
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > digitStart else { return line[...] }
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "-" else { return line[...] }
        index = line.index(after: index)
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        return line[index...]
    }

    private static func meaningSeparator(in line: Substring) -> String.Index? {
        var index = line.startIndex
        var numericMeaningFallback: String.Index?
        while index < line.endIndex {
            guard line[index] == "-" else {
                index = line.index(after: index)
                continue
            }
            let term = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidTerm(term), startsLikePrimaryMeaning(meaning) {
                return index
            }
            if isValidTerm(term), startsLikeNumericMeaning(meaning) {
                numericMeaningFallback = index
            }
            index = line.index(after: index)
        }
        return numericMeaningFallback
    }

    private static func isValidTerm(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == " " || $0 == "-"
        }
    }

    private static func startsLikePrimaryMeaning(_ value: String) -> Bool {
        guard let scalar = value.unicodeScalars.first else { return false }
        return value.hasPrefix("약 ")
            || (scalar.value >= 0xAC00 && scalar.value <= 0xD7A3)
            || nonHangulMeaningStartCharacters.contains(scalar)
    }

    private static func startsLikeNumericMeaning(_ value: String) -> Bool {
        value.unicodeScalars.first.map(CharacterSet.decimalDigits.contains) == true
    }

    private static func draft(term: String, meanings: String, line: Int) throws -> WordDraft {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMeanings = meanings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty, !trimmedMeanings.isEmpty else {
            throw PasteIntakeError.invalidLine(line)
        }
        return WordDraft(term: trimmedTerm, meanings: trimmedMeanings)
    }
}

enum PasteIntakeError: LocalizedError {
    case empty
    case invalidLine(Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            "붙여넣은 텍스트가 없습니다."
        case .invalidLine(let line):
            "\(line)번째 줄 형식을 확인하세요. '번호-영단어-뜻' 또는 탭 구분 형식을 사용합니다."
        }
    }
}
