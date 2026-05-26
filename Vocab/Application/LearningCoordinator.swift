import Foundation
import SwiftData

struct WordDraft: Identifiable {
    let id = UUID()
    var term = ""
    var meanings = ""
}

enum DailyIntakePasteParser {
    static func parse(_ text: String) throws -> [WordDraft] {
        let lines = text.components(separatedBy: .newlines)
            .enumerated()
            .filter {
                let value = $0.element.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && !value.hasPrefix("```")
            }
        guard !lines.isEmpty else { throw PasteIntakeError.empty }

        return try lines.map { offset, line in
            let lineNumber = offset + 1
            if line.contains("\t") {
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2 else { throw PasteIntakeError.invalidLine(lineNumber) }
                return try draft(term: String(fields[0]), meanings: String(fields[1]), line: lineNumber)
            }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let pattern = #"^\s*(?:\d+\s*-\s*)?([A-Za-z][A-Za-z0-9' -]*?)\s*-\s*((?:[가-힣~(]|약\s).*)\s*$"#
            let expression = try NSRegularExpression(pattern: pattern)
            guard let match = expression.firstMatch(in: line, range: range),
                  let termRange = Range(match.range(at: 1), in: line),
                  let meaningsRange = Range(match.range(at: 2), in: line) else {
                throw PasteIntakeError.invalidLine(lineNumber)
            }
            return try draft(term: String(line[termRange]), meanings: String(line[meaningsRange]), line: lineNumber)
        }
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

enum SessionMode: String, CaseIterable, Identifiable {
    case today = "오늘 신규"
    case review = "복습"
    case mixed = "혼합"
    var id: String { rawValue }
}

enum PracticeDirection: String, CaseIterable, Identifiable {
    case enToKo = "영어 -> 한국어"
    case koToEn = "한국어 -> 영어"
    var id: String { rawValue }
}

enum FinalResult: String {
    case correct
    case incorrect
    case unknown
}

struct SessionQuestion: Identifiable {
    let id = UUID()
    let word: WordRecord
    let direction: PracticeDirection
    let index: Int

    var prompt: String {
        switch direction {
        case .enToKo: word.term
        case .koToEn: word.meanings.first(where: \.isCore)?.text ?? word.meanings.first?.text ?? ""
        }
    }
}

struct JudgeResult {
    let automaticResult: FinalResult
    let matchedMeaningID: UUID?
    let isTypoSuggestion: Bool
}

@MainActor
final class LearningCoordinator {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func saveDailySet(_ drafts: [WordDraft], date: Date = .now) throws {
        let validDrafts = drafts.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validDrafts.count == 100 else {
            throw LearningError.dailySetRequiresExactly100
        }
        let normalized = validDrafts.map { TextNormalizer.normalizeEnglish($0.term) }
        guard Set(normalized).count == 100 else { throw LearningError.duplicateNewWord }
        let day = SeoulCalendar.day(for: date)
        let existingSet = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate { $0.seoulDay == day })).first
        guard existingSet == nil else { throw LearningError.dailySetAlreadyExists }
        let allWords = try context.fetch(FetchDescriptor<WordRecord>())
        let activeTerms = Set(allWords.filter { $0.deletedAt == nil }.map(\.normalizedTerm))
        guard normalized.allSatisfy({ !activeTerms.contains($0) }) else { throw LearningError.existingTermDoesNotCountAsNew }
        let prepared = validDrafts.map { draft in
            (
                draft: draft,
                meanings: draft.meanings.components(separatedBy: CharacterSet(charactersIn: ",/\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        guard prepared.allSatisfy({ !$0.meanings.isEmpty }) else { throw LearningError.meaningRequired }

        let set = DailySetRecord(seoulDay: day, createdAt: date)
        for (index, preparedDraft) in prepared.enumerated() {
            let word = WordRecord(term: preparedDraft.draft.term, createdAt: date)
            word.reviewState = ReviewStateRecord()
            for value in preparedDraft.meanings {
                let meaning = MeaningRecord(text: value)
                meaning.word = word
                word.meanings.append(meaning)
            }
            let item = DailySetItemRecord(orderIndex: index, entryKind: "newHeadword", wordID: word.id)
            item.set = set
            set.items.append(item)
            context.insert(word)
            context.insert(item)
        }
        set.completedAt = date
        context.insert(set)
        try context.save()
    }

    func generateSession(mode: SessionMode, direction: PracticeDirection, date: Date = .now) throws -> (TestSessionRecord, [SessionQuestion]) {
        let day = SeoulCalendar.day(for: date)
        let words = try context.fetch(FetchDescriptor<WordRecord>())
            .filter { $0.deletedAt == nil && $0.statusRaw == "active" }
        let todayIDs: Set<UUID> = Set((try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate { $0.seoulDay == day })).first?.items ?? []).map(\.wordID))
        let alreadyPresentedIDs: Set<UUID> = Set(try context.fetch(FetchDescriptor<TestSessionRecord>(predicate: #Predicate { $0.seoulDay == day })).flatMap(\.wordIDs))
        let today = words.filter { todayIDs.contains($0.id) && !alreadyPresentedIDs.contains($0.id) }
            + words.filter { todayIDs.contains($0.id) && alreadyPresentedIDs.contains($0.id) }
        let review = words.filter { record in
            guard let state = record.reviewState else { return false }
            return state.activePriority > 0
        }.sorted(by: Self.prioritySort)
        var selected: [WordRecord] = []
        switch mode {
        case .today:
            selected = Array(today.prefix(20))
        case .review:
            selected = Array(review.prefix(20))
        case .mixed:
            selected = Array(review.prefix(10))
            appendUnique(from: today, to: &selected, limit: 20)
            appendUnique(from: review, to: &selected, limit: 20)
        }
        let session = TestSessionRecord(directionRaw: direction.rawValue, modeRaw: mode.rawValue, seoulDay: day, wordIDs: selected.map(\.id), wasReduced: selected.count < 20)
        context.insert(session)
        try context.save()
        return (session, selected.enumerated().map { SessionQuestion(word: $0.element, direction: direction, index: $0.offset) })
    }

    func judge(answer: String, for question: SessionQuestion) -> JudgeResult {
        let normalized = question.direction == .enToKo ? TextNormalizer.normalizeKorean(answer) : TextNormalizer.normalizeEnglish(answer)
        switch question.direction {
        case .enToKo:
            for meaning in question.word.meanings {
                let answers = [meaning.normalizedText] + meaning.aliases.map(TextNormalizer.normalizeKorean)
                if answers.contains(normalized) {
                    return JudgeResult(automaticResult: .correct, matchedMeaningID: meaning.id, isTypoSuggestion: false)
                }
            }
            return JudgeResult(automaticResult: .incorrect, matchedMeaningID: nil, isTypoSuggestion: typoCandidate(answer, for: question))
        case .koToEn:
            let accepted = [question.word.term] + question.word.englishAliases
            if accepted.map(TextNormalizer.normalizeEnglish).contains(normalized) {
                return JudgeResult(automaticResult: .correct, matchedMeaningID: nil, isTypoSuggestion: false)
            }
            return JudgeResult(automaticResult: .incorrect, matchedMeaningID: nil, isTypoSuggestion: typoCandidate(answer, for: question))
        }
    }

    func commit(answer: String, result: FinalResult, automatic: FinalResult, matchedMeaningID: UUID?, question: SessionQuestion, session: TestSessionRecord, correction: String? = nil, date: Date = .now) throws {
        let attempt = AttemptRecord(directionRaw: question.direction.rawValue, modeRaw: session.modeRaw, sessionID: session.id, questionIndex: question.index, seoulDay: SeoulCalendar.day(for: date), prompt: question.prompt, submittedAnswer: answer, automaticJudgementRaw: automatic.rawValue, finalJudgementRaw: result.rawValue, matchedMeaningID: matchedMeaningID, answeredAt: date)
        attempt.correctionRaw = correction
        attempt.word = question.word
        question.word.attempts.append(attempt)
        apply(result: result, matchedMeaningID: matchedMeaningID, direction: question.direction, to: question.word, date: date)
        context.insert(attempt)
        try context.save()
    }

    func deleteMastered(_ word: WordRecord) throws {
        guard word.statusRaw == "mastered" else { throw LearningError.onlyMasteredCanBeDeleted }
        let day = SeoulCalendar.day(for: .now)
        let aggregate = AnonymousAggregateRecord(seoulDay: day, modeRaw: "deletion")
        aggregate.deletedMasteredCount = 1
        context.insert(aggregate)
        for set in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            for item in set.items where item.wordID == word.id {
                context.delete(item)
            }
            set.items.removeAll { $0.wordID == word.id }
        }
        for session in try context.fetch(FetchDescriptor<TestSessionRecord>()) {
            session.wordIDs.removeAll { $0 == word.id }
        }
        context.delete(word)
        try context.save()
    }

    private func apply(result: FinalResult, matchedMeaningID: UUID?, direction: PracticeDirection, to word: WordRecord, date: Date) {
        let state = word.reviewState ?? ReviewStateRecord()
        word.reviewState = state
        state.lastTestedAt = date
        let day = SeoulCalendar.day(for: date)
        switch result {
        case .incorrect, .unknown:
            state.failureCheck = min(state.failureCheck + 1, 3)
            state.activePriority = max(state.activePriority, state.failureCheck)
            state.latestWrongDirection = direction.rawValue
            state.latestWrongAt = date
            if direction == .enToKo { state.enToKoStreak = 0 } else { state.koToEnStreak = 0 }
        case .correct:
            if direction == .enToKo {
                state.enToKoStreak += 1
                if let matchedMeaningID, let meaning = word.meanings.first(where: { $0.id == matchedMeaningID && $0.isCore }), !meaning.successDays.contains(day) {
                    meaning.successDays.append(day)
                }
            } else {
                state.koToEnStreak += 1
                if !state.koToEnSuccessDays.contains(day) { state.koToEnSuccessDays.append(day) }
            }
            if state.enToKoStreak >= 2 && state.koToEnStreak >= 2 {
                state.activePriority = max(state.activePriority - 1, 0)
                state.enToKoStreak = 0
                state.koToEnStreak = 0
            }
        }
        if masterySatisfied(for: word, at: date) { word.statusRaw = "mastered" }
    }

    private func masterySatisfied(for word: WordRecord, at date: Date) -> Bool {
        let coreSatisfied = word.meanings.filter(\.isCore).allSatisfy { Set($0.successDays).count >= 3 }
        let kToESatisfied = Set(word.reviewState?.koToEnSuccessDays ?? []).count >= 3
        let noRecentFailure = word.reviewState?.latestWrongAt.map { $0 < SeoulCalendar.daysAgo(14, from: date) } ?? true
        return !word.meanings.filter(\.isCore).isEmpty && coreSatisfied && kToESatisfied && noRecentFailure
    }

    private static func prioritySort(_ lhs: WordRecord, _ rhs: WordRecord) -> Bool {
        let l = lhs.reviewState
        let r = rhs.reviewState
        if (l?.activePriority ?? 0) != (r?.activePriority ?? 0) { return (l?.activePriority ?? 0) > (r?.activePriority ?? 0) }
        return (l?.latestWrongAt ?? .distantPast) > (r?.latestWrongAt ?? .distantPast)
    }

    private func appendUnique(from candidates: [WordRecord], to selected: inout [WordRecord], limit: Int) {
        for word in candidates where selected.count < limit && !selected.contains(where: { $0.id == word.id }) {
            selected.append(word)
        }
    }

    private func typoCandidate(_ answer: String, for question: SessionQuestion) -> Bool {
        let target = question.direction == .enToKo ? question.word.meanings.first?.text ?? "" : question.word.term
        return abs(answer.count - target.count) <= 1 && answer != target
    }
}

enum LearningError: LocalizedError {
    case dailySetRequiresExactly100
    case dailySetAlreadyExists
    case duplicateNewWord
    case existingTermDoesNotCountAsNew
    case meaningRequired
    case onlyMasteredCanBeDeleted

    var errorDescription: String? {
        switch self {
        case .dailySetRequiresExactly100: "오늘의 완료 세트는 신규 단어 100개가 필요합니다."
        case .dailySetAlreadyExists: "오늘의 완료 세트가 이미 저장되어 있습니다."
        case .duplicateNewWord: "오늘 입력에 중복 표제어가 있습니다."
        case .existingTermDoesNotCountAsNew: "기존 단어의 수정은 오늘 신규 100개에 포함되지 않습니다."
        case .meaningRequired: "각 표제어에 뜻을 하나 이상 입력해야 합니다."
        case .onlyMasteredCanBeDeleted: "Mastered 단어만 삭제할 수 있습니다."
        }
    }
}
