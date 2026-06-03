import Foundation
import SwiftData

struct WordDraft: Identifiable {
    let id = UUID()
    var term = ""
    var meanings = ""
}

enum LearningHistoryRetentionPolicy {
    static let recentAttemptLimitPerWord = 40
    static let keepAllAttemptsDays = 90
    static let keepFailedAttemptsDays = 365
    static let keepSessionDays = 180
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
            let pattern = #"^\s*(?:\d+\s*-\s*)?([A-Za-z][A-Za-z0-9' -]*?)\s*-\s*((?:[가-힣0-9~(]|약\s).*)\s*$"#
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
    case set = "세트 선택"
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

extension MeaningRecord {
    var isIndividuallyTrackable: Bool {
        !text.contains { ",/\n".contains($0) }
    }

    var isTrackableCoreMeaning: Bool {
        isCore && isIndividuallyTrackable
    }
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
        let day = SeoulCalendar.day(for: date)
        let existingSet = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate { $0.seoulDay == day })).first
        guard existingSet == nil else { throw LearningError.dailySetAlreadyExists }
        let allWords = try context.fetch(FetchDescriptor<WordRecord>())
        var wordsByNormalizedTerm: [String: WordRecord] = [:]
        for word in allWords where word.deletedAt == nil {
            wordsByNormalizedTerm[word.normalizedTerm] = word
        }
        let prepared = validDrafts.map { draft in
            (
                draft: draft,
                normalizedTerm: TextNormalizer.normalizeEnglish(draft.term),
                meanings: draft.meanings.components(separatedBy: CharacterSet(charactersIn: ",/\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
        guard prepared.allSatisfy({ !$0.meanings.isEmpty }) else { throw LearningError.meaningRequired }

        let set = DailySetRecord(seoulDay: day, createdAt: date)
        for (index, preparedDraft) in prepared.enumerated() {
            let word: WordRecord
            let isNewHeadword: Bool
            if let existingWord = wordsByNormalizedTerm[preparedDraft.normalizedTerm] {
                word = existingWord
                isNewHeadword = false
                if word.reviewState == nil {
                    word.reviewState = ReviewStateRecord()
                }
            } else {
                let newWord = WordRecord(term: preparedDraft.draft.term, createdAt: date)
                newWord.reviewState = ReviewStateRecord()
                context.insert(newWord)
                wordsByNormalizedTerm[preparedDraft.normalizedTerm] = newWord
                word = newWord
                isNewHeadword = true
            }

            var existingMeanings = Set(word.meanings.map(\.normalizedText))
            for value in preparedDraft.meanings {
                let normalizedMeaning = TextNormalizer.normalizeKorean(value)
                guard !existingMeanings.contains(normalizedMeaning) else { continue }
                let meaning = MeaningRecord(text: value)
                meaning.word = word
                word.meanings.append(meaning)
                existingMeanings.insert(normalizedMeaning)
            }
            let item = DailySetItemRecord(orderIndex: index, entryKind: isNewHeadword ? "newHeadword" : "reusedHeadword", wordID: word.id)
            item.set = set
            set.items.append(item)
            context.insert(item)
        }
        set.completedAt = date
        context.insert(set)
        try context.save()
    }

    func generateSession(mode: SessionMode, direction: PracticeDirection, setID: UUID? = nil, date: Date = .now) throws -> (TestSessionRecord, [SessionQuestion]) {
        let day = SeoulCalendar.day(for: date)
        let words = try context.fetch(FetchDescriptor<WordRecord>())
            .filter { $0.deletedAt == nil && $0.statusRaw == "active" }
        let sets = try context.fetch(FetchDescriptor<DailySetRecord>())
        let referenceSet = sets.first(where: { $0.seoulDay == day }) ?? sets.sorted { $0.createdAt > $1.createdAt }.first
        let referenceIDs: Set<UUID> = Set(referenceSet?.items.map(\.wordID) ?? [])
        compactSessionHistory(now: date)
        let sessions = try context.fetch(FetchDescriptor<TestSessionRecord>())
        let exposure = presentationStats(from: sessions)
        let alreadyPresentedTodayIDs: Set<UUID> = Set(sessions.filter { $0.seoulDay == day }.flatMap(\.wordIDs))
        let allPresentedIDs: Set<UUID> = Set(sessions.flatMap(\.wordIDs))
        let reference = uniqueWords(
            fairOrder(words.filter { referenceIDs.contains($0.id) && !alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
                + fairOrder(words.filter { referenceIDs.contains($0.id) && alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
        )
        let historicalSetIDs = Set(sets.filter { $0.id != referenceSet?.id }.flatMap(\.items).map(\.wordID))
        let unverifiedBacklog = fairOrder(
            words.filter { historicalSetIDs.contains($0.id) && !allPresentedIDs.contains($0.id) },
            exposure: exposure
        )
        let review = words.filter { record in
            guard let state = record.reviewState else { return false }
            return record.statusRaw == "active" && state.activePriority > 0
        }
        let orderedReview = reviewOrder(review, exposure: exposure)
        var selected: [WordRecord] = []
        switch mode {
        case .today:
            selected = Array(reference.prefix(20))
        case .set:
            guard let setID, let selectedSet = sets.first(where: { $0.id == setID }) else {
                throw LearningError.setRequired
            }
            let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
            let setWords = uniqueWords(selectedSet.items
                .sorted { $0.orderIndex < $1.orderIndex }
                .compactMap { wordsByID[$0.wordID] })
            let prioritized = fairOrder(setWords.filter { !allPresentedIDs.contains($0.id) }, exposure: exposure)
                + fairOrder(setWords.filter { allPresentedIDs.contains($0.id) }, exposure: exposure)
            selected = Array(prioritized.prefix(20))
        case .review:
            selected = Array(orderedReview.prefix(20))
            appendUnique(from: reference, to: &selected, limit: 20)
        case .mixed:
            selected = Array(reference.prefix(12))
            appendUnique(from: orderedReview, to: &selected, limit: min(18, 20))
            appendUnique(from: unverifiedBacklog, to: &selected, limit: 20)
            appendUnique(from: reference, to: &selected, limit: 20)
            appendUnique(from: orderedReview, to: &selected, limit: 20)
            appendUnique(from: unverifiedBacklog, to: &selected, limit: 20)
        }
        guard !selected.isEmpty else { throw LearningError.noSessionCandidates }
        let session = TestSessionRecord(directionRaw: direction.rawValue, modeRaw: mode.rawValue, seoulDay: day, wordIDs: selected.map(\.id), wasReduced: selected.count < 20)
        context.insert(session)
        try context.save()
        return (session, selected.enumerated().map { SessionQuestion(word: $0.element, direction: direction, index: $0.offset) })
    }

    func judge(answer: String, for question: SessionQuestion) -> JudgeResult {
        let normalized = question.direction == .enToKo ? TextNormalizer.normalizeKorean(answer) : TextNormalizer.normalizeEnglish(answer)
        switch question.direction {
        case .enToKo:
            for meaning in question.word.meanings where meaning.isIndividuallyTrackable {
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
        compactAttempts(for: question.word, now: date)
        try context.save()
    }

    func updateWord(_ word: WordRecord, term: String, meaningsText: String) throws {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { throw LearningError.termRequired }
        let normalizedTerm = TextNormalizer.normalizeEnglish(trimmedTerm)
        let duplicate = try context.fetch(FetchDescriptor<WordRecord>()).first {
            $0.id != word.id && $0.deletedAt == nil && $0.normalizedTerm == normalizedTerm
        }
        guard duplicate == nil else { throw LearningError.duplicateHeadword }

        let meaningValues = meaningsText.components(separatedBy: CharacterSet(charactersIn: ",/\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !meaningValues.isEmpty else { throw LearningError.meaningRequired }

        let originalTerm = word.normalizedTerm
        word.term = trimmedTerm
        word.normalizedTerm = normalizedTerm

        var existingByNormalized: [String: [MeaningRecord]] = [:]
        for meaning in word.meanings {
            existingByNormalized[meaning.normalizedText, default: []].append(meaning)
        }
        var revised: [MeaningRecord] = []
        var seenMeanings = Set<String>()
        for value in meaningValues {
            let normalized = TextNormalizer.normalizeKorean(value)
            guard seenMeanings.insert(normalized).inserted else { continue }
            if var matches = existingByNormalized[normalized], let meaning = matches.first {
                meaning.text = value
                meaning.normalizedText = normalized
                revised.append(meaning)
                matches.removeFirst()
                existingByNormalized[normalized] = matches
            } else {
                let meaning = MeaningRecord(text: value)
                meaning.word = word
                context.insert(meaning)
                revised.append(meaning)
            }
        }
        for removed in existingByNormalized.values.flatMap({ $0 }) {
            context.delete(removed)
        }
        word.meanings = revised

        if originalTerm != normalizedTerm {
            word.reviewState?.koToEnSuccessDays = []
        }
        if word.statusRaw == "mastered" {
            word.statusRaw = "active"
        }
        try context.save()
    }

    func compactLearningHistory(now: Date = .now) throws {
        for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
            compactAttempts(for: word, now: now)
        }
        compactSessionHistory(now: now)
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

    func deleteWords(_ words: [WordRecord]) throws {
        var deletedIDs = Set<UUID>()
        for word in words where deletedIDs.insert(word.id).inserted {
            try deleteWordRecord(word)
        }
        try context.save()
    }

    func discardDailySet(_ set: DailySetRecord) throws {
        let allItems = try context.fetch(FetchDescriptor<DailySetItemRecord>())
        let wordsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WordRecord>()).map { ($0.id, $0) })
        var deletedWordIDs = Set<UUID>()

        for item in set.items {
            let isLinkedOutsideSet = allItems.contains { other in
                other.wordID == item.wordID && other.set?.id != set.id
            }
            if !isLinkedOutsideSet, let word = wordsByID[item.wordID], deletedWordIDs.insert(word.id).inserted {
                try deleteWordRecord(word)
            } else {
                context.delete(item)
            }
        }

        context.delete(set)
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
                if let matchedMeaningID, let meaning = word.meanings.first(where: { $0.id == matchedMeaningID && $0.isTrackableCoreMeaning }), !meaning.successDays.contains(day) {
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
            } else if state.enToKoStreak >= 3 {
                state.activePriority = max(state.activePriority - 1, 0)
                state.enToKoStreak = 0
            }
        }
        if masterySatisfied(for: word, at: date) { word.statusRaw = "mastered" }
    }

    private func masterySatisfied(for word: WordRecord, at date: Date) -> Bool {
        let coreMeanings = word.meanings.filter(\.isCore)
        guard !coreMeanings.isEmpty, coreMeanings.allSatisfy(\.isTrackableCoreMeaning) else { return false }
        let coreSatisfied = coreMeanings.allSatisfy { Set($0.successDays).count >= 3 }
        let kToESatisfied = Set(word.reviewState?.koToEnSuccessDays ?? []).count >= 3
        let noRecentFailure = word.reviewState?.latestWrongAt.map { $0 < SeoulCalendar.daysAgo(14, from: date) } ?? true
        return coreSatisfied && kToESatisfied && noRecentFailure
    }

    private struct PresentationStats {
        var count = 0
        var lastPresentedAt: Date?
    }

    private func presentationStats(from sessions: [TestSessionRecord]) -> [UUID: PresentationStats] {
        var stats: [UUID: PresentationStats] = [:]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            for id in session.wordIDs {
                stats[id, default: PresentationStats()].count += 1
                stats[id, default: PresentationStats()].lastPresentedAt = session.startedAt
            }
        }
        return stats
    }

    private func fairOrder(_ candidates: [WordRecord], exposure: [UUID: PresentationStats]) -> [WordRecord] {
        let randomRank = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, Int.random(in: Int.min...Int.max)) })
        return candidates.sorted { lhs, rhs in
            let l = exposure[lhs.id] ?? PresentationStats()
            let r = exposure[rhs.id] ?? PresentationStats()
            if l.count != r.count { return l.count < r.count }
            if l.lastPresentedAt != r.lastPresentedAt {
                return (l.lastPresentedAt ?? .distantPast) < (r.lastPresentedAt ?? .distantPast)
            }
            return (randomRank[lhs.id] ?? 0) < (randomRank[rhs.id] ?? 0)
        }
    }

    private func reviewOrder(_ candidates: [WordRecord], exposure: [UUID: PresentationStats]) -> [WordRecord] {
        let randomRank = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, Int.random(in: Int.min...Int.max)) })
        return candidates.sorted { lhs, rhs in
            let l = lhs.reviewState
            let r = rhs.reviewState
            if (l?.activePriority ?? 0) != (r?.activePriority ?? 0) {
                return (l?.activePriority ?? 0) > (r?.activePriority ?? 0)
            }
            if (l?.failureCheck ?? 0) != (r?.failureCheck ?? 0) {
                return (l?.failureCheck ?? 0) > (r?.failureCheck ?? 0)
            }
            let le = exposure[lhs.id] ?? PresentationStats()
            let re = exposure[rhs.id] ?? PresentationStats()
            if le.count != re.count { return le.count < re.count }
            if le.lastPresentedAt != re.lastPresentedAt {
                return (le.lastPresentedAt ?? .distantPast) < (re.lastPresentedAt ?? .distantPast)
            }
            if (l?.latestWrongAt ?? .distantPast) != (r?.latestWrongAt ?? .distantPast) {
                return (l?.latestWrongAt ?? .distantPast) > (r?.latestWrongAt ?? .distantPast)
            }
            return (randomRank[lhs.id] ?? 0) < (randomRank[rhs.id] ?? 0)
        }
    }

    private func appendUnique(from candidates: [WordRecord], to selected: inout [WordRecord], limit: Int) {
        for word in candidates where selected.count < limit && !selected.contains(where: { $0.id == word.id }) {
            selected.append(word)
        }
    }

    private func compactSessionHistory(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(LearningHistoryRetentionPolicy.keepSessionDays) * 86_400)
        do {
            for session in try context.fetch(FetchDescriptor<TestSessionRecord>()) where session.startedAt < cutoff {
                context.delete(session)
            }
        } catch {
            assertionFailure("Failed to compact session history: \(error)")
        }
    }

    private func compactAttempts(for word: WordRecord, now: Date) {
        let sorted = word.attempts.sorted { $0.answeredAt > $1.answeredAt }
        let recentIDs = Set(sorted.prefix(LearningHistoryRetentionPolicy.recentAttemptLimitPerWord).map(\.id))
        let keepAllCutoff = now.addingTimeInterval(-Double(LearningHistoryRetentionPolicy.keepAllAttemptsDays) * 86_400)
        let keepFailedCutoff = now.addingTimeInterval(-Double(LearningHistoryRetentionPolicy.keepFailedAttemptsDays) * 86_400)
        for attempt in sorted {
            let isRecent = recentIDs.contains(attempt.id)
            let isWithinRecentWindow = attempt.answeredAt >= keepAllCutoff
            let isFailed = attempt.finalJudgementRaw != FinalResult.correct.rawValue
            let isFailedWithinWindow = isFailed && attempt.answeredAt >= keepFailedCutoff
            if !isRecent && !isWithinRecentWindow && !isFailedWithinWindow {
                context.delete(attempt)
            }
        }
        word.attempts.removeAll { attempt in
            let isRecent = recentIDs.contains(attempt.id)
            let isWithinRecentWindow = attempt.answeredAt >= keepAllCutoff
            let isFailed = attempt.finalJudgementRaw != FinalResult.correct.rawValue
            let isFailedWithinWindow = isFailed && attempt.answeredAt >= keepFailedCutoff
            return !isRecent && !isWithinRecentWindow && !isFailedWithinWindow
        }
    }

    private func deleteWordRecord(_ word: WordRecord) throws {
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
    }

    private func uniqueWords(_ words: [WordRecord]) -> [WordRecord] {
        var seen = Set<UUID>()
        return words.filter { word in
            seen.insert(word.id).inserted
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
    case meaningRequired
    case termRequired
    case duplicateHeadword
    case onlyMasteredCanBeDeleted
    case setRequired
    case noSessionCandidates

    var errorDescription: String? {
        switch self {
        case .dailySetRequiresExactly100: "오늘의 완료 세트는 신규 단어 100개가 필요합니다."
        case .dailySetAlreadyExists: "오늘의 완료 세트가 이미 저장되어 있습니다."
        case .meaningRequired: "각 표제어에 뜻을 하나 이상 입력해야 합니다."
        case .termRequired: "영단어 표제어를 입력해야 합니다."
        case .duplicateHeadword: "이미 존재하는 표제어입니다. 기존 단어를 직접 수정하세요."
        case .onlyMasteredCanBeDeleted: "Mastered 단어만 삭제할 수 있습니다."
        case .setRequired: "테스트할 입력 세트를 선택하세요."
        case .noSessionCandidates: "선택한 범위에 출제 가능한 단어가 없습니다."
        }
    }
}
