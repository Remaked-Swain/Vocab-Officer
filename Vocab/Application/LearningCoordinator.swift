import Foundation
import Security
import SwiftData

extension Notification.Name {
    static let vocabLearningStoreDidChange = Notification.Name("vocabLearningStoreDidChange")
}

struct WordDraft: Identifiable {
    let id = UUID()
    var term = ""
    var meanings = ""
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

enum LearningHistoryRetentionPolicy {
    static let recentAttemptLimitPerWord = 40
    static let keepAllAttemptsDays = 90
    static let keepFailedAttemptsDays = 365
    static let keepSessionDays = 180
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

enum SessionMode: String, CaseIterable, Identifiable {
    case today = "오늘 신규"
    case set = "세트 선택"
    case loose = "낱개"
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

struct VocabAttemptLogicalKey: Hashable, Equatable {
    let sessionID: UUID
    let questionIndex: Int
}

struct VocabAttemptReplayConflict: Equatable {
    let key: VocabAttemptLogicalKey
    let attemptIDs: [UUID]
}

struct VocabAttemptReplayPlan {
    let canonicalAttempts: [AttemptRecord]
    let conflicts: [VocabAttemptReplayConflict]
}

struct SessionQuestion: Identifiable {
    let id = UUID()
    let word: WordRecord
    let direction: PracticeDirection
    let index: Int

    var prompt: String {
        switch direction {
        case .enToKo: word.term
        case .koToEn: word.activeMeanings.first(where: \.isCore)?.text ?? word.activeMeanings.first?.text ?? ""
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
        MeaningTextSplitter.split(text).count == 1
    }

    var isTrackableCoreMeaning: Bool {
        isCore && isIndividuallyTrackable
    }
}

extension WordRecord {
    var activeMeanings: [MeaningRecord] {
        allMeanings.filter { $0.deletedAt == nil }
    }

    var correctionCandidateMeanings: [MeaningRecord] {
        let trackable = activeMeanings.filter(\.isTrackableCoreMeaning)
        return trackable.isEmpty ? activeMeanings.filter(\.isCore) : trackable
    }

    var defaultCorrectionMeaningID: UUID? {
        correctionCandidateMeanings.first?.id
    }
}

@MainActor
final class LearningCoordinator {
    private let context: ModelContext
    private let syncMode: VocabSyncMode
    private var activeWordCache: [WordRecord]?
    private var dailySetCache: [DailySetRecord]?

    init(context: ModelContext, syncMode: VocabSyncMode = .current(allowsCloudKit: true)) {
        self.context = context
        self.syncMode = syncMode
    }

    private func saveAndNotifyChange() throws {
        try context.save()
        NotificationCenter.default.post(name: .vocabLearningStoreDidChange, object: nil)
    }

    func saveDailySet(_ drafts: [WordDraft], date: Date = .now) throws {
        let validDrafts = drafts.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard validDrafts.count == 100 else {
            throw LearningError.dailySetRequiresExactly100
        }
        let day = SeoulCalendar.day(for: date)
        let existingSet = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate {
            $0.seoulDay == day && $0.deletedAt == nil
        })).first
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
                meanings: MeaningTextSplitter.split(draft.meanings)
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

            var existingMeanings = Set(word.activeMeanings.map(\.normalizedText))
            for value in preparedDraft.meanings {
                let normalizedMeaning = TextNormalizer.normalizeKorean(value)
                guard !existingMeanings.contains(normalizedMeaning) else { continue }
                let meaning = MeaningRecord(text: value)
                meaning.word = word
                word.appendMeaning(meaning)
                existingMeanings.insert(normalizedMeaning)
            }
            let item = DailySetItemRecord(orderIndex: index, entryKind: isNewHeadword ? "newHeadword" : "reusedHeadword", wordID: word.id)
            item.set = set
            set.appendItem(item)
            context.insert(item)
        }
        set.completedAt = date
        context.insert(set)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
    }

    @discardableResult
    func addLooseWord(term: String, meaningsText: String, date: Date = .now) throws -> WordRecord {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { throw LearningError.termRequired }
        let normalizedTerm = TextNormalizer.normalizeEnglish(trimmedTerm)
        let meaningValues = MeaningTextSplitter.split(meaningsText)
        guard !meaningValues.isEmpty else { throw LearningError.meaningRequired }

        let existing = try context.fetch(FetchDescriptor<WordRecord>()).first {
            $0.deletedAt == nil && $0.normalizedTerm == normalizedTerm
        }
        let word: WordRecord
        if let existing {
            word = existing
            if word.reviewState == nil {
                word.reviewState = ReviewStateRecord()
            }
        } else {
            let newWord = WordRecord(term: trimmedTerm, createdAt: date)
            newWord.reviewState = ReviewStateRecord()
            context.insert(newWord)
            word = newWord
        }

        var existingMeanings = Set(word.activeMeanings.map(\.normalizedText))
        for value in meaningValues {
            let normalizedMeaning = TextNormalizer.normalizeKorean(value)
            guard existingMeanings.insert(normalizedMeaning).inserted else { continue }
            let meaning = MeaningRecord(text: value)
            meaning.word = word
            word.appendMeaning(meaning)
            context.insert(meaning)
        }
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
        return word
    }

    func generateSession(mode: SessionMode, direction: PracticeDirection, setID: UUID? = nil, date: Date = .now) throws -> (TestSessionRecord, [SessionQuestion]) {
        _ = try VocabCloudReconciler.reconcile(context: context, syncMode: syncMode, now: date)
        let day = SeoulCalendar.day(for: date)
        let words = try activeWords()
        let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        let sets = try dailySets()
        let setsByRecency = sets.filter { $0.seoulDay <= day }.sorted {
            if $0.seoulDay != $1.seoulDay { return $0.seoulDay > $1.seoulDay }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let todaySet = setsByRecency.first(where: { $0.seoulDay == day })
        let referenceSet = todaySet ?? setsByRecency.first
        let previousSet = setsByRecency.first(where: { $0.seoulDay < day })
        let presentation = try presentationContext(for: words, day: day, now: date)
        let exposure = presentation.exposure
        let alreadyPresentedTodayIDs = presentation.alreadyPresentedTodayIDs
        let allPresentedIDs = presentation.allPresentedIDs
        var selected: [WordRecord] = []
        func setWords(for items: [DailySetItemRecord]) -> [WordRecord] {
            uniqueWords(items
                .sorted { $0.orderIndex < $1.orderIndex }
                .compactMap { wordsByID[$0.wordID] })
        }
        func referenceCandidates() -> [WordRecord] {
            let referenceWords = setWords(for: referenceSet?.items ?? [])
            return uniqueWords(
                fairOrder(referenceWords.filter { !alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
                    + fairOrder(referenceWords.filter { alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
            )
        }
        func orderedReviewCandidates() -> [WordRecord] {
            let review = words.filter { record in
                guard let state = record.reviewState else { return false }
                return state.activePriority > 0
            }
            return reviewOrder(review, exposure: exposure)
        }
        switch mode {
        case .today:
            selected = Array(referenceCandidates().prefix(20))
        case .set:
            guard let setID, let selectedSet = sets.first(where: { $0.id == setID }) else {
                throw LearningError.setRequired
            }
            let selectedSetWords = setWords(for: selectedSet.allItems)
            let prioritized = fairOrder(selectedSetWords.filter { !allPresentedIDs.contains($0.id) }, exposure: exposure)
                + fairOrder(selectedSetWords.filter { allPresentedIDs.contains($0.id) }, exposure: exposure)
            selected = Array(prioritized.prefix(20))
        case .loose:
            let linkedWordIDs = Set(sets.flatMap(\.allItems).map(\.wordID))
            let loose = fairOrder(
                words.filter { !linkedWordIDs.contains($0.id) },
                exposure: exposure
            )
            selected = Array(loose.prefix(20))
        case .review:
            let orderedReview = orderedReviewCandidates()
            let previousSetCandidates = fairOrder(setWords(for: previousSet?.items ?? []), exposure: exposure)
            let reference = referenceCandidates()
            selected = Array(orderedReview.prefix(14))
            appendUnique(
                from: previousSetCandidates,
                to: &selected,
                limit: min(20, selected.count + 6)
            )
            appendUnique(from: orderedReview, to: &selected, limit: 20)
            appendUnique(from: reference, to: &selected, limit: 20)
        case .mixed:
            let reference = referenceCandidates()
            let orderedReview = orderedReviewCandidates()
            let historicalSetIDs = Set(setsByRecency.filter { $0.id != referenceSet?.id }.flatMap(\.allItems).map(\.wordID))
            let unverifiedBacklog = fairOrder(
                historicalSetIDs.compactMap { wordsByID[$0] }.filter { !allPresentedIDs.contains($0.id) },
                exposure: exposure
            )
            selected = Array(reference.prefix(12))
            appendUnique(from: orderedReview, to: &selected, limit: min(18, 20))
            appendUnique(from: unverifiedBacklog, to: &selected, limit: 20)
            appendUnique(from: reference, to: &selected, limit: 20)
            appendUnique(from: orderedReview, to: &selected, limit: 20)
            appendUnique(from: unverifiedBacklog, to: &selected, limit: 20)
        }
        guard !selected.isEmpty else { throw LearningError.noSessionCandidates }
        let session = TestSessionRecord(directionRaw: direction.rawValue, modeRaw: mode.rawValue, seoulDay: day, wordIDs: selected.map(\.id), wasReduced: selected.count < 20, startedAt: date)
        context.insert(session)
        recordPresentation(for: selected, at: date)
        try saveAndNotifyChange()
        return (session, selected.enumerated().map { SessionQuestion(word: $0.element, direction: direction, index: $0.offset) })
    }

    func judge(answer: String, for question: SessionQuestion) -> JudgeResult {
        let normalized = question.direction == .enToKo ? TextNormalizer.normalizeKorean(answer) : TextNormalizer.normalizeEnglish(answer)
        switch question.direction {
        case .enToKo:
            for meaning in question.word.activeMeanings where meaning.isIndividuallyTrackable {
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
        let existingAttempt = try context.fetch(FetchDescriptor<AttemptRecord>()).contains {
            $0.deletedAt == nil && $0.sessionID == session.id && $0.questionIndex == question.index
        }
        guard !existingAttempt else { return }
        let attempt = AttemptRecord(directionRaw: question.direction.rawValue, modeRaw: session.modeRaw, sessionID: session.id, questionIndex: question.index, seoulDay: SeoulCalendar.day(for: date), prompt: question.prompt, submittedAnswer: answer, automaticJudgementRaw: automatic.rawValue, finalJudgementRaw: result.rawValue, matchedMeaningID: matchedMeaningID, answeredAt: date)
        attempt.correctionRaw = correction
        attempt.word = question.word
        question.word.appendAttempt(attempt)
        context.insert(attempt)
        recomputeReviewState(for: question.word)
        compactAttempts(for: question.word, now: date)
        try saveAndNotifyChange()
    }

    func updateWord(_ word: WordRecord, term: String, meaningsText: String) throws {
        let trimmedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTerm.isEmpty else { throw LearningError.termRequired }
        let normalizedTerm = TextNormalizer.normalizeEnglish(trimmedTerm)
        let duplicate = try context.fetch(FetchDescriptor<WordRecord>()).first {
            $0.id != word.id && $0.deletedAt == nil && $0.normalizedTerm == normalizedTerm
        }
        guard duplicate == nil else { throw LearningError.duplicateHeadword }

        let meaningValues = MeaningTextSplitter.split(meaningsText)
        guard !meaningValues.isEmpty else { throw LearningError.meaningRequired }

        let originalTerm = word.normalizedTerm
        word.term = trimmedTerm
        word.normalizedTerm = normalizedTerm

        var existingByNormalized: [String: [MeaningRecord]] = [:]
        for meaning in word.activeMeanings {
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
        let now = Date.now
        for removed in existingByNormalized.values.flatMap({ $0 }) where removed.deletedAt == nil {
            tombstone(removed, at: now)
        }
        word.replaceMeanings(with: revised)
        word.updatedAt = now

        if originalTerm != normalizedTerm {
            word.reviewState?.koToEnSuccessDays = []
        }
        if word.statusRaw == "mastered" {
            word.statusRaw = "active"
        }
        try saveAndNotifyChange()
    }

    func compactLearningHistory(now: Date = .now) throws {
        for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
            compactAttempts(for: word, now: now)
        }
        compactSessionHistory(now: now)
        try saveAndNotifyChange()
    }

    func deleteMastered(_ word: WordRecord) throws {
        guard word.statusRaw == "mastered" else { throw LearningError.onlyMasteredCanBeDeleted }
        let day = SeoulCalendar.day(for: .now)
        let aggregate = AnonymousAggregateRecord(seoulDay: day, modeRaw: "deletion")
        aggregate.deletedMasteredCount = 1
        context.insert(aggregate)
        try deleteWordRecord(word)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
    }

    func deleteWords(_ words: [WordRecord]) throws {
        var deletedIDs = Set<UUID>()
        for word in words where deletedIDs.insert(word.id).inserted {
            try deleteWordRecord(word)
        }
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
    }

    func discardDailySet(_ set: DailySetRecord) throws {
        let allItems = try context.fetch(FetchDescriptor<DailySetItemRecord>()).filter { $0.deletedAt == nil }
        let wordsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WordRecord>()).filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        var deletedWordIDs = Set<UUID>()

        for item in set.allItems {
            let isLinkedOutsideSet = allItems.contains { other in
                other.wordID == item.wordID && other.set?.id != set.id
            }
            if !isLinkedOutsideSet, let word = wordsByID[item.wordID], deletedWordIDs.insert(word.id).inserted {
                try deleteWordRecord(word)
            } else {
                tombstone(item)
            }
        }

        tombstone(set)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
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
                if let matchedMeaningID, let meaning = word.activeMeanings.first(where: { $0.id == matchedMeaningID && $0.isTrackableCoreMeaning }), !meaning.successDays.contains(day) {
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
            } else if state.enToKoStreak >= 2 {
                state.activePriority = max(state.activePriority - 1, 0)
                state.enToKoStreak = 0
            }
        }
        if masterySatisfied(for: word, at: date) { word.statusRaw = "mastered" }
    }

    @discardableResult
    func recomputeReviewState(for word: WordRecord) -> [VocabAttemptReplayConflict] {
        recomputeReviewState(for: word, attempts: word.allAttempts)
    }

    @discardableResult
    func recomputeReviewState(
        for word: WordRecord,
        attempts sourceAttempts: [AttemptRecord]
    ) -> [VocabAttemptReplayConflict] {
        let replayPlan = Self.attemptReplayPlan(sourceAttempts)
        guard replayPlan.conflicts.isEmpty else { return replayPlan.conflicts }
        let state = word.reviewState ?? ReviewStateRecord()
        let presentationCount = state.presentationCount
        let lastPresentedAt = state.lastPresentedAt
        state.failureCheck = 0
        state.activePriority = 0
        state.enToKoStreak = 0
        state.koToEnStreak = 0
        state.koToEnSuccessDays = []
        state.latestWrongDirection = nil
        state.latestWrongAt = nil
        state.lastTestedAt = nil
        state.presentationCount = presentationCount
        state.lastPresentedAt = lastPresentedAt
        word.reviewState = state
        if word.deletedAt == nil {
            word.statusRaw = "active"
        }
        for meaning in word.activeMeanings {
            meaning.successDays = []
        }

        let attempts = replayPlan.canonicalAttempts
            .sorted { lhs, rhs in
                lhs.answeredAt == rhs.answeredAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.answeredAt < rhs.answeredAt
            }
        for attempt in attempts {
            guard let result = FinalResult(rawValue: attempt.finalJudgementRaw),
                  let direction = PracticeDirection(rawValue: attempt.directionRaw) else { continue }
            apply(
                result: result,
                matchedMeaningID: attempt.matchedMeaningID,
                direction: direction,
                to: word,
                date: attempt.answeredAt
            )
        }
        state.updatedAt = attempts.last?.answeredAt ?? word.updatedAt
        return []
    }

    static func attemptReplayPlan(_ sourceAttempts: [AttemptRecord]) -> VocabAttemptReplayPlan {
        let active = sourceAttempts.filter { $0.deletedAt == nil }
        let grouped = Dictionary(grouping: active) {
            VocabAttemptLogicalKey(sessionID: $0.sessionID, questionIndex: $0.questionIndex)
        }
        var canonical: [AttemptRecord] = []
        var conflicts: [VocabAttemptReplayConflict] = []
        for (key, attempts) in grouped {
            let ordered = attempts.sorted { $0.id.uuidString < $1.id.uuidString }
            guard let first = ordered.first else { continue }
            if ordered.dropFirst().allSatisfy({ attemptPayloadMatches(first, $0) }) {
                canonical.append(first)
            } else {
                conflicts.append(VocabAttemptReplayConflict(key: key, attemptIDs: ordered.map(\.id)))
            }
        }
        conflicts.sort {
            if $0.key.sessionID != $1.key.sessionID {
                return $0.key.sessionID.uuidString < $1.key.sessionID.uuidString
            }
            return $0.key.questionIndex < $1.key.questionIndex
        }
        return VocabAttemptReplayPlan(canonicalAttempts: canonical, conflicts: conflicts)
    }

    private static func attemptPayloadMatches(_ lhs: AttemptRecord, _ rhs: AttemptRecord) -> Bool {
        lhs.directionRaw == rhs.directionRaw
            && lhs.modeRaw == rhs.modeRaw
            && lhs.sessionID == rhs.sessionID
            && lhs.questionIndex == rhs.questionIndex
            && lhs.seoulDay == rhs.seoulDay
            && lhs.prompt == rhs.prompt
            && lhs.submittedAnswer == rhs.submittedAnswer
            && lhs.automaticJudgementRaw == rhs.automaticJudgementRaw
            && lhs.finalJudgementRaw == rhs.finalJudgementRaw
            && lhs.correctionRaw == rhs.correctionRaw
            && lhs.matchedMeaningID == rhs.matchedMeaningID
            && lhs.answeredAt == rhs.answeredAt
            && lhs.word?.id == rhs.word?.id
    }

    private func masterySatisfied(for word: WordRecord, at date: Date) -> Bool {
        let coreMeanings = word.activeMeanings.filter(\.isCore)
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

    private struct PresentationContext {
        let exposure: [UUID: PresentationStats]
        let alreadyPresentedTodayIDs: Set<UUID>
        let allPresentedIDs: Set<UUID>
    }

    private func activeWords() throws -> [WordRecord] {
        if let activeWordCache { return activeWordCache }
        let words = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate {
            $0.deletedAt == nil && $0.statusRaw == "active"
        }))
        activeWordCache = words
        return words
    }

    private func dailySets() throws -> [DailySetRecord] {
        if let dailySetCache { return dailySetCache }
        let sets = try context.fetch(FetchDescriptor<DailySetRecord>()).filter { $0.deletedAt == nil }
        dailySetCache = sets
        return sets
    }

    private func invalidateSessionCandidateCache() {
        activeWordCache = nil
        dailySetCache = nil
    }

    private func presentationContext(for words: [WordRecord], day: String, now: Date) throws -> PresentationContext {
        if words.contains(where: { ($0.reviewState?.presentationCount ?? 0) > 0 || $0.reviewState?.lastPresentedAt != nil }) {
            return presentationContextFromSummary(words, day: day)
        }

        let sessions = try activeSessionsAfterCompaction(now: now)
        let exposure = presentationStats(from: sessions)
        backfillPresentationSummary(exposure, into: words)
        return PresentationContext(
            exposure: exposure,
            alreadyPresentedTodayIDs: Set(sessions.filter { $0.seoulDay == day }.flatMap(\.wordIDs)),
            allPresentedIDs: Set(sessions.flatMap(\.wordIDs))
        )
    }

    private func presentationContextFromSummary(_ words: [WordRecord], day: String) -> PresentationContext {
        var exposure: [UUID: PresentationStats] = [:]
        var alreadyPresentedTodayIDs = Set<UUID>()
        var allPresentedIDs = Set<UUID>()
        for word in words {
            guard let state = word.reviewState else { continue }
            let presentationCount = state.presentationCount ?? 0
            let stats = PresentationStats(count: presentationCount, lastPresentedAt: state.lastPresentedAt)
            exposure[word.id] = stats
            if presentationCount > 0 { allPresentedIDs.insert(word.id) }
            if let lastPresentedAt = state.lastPresentedAt, SeoulCalendar.day(for: lastPresentedAt) == day {
                alreadyPresentedTodayIDs.insert(word.id)
            }
        }
        return PresentationContext(exposure: exposure, alreadyPresentedTodayIDs: alreadyPresentedTodayIDs, allPresentedIDs: allPresentedIDs)
    }

    private func presentationStats(from sessions: [TestSessionRecord]) -> [UUID: PresentationStats] {
        var stats: [UUID: PresentationStats] = [:]
        for session in sessions {
            for id in session.wordIDs {
                stats[id, default: PresentationStats()].count += 1
                if (stats[id]?.lastPresentedAt ?? .distantPast) < session.startedAt {
                    stats[id, default: PresentationStats()].lastPresentedAt = session.startedAt
                }
            }
        }
        return stats
    }

    private func backfillPresentationSummary(_ exposure: [UUID: PresentationStats], into words: [WordRecord]) {
        for word in words {
            guard let stats = exposure[word.id] else { continue }
            let state = word.reviewState ?? ReviewStateRecord()
            word.reviewState = state
            state.presentationCount = stats.count
            state.lastPresentedAt = stats.lastPresentedAt
        }
    }

    private func recordPresentation(for words: [WordRecord], at date: Date) {
        for word in words {
            let state = word.reviewState ?? ReviewStateRecord()
            word.reviewState = state
            state.presentationCount = (state.presentationCount ?? 0) + 1
            state.lastPresentedAt = date
        }
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
        do {
            _ = try activeSessionsAfterCompaction(now: now)
        } catch {
            assertionFailure("Failed to compact session history: \(error)")
        }
    }

    private func activeSessionsAfterCompaction(now: Date) throws -> [TestSessionRecord] {
        let cutoff = now.addingTimeInterval(-Double(LearningHistoryRetentionPolicy.keepSessionDays) * 86_400)
        let sessions = try context.fetch(FetchDescriptor<TestSessionRecord>()).filter { $0.deletedAt == nil }
        var active: [TestSessionRecord] = []
        active.reserveCapacity(sessions.count)
        for session in sessions {
            if session.startedAt < cutoff {
                context.delete(session)
            } else {
                active.append(session)
            }
        }
        return active
    }

    private func compactAttempts(for word: WordRecord, now: Date) {
        guard syncMode != .cloudKitPrivate else { return }
        let sorted = word.allAttempts.sorted { $0.answeredAt > $1.answeredAt }
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
        word.replaceAttempts(with: word.allAttempts.filter { attempt in
            let isRecent = recentIDs.contains(attempt.id)
            let isWithinRecentWindow = attempt.answeredAt >= keepAllCutoff
            let isFailed = attempt.finalJudgementRaw != FinalResult.correct.rawValue
            let isFailedWithinWindow = isFailed && attempt.answeredAt >= keepFailedCutoff
            return isRecent || isWithinRecentWindow || isFailedWithinWindow
        })
    }

    private func deleteWordRecord(_ word: WordRecord) throws {
        let now = Date.now
        for set in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            for item in set.allItems where item.wordID == word.id && item.deletedAt == nil {
                tombstone(item, at: now)
            }
        }
        for meaning in word.activeMeanings {
            tombstone(meaning, at: now)
        }
        tombstone(word, at: now)
    }

    private func tombstone(_ word: WordRecord, at date: Date = .now) {
        word.deletedAt = date
        word.updatedAt = date
        context.insert(RecordTombstone(recordID: word.id, recordType: "WordRecord", deletedAt: date))
    }

    private func tombstone(_ meaning: MeaningRecord, at date: Date = .now) {
        meaning.deletedAt = date
        meaning.updatedAt = date
        context.insert(RecordTombstone(recordID: meaning.id, recordType: "MeaningRecord", deletedAt: date))
    }

    private func tombstone(_ item: DailySetItemRecord, at date: Date = .now) {
        item.deletedAt = date
        item.updatedAt = date
        context.insert(RecordTombstone(recordID: item.id, recordType: "DailySetItemRecord", deletedAt: date))
    }

    private func tombstone(_ set: DailySetRecord, at date: Date = .now) {
        set.deletedAt = date
        set.updatedAt = date
        context.insert(RecordTombstone(recordID: set.id, recordType: "DailySetRecord", deletedAt: date))
    }

    private func uniqueWords(_ words: [WordRecord]) -> [WordRecord] {
        var seen = Set<UUID>()
        return words.filter { word in
            seen.insert(word.id).inserted
        }
    }

    private func typoCandidate(_ answer: String, for question: SessionQuestion) -> Bool {
        let target = question.direction == .enToKo ? question.word.activeMeanings.first?.text ?? "" : question.word.term
        return abs(answer.count - target.count) <= 1 && answer != target
    }
}

enum VocabHydrationState: String, Equatable {
    case localOnly
    case awaitingBootstrapMetadata
    case hydrating
    case reconciling
    case ready
    case failed
}

struct VocabEntityCounts: Codable, Equatable {
    var words: Int
    var meanings: Int
    var dailySets: Int
    var dailySetItems: Int
    var testSessions: Int
    var attempts: Int
    var anonymousAggregates: Int
    var memoryAidCaches: Int
    var tombstones: Int

    func satisfies(_ metadata: CloudBootstrapRecord) -> Bool {
        words >= metadata.expectedWordCount
            && meanings >= metadata.expectedMeaningCount
            && dailySets >= metadata.expectedDailySetCount
            && dailySetItems >= metadata.expectedDailySetItemCount
            && testSessions >= metadata.expectedTestSessionCount
            && attempts >= metadata.expectedAttemptCount
            && anonymousAggregates >= metadata.expectedAnonymousAggregateCount
            && memoryAidCaches >= metadata.expectedMemoryAidCacheCount
            && tombstones >= metadata.expectedTombstoneCount
    }
}

struct VocabHydrationStatus: Equatable {
    let state: VocabHydrationState
    let counts: VocabEntityCounts
    let expectedBootstrapUUID: UUID?
    let message: String?

    var permitsUserDataMutation: Bool {
        state == .localOnly || state == .ready
    }
}

struct VocabBootstrapToken: Codable, Equatable {
    let claimID: UUID
    let requestID: UUID

    var id: UUID { requestID }

    init(claimID: UUID = UUID(), requestID: UUID = UUID()) {
        self.claimID = claimID
        self.requestID = requestID
    }

    init(id: UUID) {
        claimID = id
        requestID = id
    }
}

protocol VocabBootstrapCredentialDataStoring {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

enum VocabBootstrapCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "bootstrap claim Keychain 처리에 실패했습니다. (OSStatus \(status))"
        }
    }
}

struct VocabBootstrapCredentialKeychainStore: VocabBootstrapCredentialDataStoring {
    private let service = "com.swainyun.Vocab.bootstrap"
    private let account = "claim-credential-v1"

    func load() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VocabBootstrapCredentialStoreError.keychain(status)
        }
        return data
    }

    func save(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VocabBootstrapCredentialStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw VocabBootstrapCredentialStoreError.keychain(status)
        }
    }
}

enum VocabBootstrapTokenStore {
    private static let claimKey = "vocabPendingBootstrapClaimID"
    private static let requestKey = "vocabPendingBootstrapRequestID"
    private static let migrationKey = "vocabBootstrapCredentialMigrationV1"

    struct Credential: Codable, Equatable {
        var token: VocabBootstrapToken
        var originDeviceID: String
        var request: VocabBootstrapClaimRequest?
    }

    static func load(
        defaults: UserDefaults = .standard,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws -> Credential? {
        if let data = try dataStore.load() {
            return try JSONDecoder.vocabSnapshotDecoder.decode(Credential.self, from: data)
        }
        guard !defaults.bool(forKey: migrationKey) else { return nil }
        guard let token = legacyToken(defaults: defaults) else {
            defaults.set(true, forKey: migrationKey)
            return nil
        }
        let credential = Credential(token: token, originDeviceID: VocabDeviceIdentity.current, request: nil)
        try save(credential, to: dataStore)
        defaults.removeObject(forKey: claimKey)
        defaults.removeObject(forKey: requestKey)
        defaults.set(true, forKey: migrationKey)
        return credential
    }

    static func createAndPersist(
        defaults: UserDefaults = .standard,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws -> Credential {
        if let existing = try load(defaults: defaults, dataStore: dataStore) { return existing }
        let credential = Credential(
            token: VocabBootstrapToken(),
            originDeviceID: VocabDeviceIdentity.current,
            request: nil
        )
        try save(credential, to: dataStore)
        return credential
    }

    static func persist(
        _ request: VocabBootstrapClaimRequest,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws {
        try save(Credential(
            token: VocabBootstrapToken(claimID: request.claimID, requestID: request.requestID),
            originDeviceID: request.ownerDeviceID,
            request: request
        ), to: dataStore)
    }

    private static func legacyToken(defaults: UserDefaults) -> VocabBootstrapToken? {
        guard let claimRaw = defaults.string(forKey: claimKey),
              let requestRaw = defaults.string(forKey: requestKey),
              let claimID = UUID(uuidString: claimRaw),
              let requestID = UUID(uuidString: requestRaw) else { return nil }
        return VocabBootstrapToken(claimID: claimID, requestID: requestID)
    }

    private static func save(
        _ credential: Credential,
        to dataStore: any VocabBootstrapCredentialDataStoring
    ) throws {
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(credential)
        try dataStore.save(data)
    }
}

enum VocabCloudReconciliationError: LocalizedError, Equatable {
    case hydrationNotReady(VocabHydrationState)
    case unsupportedSchemaVersion(Int)
    case bootstrapTokenRequired
    case attemptReplayConflicts([VocabAttemptReplayConflict])

    var errorDescription: String? {
        switch self {
        case .hydrationNotReady(let state):
            "iCloud hydration이 \(state.rawValue) 상태여서 쓰기 작업을 중단했습니다."
        case .unsupportedSchemaVersion(let version):
            "지원하지 않는 iCloud metadata schema version입니다: \(version)"
        case .bootstrapTokenRequired:
            "Mac 최초 bootstrap에는 사용자 확인으로 발급된 일회성 token이 필요합니다."
        case .attemptReplayConflicts(let conflicts):
            "동일한 테스트 문항에 서로 다른 Attempt payload가 \(conflicts.count)건 있어 ReviewState 재계산을 중단했습니다."
        }
    }
}

@MainActor
enum VocabCloudReconciler {
    static let metadataSchemaVersion = 2

    static func counts(context: ModelContext) throws -> VocabEntityCounts {
        VocabEntityCounts(
            words: try context.fetchCount(FetchDescriptor<WordRecord>()),
            meanings: try context.fetchCount(FetchDescriptor<MeaningRecord>()),
            dailySets: try context.fetchCount(FetchDescriptor<DailySetRecord>()),
            dailySetItems: try context.fetchCount(FetchDescriptor<DailySetItemRecord>()),
            testSessions: try context.fetchCount(FetchDescriptor<TestSessionRecord>()),
            attempts: try context.fetchCount(FetchDescriptor<AttemptRecord>()),
            anonymousAggregates: try context.fetchCount(FetchDescriptor<AnonymousAggregateRecord>()),
            memoryAidCaches: try context.fetchCount(FetchDescriptor<MemoryAidCacheRecord>()),
            tombstones: try context.fetchCount(FetchDescriptor<RecordTombstone>())
        )
    }

    static func hydrationStatus(context: ModelContext, syncMode: VocabSyncMode) throws -> VocabHydrationStatus {
        let actual = try counts(context: context)
        guard syncMode == .cloudKitPrivate else {
            return VocabHydrationStatus(state: .localOnly, counts: actual, expectedBootstrapUUID: nil, message: nil)
        }
        let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
            .filter { $0.deletedAt == nil && $0.key == "primary" }
            .sorted { $0.createdAt < $1.createdAt }
            .last
        guard let metadata else {
            return VocabHydrationStatus(
                state: .awaitingBootstrapMetadata,
                counts: actual,
                expectedBootstrapUUID: nil,
                message: "bootstrap metadata가 아직 관찰되지 않았습니다."
            )
        }
        guard metadata.schemaVersion == metadataSchemaVersion, !metadata.contentFingerprint.isEmpty else {
            return VocabHydrationStatus(
                state: .failed,
                counts: actual,
                expectedBootstrapUUID: metadata.bootstrapUUID,
                message: "metadata schema 또는 fingerprint가 유효하지 않습니다."
            )
        }
        guard actual.satisfies(metadata) else {
            return VocabHydrationStatus(
                state: .hydrating,
                counts: actual,
                expectedBootstrapUUID: metadata.bootstrapUUID,
                message: "metadata의 예상 엔티티 개수가 아직 도착하지 않았습니다."
            )
        }
        return VocabHydrationStatus(
            state: metadata.lastReconciledAt == nil ? .reconciling : .ready,
            counts: actual,
            expectedBootstrapUUID: metadata.bootstrapUUID,
            message: nil
        )
    }

    @discardableResult
    static func reconcile(context: ModelContext, syncMode: VocabSyncMode, now: Date = .now) throws -> VocabHydrationStatus {
        let initial = try hydrationStatus(context: context, syncMode: syncMode)
        guard initial.state == .localOnly || initial.state == .reconciling || initial.state == .ready else {
            throw VocabCloudReconciliationError.hydrationNotReady(initial.state)
        }

        let allAttempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        if syncMode == .cloudKitPrivate {
            let replayPlan = LearningCoordinator.attemptReplayPlan(allAttempts)
            guard replayPlan.conflicts.isEmpty else {
                throw VocabCloudReconciliationError.attemptReplayConflicts(replayPlan.conflicts)
            }
        }

        let tombstones = try context.fetch(FetchDescriptor<RecordTombstone>())
        var winningDeletion: [String: Date] = [:]
        for tombstone in tombstones {
            let key = "\(tombstone.recordType):\(tombstone.recordID.uuidString)"
            winningDeletion[key] = max(winningDeletion[key] ?? .distantPast, tombstone.deletedAt)
        }
        func deletion(_ type: String, _ id: UUID) -> Date? {
            winningDeletion["\(type):\(id.uuidString)"]
        }
        for record in try context.fetch(FetchDescriptor<WordRecord>()) {
            if let date = deletion("WordRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
            }
        }
        for record in try context.fetch(FetchDescriptor<MeaningRecord>()) {
            if let date = deletion("MeaningRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
            }
        }
        for record in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            if let date = deletion("DailySetRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
            }
        }
        for record in try context.fetch(FetchDescriptor<DailySetItemRecord>()) {
            if let date = deletion("DailySetItemRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
            }
        }

        if syncMode == .cloudKitPrivate {
            let coordinator = LearningCoordinator(context: context, syncMode: syncMode)
            for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
                coordinator.recomputeReviewState(
                    for: word,
                    attempts: allAttempts.filter { $0.word?.id == word.id }
                )
            }
        }
        if syncMode == .cloudKitPrivate {
            let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
                .first { $0.deletedAt == nil && $0.key == "primary" }
            metadata?.lastReconciledAt = now
            metadata?.updatedAt = now
        }
        try context.save()
        return try hydrationStatus(context: context, syncMode: syncMode)
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
