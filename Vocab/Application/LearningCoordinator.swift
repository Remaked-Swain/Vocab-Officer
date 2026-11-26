import Foundation
import SwiftData

extension Notification.Name {
    /// Consumed by `VocabStoreChangeMonitor`; store changes themselves are
    /// observed through `ModelContext.didSave`.
    static let vocabMasteryCleanupRequested = Notification.Name("vocabMasteryCleanupRequested")
}

enum LearningHistoryRetentionPolicy {
    static let recentAttemptLimitPerWord = 40
    static let keepAllAttemptsDays = 90
    static let keepFailedAttemptsDays = 365
    static let keepSessionDays = 180
}

enum SessionMode: String, CaseIterable, Identifiable {
    case today = "오늘 신규"
    case set = "세트 선택"
    case loose = "낱개"
    case review = "복습"
    case mixed = "혼합"

    static var allCases: [SessionMode] { [.today, .review, .mixed] }
    var id: String { rawValue }
}

enum PracticeDirection: String, CaseIterable, Identifiable {
    case enToKo = "영어 -> 한국어"
    case koToEn = "한국어 -> 영어"
    var id: String { rawValue }
}

enum QuestionFormat: String, CaseIterable, Identifiable {
    case typed
    case multipleChoice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typed: "직접 입력"
        case .multipleChoice: "4지선택형"
        }
    }
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

struct VocabAttemptCanonicalPayload: Equatable {
    static let signatureVersion = 1

    let directionRaw: String
    let modeRaw: String
    let sessionID: UUID
    let questionIndex: Int
    let seoulDay: String
    let prompt: String
    let submittedAnswer: String
    let automaticJudgementRaw: String
    let finalJudgementRaw: String
    let correctionRaw: String?
    let questionFormatRaw: String
    let matchedMeaningID: UUID?
    let answeredAt: Date
    let wordID: UUID?

    init(_ record: AttemptRecord) {
        directionRaw = record.directionRaw
        modeRaw = record.modeRaw
        sessionID = record.sessionID
        questionIndex = record.questionIndex
        seoulDay = record.seoulDay
        prompt = record.prompt
        submittedAnswer = record.submittedAnswer
        automaticJudgementRaw = record.automaticJudgementRaw
        finalJudgementRaw = record.finalJudgementRaw
        correctionRaw = record.correctionRaw
        questionFormatRaw = record.questionFormatRaw
        matchedMeaningID = record.matchedMeaningID
        answeredAt = record.answeredAt
        wordID = record.word?.id
    }

    var signatureComponents: [String] {
        [
            directionRaw, modeRaw, sessionID.uuidString, String(questionIndex), seoulDay,
            prompt, submittedAnswer, automaticJudgementRaw, finalJudgementRaw,
            correctionRaw ?? "", questionFormatRaw, matchedMeaningID?.uuidString ?? "",
            String(answeredAt.timeIntervalSince1970), wordID?.uuidString ?? ""
        ]
    }
}

struct MultipleChoiceOption: Identifiable, Equatable {
    let id: UUID
    let label: String
    let isCorrect: Bool
    let matchedMeaningID: UUID?
}

struct SessionQuestion: Identifiable {
    let id = UUID()
    let word: WordRecord
    let direction: PracticeDirection
    let format: QuestionFormat
    let index: Int
    let choices: [MultipleChoiceOption]

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
    private static let legacyMasteredRawValue = "mastered"
    private static let legacyConsolidationPrefix = "consolidatingLegacy@"

    var learningStatus: VocabularyLearningStatus {
        get {
            if statusRaw == Self.legacyMasteredRawValue
                || statusRaw.hasPrefix(Self.legacyConsolidationPrefix) {
                return .consolidating
            }
            return VocabularyLearningStatus(rawValue: statusRaw) ?? .active
        }
        set { statusRaw = newValue.rawValue }
    }

    var learningStatusTitle: String {
        learningStatus.koreanTitle
    }

    var legacyMasteryEvidenceBoundary: Date? {
        guard statusRaw.hasPrefix(Self.legacyConsolidationPrefix),
              let seconds = TimeInterval(statusRaw.dropFirst(Self.legacyConsolidationPrefix.count)) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    func markLegacyMasteryAsConsolidating(at date: Date) {
        statusRaw = legacyConsolidationStatus(at: date)
    }

    func legacyConsolidationStatus(at date: Date) -> String {
        Self.legacyConsolidationPrefix + String(date.timeIntervalSince1970)
    }

    var registrationDay: String {
        SeoulCalendar.day(for: createdAt)
    }

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

final class LearningCoordinator {
    private let context: ModelContext
    private let syncMode: VocabSyncMode
    private let authoringCapability: VocabAuthoringCapability
    private let learningFactAuthority: VocabMutationAuthority
    private var activeWordCache: [WordRecord]?
    private var activeWordByIDCache: [UUID: WordRecord]?
    private var consolidatingWordCache: [WordRecord]?
    private var dailySetCache: [DailySetRecord]?
    private var dailySetMembershipIndexCache: DailySetMembershipIndex?

    init(
        context: ModelContext,
        syncMode: VocabSyncMode = .current(allowsCloudKit: true),
        authoringCapability: VocabAuthoringCapability = .currentPlatform,
        mutationAuthority: VocabMutationAuthority = .runtimeCurrent
    ) {
        self.context = context
        self.syncMode = syncMode
        self.authoringCapability = authoringCapability
        self.learningFactAuthority = mutationAuthority
    }

    private func saveAndNotifyChange() throws {
        // Observers learn of the save from `ModelContext.didSave`.
        try context.save()
    }

    @discardableResult
    func saveDailySet(_ drafts: [WordDraft], date: Date = .now) throws -> DailySetRecord {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        let validDrafts = drafts.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !validDrafts.isEmpty, validDrafts.count <= 100 else {
            throw LearningError.dailySetCountOutOfRange
        }
        let day = SeoulCalendar.day(for: date)
        let existingSet = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate {
            $0.seoulDay == day && $0.deletedAt == nil
        })).first
        let existingItemCount = existingSet?.allItems.filter { $0.deletedAt == nil }.count ?? 0
        guard existingItemCount < 100 else { throw LearningError.dailySetAlreadyExists }
        guard existingItemCount + validDrafts.count <= 100 else {
            throw LearningError.dailySetExceeds100(remaining: 100 - existingItemCount)
        }
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

        let set = existingSet ?? DailySetRecord(seoulDay: day, createdAt: date)
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
            let item = DailySetItemRecord(orderIndex: existingItemCount + index, entryKind: isNewHeadword ? "newHeadword" : "reusedHeadword", wordID: word.id)
            item.set = set
            set.appendItem(item)
            context.insert(item)
        }
        set.completedAt = existingItemCount + validDrafts.count == 100 ? date : nil
        set.updatedAt = date
        if existingSet == nil { context.insert(set) }
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
        return set
    }

    @available(*, deprecated, message: "Use registerWords(_:date:) for the unified vocabulary.")
    @discardableResult
    func addLooseWord(term: String, meaningsText: String, date: Date = .now) throws -> WordRecord {
        let words = try registerWords([WordDraft(term: term, meanings: meaningsText)], date: date)
        guard let word = words.first else { throw LearningError.termRequired }
        return word
    }

    @available(*, deprecated, message: "Use registerWords(_:date:) for the unified vocabulary.")
    @discardableResult
    func addLooseWords(_ drafts: [WordDraft], date: Date = .now) throws -> [WordRecord] {
        try registerWords(drafts, date: date)
    }

    /// Registers vocabulary without creating a set. Existing headwords retain their
    /// first registration date and receive only previously unknown meanings.
    @discardableResult
    func registerWords(_ drafts: [WordDraft], date: Date = .now) throws -> [WordRecord] {
        try registerWordsWithSummary(drafts, date: date).words
    }

    func registerWordsWithSummary(
        _ drafts: [WordDraft],
        date: Date = .now
    ) throws -> VocabularyRegistrationResult {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        // Fixed-size intake tables pass their untouched rows; a row with
        // neither headword nor meanings is not input. A half-filled row still
        // fails below with the missing field.
        let drafts = drafts.filter { !$0.isBlank }
        guard !drafts.isEmpty else { throw LearningError.termRequired }
        let prepared = try drafts.map { draft -> (term: String, normalizedTerm: String, meanings: [String]) in
            let term = draft.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { throw LearningError.termRequired }
            let meanings = MeaningTextSplitter.split(draft.meanings)
            guard !meanings.isEmpty else { throw LearningError.meaningRequired }
            return (term, TextNormalizer.normalizeEnglish(term), meanings)
        }
        let matchingWords = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate { word in
            word.deletedAt == nil
        }))
        var wordsByNormalizedTerm: [String: WordRecord] = [:]
        wordsByNormalizedTerm.reserveCapacity(matchingWords.count + prepared.count)
        for word in matchingWords {
            wordsByNormalizedTerm[word.normalizedTerm] = word
        }
        let existingNormalizedTerms = Set(wordsByNormalizedTerm.keys)
        let uniqueInputHeadwords = Set(prepared.map(\.normalizedTerm))
        var savedWords: [WordRecord] = []
        savedWords.reserveCapacity(prepared.count)
        var savedWordIDs = Set<UUID>()
        var newlyCreatedWordIDs = Set<UUID>()
        var meaningsAddedToExistingHeadwords = 0
        let mutationRecordedAt = Date.now

        for value in prepared {
            let word: WordRecord
            if let existing = wordsByNormalizedTerm[value.normalizedTerm] {
                word = existing
                if word.reviewState == nil {
                    word.reviewState = ReviewStateRecord()
                }
            } else {
                let newWord = WordRecord(term: value.term, createdAt: date)
                newWord.reviewState = ReviewStateRecord()
                context.insert(newWord)
                wordsByNormalizedTerm[value.normalizedTerm] = newWord
                newlyCreatedWordIDs.insert(newWord.id)
                word = newWord
            }

            var didMutate = false
            var existingMeanings = Set(word.activeMeanings.map(\.normalizedText))
            for meaningText in value.meanings {
                let normalizedMeaning = TextNormalizer.normalizeKorean(meaningText)
                guard existingMeanings.insert(normalizedMeaning).inserted else { continue }
                let meaning = MeaningRecord(text: meaningText)
                meaning.word = word
                word.appendMeaning(meaning)
                context.insert(meaning)
                didMutate = true
                if existingNormalizedTerms.contains(value.normalizedTerm) {
                    meaningsAddedToExistingHeadwords += 1
                }
            }
            if didMutate && !newlyCreatedWordIDs.contains(word.id) {
                let monotonicBoundary = word.updatedAt.addingTimeInterval(0.001)
                word.updatedAt = max(max(monotonicBoundary, date), mutationRecordedAt)
                if word.learningStatus != .active {
                    word.learningStatus = .active
                }
                resetMasteryEvidence(for: word)
            }
            if savedWordIDs.insert(word.id).inserted {
                savedWords.append(word)
            }
        }
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
        let matchedExistingHeadwordCount = uniqueInputHeadwords.intersection(existingNormalizedTerms).count
        return VocabularyRegistrationResult(
            words: savedWords,
            inputRowCount: prepared.count,
            createdHeadwordCount: uniqueInputHeadwords.count - matchedExistingHeadwordCount,
            matchedExistingHeadwordCount: matchedExistingHeadwordCount,
            duplicateInputRowCount: prepared.count - uniqueInputHeadwords.count,
            meaningsAddedToExistingHeadwords: meaningsAddedToExistingHeadwords
        )
    }

    func generateSession(mode: SessionMode, direction: PracticeDirection, setID: UUID? = nil, date: Date = .now, format: QuestionFormat = .typed) throws -> (TestSessionRecord, [SessionQuestion]) {
        try requireLearningFactWriting()
        let day = SeoulCalendar.day(for: date)
        let candidates = try sessionCandidates(mode: mode, setID: setID, day: day, date: date)
        return try startSession(
            selecting: candidates.selected,
            from: candidates.pool,
            mode: mode,
            direction: direction,
            format: format,
            day: day,
            date: date
        )
    }

    /// Selects up to 20 words for `mode` under the session policy; `pool` is
    /// every word a multiple-choice distractor may come from.
    private func sessionCandidates(
        mode: SessionMode,
        setID: UUID?,
        day: String,
        date: Date
    ) throws -> (selected: [WordRecord], pool: [WordRecord]) {
        let words = try activeWords()
        let maintenanceWords: [WordRecord]
        switch mode {
        case .review, .mixed:
            maintenanceWords = try consolidatingWords()
        case .today, .set, .loose:
            maintenanceWords = []
        }
        let wordsByID = try activeWordsByID()
        let usesLegacySetMembership = mode == .set || mode == .loose
        let sets = usesLegacySetMembership ? try dailySets() : []
        let wordsByRegistrationDay = Dictionary(grouping: words, by: \.registrationDay)
        let registrationDays = wordsByRegistrationDay.keys.filter { $0 <= day }.sorted(by: >)
        let eligibleActiveWords = words.filter { $0.registrationDay <= day }
        let referenceDay = registrationDays.first
        let previousDay = registrationDays.dropFirst().first
        let presentation = try presentationContext(for: words + maintenanceWords, day: day, now: date)
        let exposure = presentation.exposure
        let alreadyPresentedTodayIDs = presentation.alreadyPresentedTodayIDs
        let allPresentedIDs = presentation.allPresentedIDs
        let setMembership = dailySetMembershipIndex(for: sets)
        var selected: [WordRecord] = []
        func setWords(for set: DailySetRecord?) -> [WordRecord] {
            guard let set else { return [] }
            return setMembership.wordIDsBySetID[set.id, default: []].compactMap { wordsByID[$0] }
        }
        func registeredWords(on registrationDay: String?) -> [WordRecord] {
            guard let registrationDay else { return [] }
            return wordsByRegistrationDay[registrationDay, default: []]
        }
        func referenceCandidates() -> [WordRecord] {
            let referenceWords = registeredWords(on: referenceDay)
            return uniqueWords(
                fairOrder(referenceWords.filter { !alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
                    + fairOrder(referenceWords.filter { alreadyPresentedTodayIDs.contains($0.id) }, exposure: exposure)
            )
        }
        func orderedReviewCandidates(preferUnseenToday: Bool = false) -> [WordRecord] {
            let review = eligibleActiveWords.filter { record in
                guard let state = record.reviewState else { return false }
                return state.activePriority > 0
            }
            guard preferUnseenToday else {
                return reviewOrder(review, exposure: exposure)
            }
            let unseenToday = review.filter { !alreadyPresentedTodayIDs.contains($0.id) }
            let seenToday = review.filter { alreadyPresentedTodayIDs.contains($0.id) }
            return reviewOrder(unseenToday, exposure: exposure)
                + reviewOrder(seenToday, exposure: exposure)
        }
        let linkedWordIDs = setMembership.linkedWordIDs
        let legacyLooseCandidates = fairOrder(
            words.filter { !linkedWordIDs.contains($0.id) },
            exposure: exposure
        )
        let maintenancePolicy = MasteryMaintenancePolicy()
        let promotionPolicy = MasteryPromotionPolicy()
        let promotionCandidates = fairOrderPreferUnseenToday(
            eligibleActiveWords.filter { word in
                promotionPolicy.isDue(
                    verifiedSuccessDays: verifiedSuccessDays(for: word),
                    latestWrongAt: word.reviewState?.latestWrongAt,
                    asOf: date
                )
            },
            exposure: exposure,
            alreadyPresentedTodayIDs: alreadyPresentedTodayIDs
        )
        let masteryMaintenanceCandidates = orderedMasteryMaintenanceCandidates(
            maintenanceWords,
            policy: maintenancePolicy,
            asOf: date,
            exposure: exposure,
            alreadyPresentedTodayIDs: alreadyPresentedTodayIDs,
            preferUnseenToday: false
        )
        switch mode {
        case .today:
            let reference = referenceCandidates()
            selected = Array(reference.prefix(20))
        case .set:
            guard let setID, let selectedSet = sets.first(where: { $0.id == setID }) else {
                throw LearningError.setRequired
            }
            let selectedSetWords = setWords(for: selectedSet)
            let prioritized = fairOrder(selectedSetWords.filter { !allPresentedIDs.contains($0.id) }, exposure: exposure)
                + fairOrder(selectedSetWords.filter { allPresentedIDs.contains($0.id) }, exposure: exposure)
            selected = Array(prioritized.prefix(20))
        case .loose:
            selected = Array(legacyLooseCandidates.prefix(20))
        case .review:
            let orderedReview = orderedReviewCandidates()
            let previousRegistrationCandidates = fairOrder(registeredWords(on: previousDay), exposure: exposure)
            let reference = referenceCandidates()
            let masteryMaintenance = Array(
                masteryMaintenanceCandidates.prefix(maintenancePolicy.reviewMaximumQuestionsPerSession)
            )
            let activeCapacity = 20 - masteryMaintenance.count
            selected = Array(orderedReview.prefix(14))
            appendUnique(from: promotionCandidates, to: &selected, limit: activeCapacity)
            appendUnique(
                from: previousRegistrationCandidates,
                to: &selected,
                limit: min(activeCapacity, selected.count + 6)
            )
            appendUnique(from: masteryMaintenance, to: &selected, limit: 20)
            appendUnique(from: orderedReview, to: &selected, limit: 20)
            appendUnique(from: reference, to: &selected, limit: 20)
        case .mixed:
            let composition = MixedSessionCompositionPolicy()
            let orderedReview = orderedReviewCandidates(preferUnseenToday: true)
            let mixedMaintenanceCandidates = orderedMasteryMaintenanceCandidates(
                maintenanceWords,
                policy: maintenancePolicy,
                asOf: date,
                exposure: exposure,
                alreadyPresentedTodayIDs: alreadyPresentedTodayIDs,
                preferUnseenToday: true
            )
            let allActiveRotation = fairOrderPreferUnseenToday(
                eligibleActiveWords,
                exposure: exposure,
                alreadyPresentedTodayIDs: alreadyPresentedTodayIDs
            )
            let rotationFloor = eligibleActiveWords.map {
                exposure[$0.id]?.count ?? 0
            }.min() ?? 0
            let promotionWordIDs = Set(promotionCandidates.map(\.id))
            let reviewWordIDs = Set(orderedReview.map(\.id))
            let reviewAtRotationFloor = orderedReview.filter {
                (exposure[$0.id]?.count ?? 0) == rotationFloor
            }
            let selectedIDs = composition.select(
                promotionDue: promotionCandidates.map(\.id),
                promotionDueCategoryIDs: promotionWordIDs,
                activeReview: reviewAtRotationFloor.map(\.id),
                activeReviewCategoryIDs: reviewWordIDs,
                masteryMaintenance: mixedMaintenanceCandidates.map(\.id),
                broadRotation: allActiveRotation.map(\.id),
                presentedToday: alreadyPresentedTodayIDs
            )
            let maintenanceWordsByID = Dictionary(
                uniqueKeysWithValues: maintenanceWords.map { ($0.id, $0) }
            )
            selected = selectedIDs.compactMap { wordsByID[$0] ?? maintenanceWordsByID[$0] }
        }
        return (selected, words + maintenanceWords)
    }

    /// Persists a session for the questions that could be built from the
    /// candidates; with none it throws `noSessionCandidates` and saves nothing.
    private func startSession(
        selecting candidates: [WordRecord],
        from pool: [WordRecord],
        mode: SessionMode,
        direction: PracticeDirection,
        format: QuestionFormat,
        day: String,
        date: Date
    ) throws -> (TestSessionRecord, [SessionQuestion]) {
        let sessionID = UUID()
        let questions = makeQuestions(
            selected: candidates,
            allWords: pool,
            direction: direction,
            format: format,
            sessionID: sessionID
        )
        guard !questions.isEmpty else { throw LearningError.noSessionCandidates }
        let selected = questions.map(\.word)
        let session = TestSessionRecord(id: sessionID, directionRaw: direction.rawValue, modeRaw: mode.rawValue, seoulDay: day, wordIDs: selected.map(\.id), wasReduced: selected.count < 20, startedAt: date, questionFormatRaw: format.rawValue)
        context.insert(session)
        recordPresentation(for: selected, at: date)
        try saveAndNotifyChange()
        return (session, questions)
    }

    func judge(answer: String, for question: SessionQuestion) -> JudgeResult {
        if question.format == .multipleChoice {
            return judgeMultipleChoice(answer: answer, for: question)
        }
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

    private func judgeMultipleChoice(answer: String, for question: SessionQuestion) -> JudgeResult {
        guard let selectedID = UUID(uuidString: answer),
              let option = question.choices.first(where: { $0.id == selectedID }) else {
            return JudgeResult(automaticResult: .incorrect, matchedMeaningID: nil, isTypoSuggestion: false)
        }
        return JudgeResult(
            automaticResult: option.isCorrect ? .correct : .incorrect,
            matchedMeaningID: option.isCorrect ? option.matchedMeaningID : nil,
            isTypoSuggestion: false
        )
    }

    private func storedAnswer(_ answer: String, for question: SessionQuestion) -> String {
        guard question.format == .multipleChoice else { return answer }
        return question.choices.first { $0.id.uuidString == answer }?.label ?? answer
    }

    func commit(answer: String, result: FinalResult, automatic: FinalResult, matchedMeaningID: UUID?, question: SessionQuestion, session: TestSessionRecord, correction: String? = nil, date: Date = .now) throws {
        try requireLearningFactWriting()
        let existingAttempt = try context.fetch(FetchDescriptor<AttemptRecord>()).contains {
            $0.deletedAt == nil && $0.sessionID == session.id && $0.questionIndex == question.index
        }
        guard !existingAttempt else { return }
        let attempt = AttemptRecord(directionRaw: question.direction.rawValue, modeRaw: session.modeRaw, sessionID: session.id, questionIndex: question.index, seoulDay: SeoulCalendar.day(for: date), prompt: question.prompt, submittedAnswer: storedAnswer(answer, for: question), automaticJudgementRaw: automatic.rawValue, finalJudgementRaw: result.rawValue, matchedMeaningID: matchedMeaningID, answeredAt: date, questionFormatRaw: question.format.rawValue)
        attempt.correctionRaw = correction
        attempt.word = question.word
        question.word.appendAttempt(attempt)
        context.insert(attempt)
        recomputeReviewState(for: question.word)
        compactAttempts(for: question.word, now: date)
        try saveAndNotifyChange()
        if question.word.learningStatus == .mastered {
            NotificationCenter.default.post(name: .vocabMasteryCleanupRequested, object: nil)
        }
    }

    func completeSession(_ session: TestSessionRecord, date: Date = .now) throws {
        try requireLearningFactWriting()
        session.completedAt = date
        session.updatedAt = date
        try saveAndNotifyChange()
    }

    func updateWord(_ word: WordRecord, term: String, meaningsText: String) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
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
            removed.scrubDeletedContent()
            tombstone(removed, at: now)
        }
        word.replaceMeanings(with: revised)
        word.updatedAt = now

        if originalTerm != normalizedTerm {
            word.reviewState?.koToEnSuccessDays = []
        }
        if word.learningStatus != .active {
            word.learningStatus = .active
        }
        try saveAndNotifyChange()
        invalidateWordCandidateCaches()
    }

    func compactLearningHistory(now: Date = .now) throws {
        try requireLearningFactWriting()
        for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
            compactAttempts(for: word, now: now)
        }
        compactSessionHistory(now: now)
        try saveAndNotifyChange()
    }

    struct MasteryCleanupResult: Equatable, Sendable {
        let normalizedLegacyCount: Int
        let retiredCount: Int
    }

    @discardableResult
    func normalizeAndRetireMasteredWords(now: Date = .now) throws -> MasteryCleanupResult {
        try requireLearningFactWriting()
        let scrubbedExistingDeletion = try scrubPreviouslyDeletedIdentifyingRecords(at: now)
        let candidates = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate {
            $0.deletedAt == nil && $0.statusRaw != "active"
        }))
        var normalizedLegacyCount = 0
        var retiringWords: [WordRecord] = []

        for word in candidates {
            if word.statusRaw == "mastered" {
                word.markLegacyMasteryAsConsolidating(at: now)
                normalizedLegacyCount += 1
            } else if word.learningStatus == .mastered && masteryIsSatisfied(for: word) {
                retiringWords.append(word)
            } else if word.learningStatus == .mastered {
                word.learningStatus = .consolidating
                normalizedLegacyCount += 1
            }
        }
        try scrubAndTombstoneWords(retiringWords, at: now)
        let retiredCount = retiringWords.count

        if retiredCount > 0 {
            let aggregate = AnonymousAggregateRecord(
                seoulDay: SeoulCalendar.day(for: now),
                modeRaw: "automaticMasteryCleanup"
            )
            aggregate.deletedMasteredCount = retiredCount
            context.insert(aggregate)
        }
        guard scrubbedExistingDeletion || normalizedLegacyCount > 0 || retiredCount > 0 else {
            return MasteryCleanupResult(normalizedLegacyCount: 0, retiredCount: 0)
        }
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
        return MasteryCleanupResult(
            normalizedLegacyCount: normalizedLegacyCount,
            retiredCount: retiredCount
        )
    }

    func deleteMastered(_ word: WordRecord) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        guard word.learningStatus == .mastered else { throw LearningError.onlyMasteredCanBeDeleted }
        let day = SeoulCalendar.day(for: .now)
        let aggregate = AnonymousAggregateRecord(seoulDay: day, modeRaw: "deletion")
        aggregate.deletedMasteredCount = 1
        context.insert(aggregate)
        try scrubAndTombstoneWord(word)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
    }

    func deleteWords(_ words: [WordRecord]) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        try scrubAndTombstoneWords(words, at: .now)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
    }

    func discardDailySet(_ set: DailySetRecord) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        let allItems = try context.fetch(FetchDescriptor<DailySetItemRecord>()).filter { $0.deletedAt == nil }
        let wordsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WordRecord>()).filter { $0.deletedAt == nil }.map { ($0.id, $0) })
        var deletedWordIDs = Set<UUID>()

        for item in set.allItems {
            let isLinkedOutsideSet = allItems.contains { other in
                other.wordID == item.wordID && other.set?.id != set.id
            }
            if !isLinkedOutsideSet, let word = wordsByID[item.wordID], deletedWordIDs.insert(word.id).inserted {
                try scrubAndTombstoneWord(word)
            } else {
                tombstone(item)
            }
        }

        tombstone(set)
        try saveAndNotifyChange()
        invalidateSessionCandidateCache()
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
        let calculation = expectedReviewState(for: word, attempts: sourceAttempts)
        guard calculation.conflicts.isEmpty, let expected = calculation.expected else {
            return calculation.conflicts
        }
        if applyExpectedReviewState(expected, to: word) {
            invalidateWordCandidateCaches()
        }
        return []
    }

    struct RecomputedWordReviewState: Equatable {
        var statusRaw: String
        var failureCheck = 0
        var activePriority = 0
        var enToKoStreak = 0
        var koToEnStreak = 0
        var koToEnSuccessDays: [String] = []
        var latestWrongDirection: String?
        var latestWrongAt: Date?
        var lastTestedAt: Date?
        var presentationCount: Int?
        var lastPresentedAt: Date?
        var updatedAt: Date
        var meaningSuccessDays: [UUID: [String]]
    }

    func expectedReviewState(
        for word: WordRecord,
        attempts sourceAttempts: [AttemptRecord]
    ) -> (expected: RecomputedWordReviewState?, conflicts: [VocabAttemptReplayConflict]) {
        let replayPlan = Self.attemptReplayPlan(sourceAttempts)
        guard replayPlan.conflicts.isEmpty else { return (nil, replayPlan.conflicts) }

        let activeMeanings = word.activeMeanings
        let trackableCoreMeaningIDs = Set(activeMeanings.filter(\.isTrackableCoreMeaning).map(\.id))
        let unmigratedLegacyBoundary = word.statusRaw == "mastered"
            ? max(word.updatedAt, sourceAttempts.map(\.answeredAt).max() ?? word.updatedAt)
            : nil
        let legacyEvidenceBoundary = word.legacyMasteryEvidenceBoundary ?? unmigratedLegacyBoundary
        var expected = RecomputedWordReviewState(
            statusRaw: word.statusRaw,
            presentationCount: word.reviewState?.presentationCount,
            lastPresentedAt: word.reviewState?.lastPresentedAt,
            updatedAt: word.updatedAt,
            meaningSuccessDays: Dictionary(uniqueKeysWithValues: activeMeanings.map { ($0.id, []) })
        )

        let attempts = replayPlan.canonicalAttempts.sorted { lhs, rhs in
            lhs.answeredAt == rhs.answeredAt
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.answeredAt < rhs.answeredAt
        }
        for attempt in attempts {
            guard let result = FinalResult(rawValue: attempt.finalJudgementRaw),
                  let direction = PracticeDirection(rawValue: attempt.directionRaw) else { continue }
            expected.lastTestedAt = attempt.answeredAt
            let day = SeoulCalendar.day(for: attempt.answeredAt)
            switch result {
            case .incorrect, .unknown:
                expected.failureCheck = min(expected.failureCheck + 1, 3)
                expected.activePriority = max(expected.activePriority, expected.failureCheck)
                expected.latestWrongDirection = direction.rawValue
                expected.latestWrongAt = attempt.answeredAt
                if direction == .enToKo {
                    expected.enToKoStreak = 0
                } else {
                    expected.koToEnStreak = 0
                }
            case .correct:
                // An answer at or after the latest headword revision is evidence. The
                // legacy boundary is the last pre-migration answer itself, so only
                // strictly later answers may count past it.
                guard attempt.answeredAt >= word.updatedAt,
                      legacyEvidenceBoundary.map({ attempt.answeredAt > $0 }) ?? true else { continue }
                if direction == .enToKo {
                    expected.enToKoStreak += 1
                    if let meaningID = attempt.matchedMeaningID,
                       trackableCoreMeaningIDs.contains(meaningID),
                       expected.meaningSuccessDays[meaningID]?.contains(day) == false {
                        expected.meaningSuccessDays[meaningID, default: []].append(day)
                    }
                } else {
                    expected.koToEnStreak += 1
                    if !expected.koToEnSuccessDays.contains(day) {
                        expected.koToEnSuccessDays.append(day)
                    }
                }
                if expected.enToKoStreak >= 2 && expected.koToEnStreak >= 2 {
                    expected.activePriority = max(expected.activePriority - 1, 0)
                    expected.enToKoStreak = 0
                    expected.koToEnStreak = 0
                } else if expected.enToKoStreak >= 2 {
                    expected.activePriority = max(expected.activePriority - 1, 0)
                    expected.enToKoStreak = 0
                }
            }

        }
        var verifiedSuccessDays = Set(expected.koToEnSuccessDays)
        for successDays in expected.meaningSuccessDays.values {
            verifiedSuccessDays.formUnion(successDays)
        }
        if MasteryPolicy().isSatisfied(
            verifiedSuccessDays: verifiedSuccessDays,
            latestWrongAt: expected.latestWrongAt
        ) {
            expected.statusRaw = VocabularyLearningStatus.mastered.rawValue
        } else if let legacyEvidenceBoundary,
                  !(expected.latestWrongAt.map { $0 > legacyEvidenceBoundary } ?? false) {
            expected.statusRaw = word.legacyConsolidationStatus(at: legacyEvidenceBoundary)
        } else if ConsolidationPolicy().isSatisfied(
            verifiedSuccessDays: verifiedSuccessDays,
            latestWrongAt: expected.latestWrongAt
        ) {
            expected.statusRaw = VocabularyLearningStatus.consolidating.rawValue
        } else {
            expected.statusRaw = VocabularyLearningStatus.active.rawValue
        }
        expected.updatedAt = attempts.last?.answeredAt ?? word.updatedAt
        return (expected, [])
    }

    @discardableResult
    func applyExpectedReviewState(_ expected: RecomputedWordReviewState, to word: WordRecord) -> Bool {
        var changed = false
        func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<ReviewStateRecord, T>, _ value: T, to state: ReviewStateRecord) {
            guard state[keyPath: keyPath] != value else { return }
            state[keyPath: keyPath] = value
            changed = true
        }

        if word.statusRaw != expected.statusRaw {
            word.statusRaw = expected.statusRaw
            changed = true
        }
        let state: ReviewStateRecord
        if let existing = word.reviewState {
            state = existing
        } else {
            state = ReviewStateRecord()
            word.reviewState = state
            changed = true
        }
        assign(\.failureCheck, expected.failureCheck, to: state)
        assign(\.activePriority, expected.activePriority, to: state)
        assign(\.enToKoStreak, expected.enToKoStreak, to: state)
        assign(\.koToEnStreak, expected.koToEnStreak, to: state)
        assign(\.koToEnSuccessDays, expected.koToEnSuccessDays, to: state)
        assign(\.latestWrongDirection, expected.latestWrongDirection, to: state)
        assign(\.latestWrongAt, expected.latestWrongAt, to: state)
        assign(\.lastTestedAt, expected.lastTestedAt, to: state)
        assign(\.presentationCount, expected.presentationCount, to: state)
        assign(\.lastPresentedAt, expected.lastPresentedAt, to: state)
        assign(\.updatedAt, expected.updatedAt, to: state)

        for meaning in word.activeMeanings {
            let successDays = expected.meaningSuccessDays[meaning.id] ?? []
            guard meaning.successDays != successDays else { continue }
            meaning.successDays = successDays
            changed = true
        }
        return changed
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
        VocabAttemptCanonicalPayload(lhs) == VocabAttemptCanonicalPayload(rhs)
    }

    private func verifiedSuccessDays(for word: WordRecord) -> Set<String> {
        var successDays = Set(word.reviewState?.koToEnSuccessDays ?? [])
        for meaning in word.activeMeanings {
            successDays.formUnion(meaning.successDays)
        }
        return successDays
    }

    private func resetMasteryEvidence(for word: WordRecord) {
        word.reviewState?.koToEnSuccessDays = []
        word.reviewState?.enToKoStreak = 0
        word.reviewState?.koToEnStreak = 0
        for meaning in word.activeMeanings {
            meaning.successDays = []
        }
    }

    private func eligibleMasterySuccessDays(for word: WordRecord) -> Set<String> {
        let successDays = verifiedSuccessDays(for: word)
        guard let latestWrongAt = word.reviewState?.latestWrongAt else { return successDays }
        let latestWrongDay = SeoulCalendar.day(for: latestWrongAt)
        return successDays.filter { $0 > latestWrongDay }
    }

    private func masteryIsSatisfied(for word: WordRecord) -> Bool {
        MasteryPolicy().isSatisfied(
            verifiedSuccessDays: verifiedSuccessDays(for: word),
            latestWrongAt: word.reviewState?.latestWrongAt
        )
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

    private struct DailySetMembershipIndex {
        let linkedWordIDs: Set<UUID>
        let wordIDsBySetID: [UUID: [UUID]]
    }

    private struct MasteryMaintenanceCandidate {
        let word: WordRecord
        let dueAt: Date
        let wasPresentedToday: Bool
        let presentationCount: Int
        let lastPresentedAt: Date?
        let randomRank: Int
    }

    private struct FairCandidate {
        let word: WordRecord
        let presentationCount: Int
        let lastPresentedAt: Date?
        let randomRank: Int
    }

    private struct ReviewCandidate {
        let word: WordRecord
        let activePriority: Int
        let failureCheck: Int
        let latestWrongAt: Date?
        let presentationCount: Int
        let lastPresentedAt: Date?
        let randomRank: Int
    }

    private func activeWords() throws -> [WordRecord] {
        if let activeWordCache { return activeWordCache }
        let words = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate {
            $0.deletedAt == nil && $0.statusRaw == "active"
        }))
        activeWordCache = words
        activeWordByIDCache = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        return words
    }

    private func activeWordsByID() throws -> [UUID: WordRecord] {
        if let activeWordByIDCache { return activeWordByIDCache }
        _ = try activeWords()
        return activeWordByIDCache ?? [:]
    }

    private func consolidatingWords() throws -> [WordRecord] {
        if let consolidatingWordCache { return consolidatingWordCache }
        let words = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate {
            $0.deletedAt == nil
                && $0.statusRaw != "active"
                && $0.statusRaw != "masteredV2"
        })).filter { $0.learningStatus == .consolidating }
        consolidatingWordCache = words
        return words
    }

    private func dailySets() throws -> [DailySetRecord] {
        if let dailySetCache { return dailySetCache }
        let sets = try context.fetch(FetchDescriptor<DailySetRecord>()).filter { $0.deletedAt == nil }
        dailySetCache = sets
        return sets
    }

    private func makeQuestions(
        selected: [WordRecord],
        allWords: [WordRecord],
        direction: PracticeDirection,
        format: QuestionFormat,
        sessionID: UUID
    ) -> [SessionQuestion] {
        switch format {
        case .typed:
            return selected.enumerated().map {
                SessionQuestion(word: $0.element, direction: direction, format: .typed, index: $0.offset, choices: [])
            }
        case .multipleChoice:
            var questions: [SessionQuestion] = []
            let choiceCandidates = uniqueWords(selected + allWords).compactMap {
                multipleChoiceCandidate(for: $0, direction: direction)
            }
            let choiceCandidatesByWordID = Dictionary(uniqueKeysWithValues: choiceCandidates.map { ($0.wordID, $0) })
            for word in selected {
                guard let target = choiceCandidatesByWordID[word.id] else { continue }
                guard let choices = multipleChoiceOptions(
                    for: target,
                    candidates: choiceCandidates,
                    sessionID: sessionID,
                    questionIndex: questions.count
                ) else { continue }
                questions.append(SessionQuestion(
                    word: word,
                    direction: direction,
                    format: .multipleChoice,
                    index: questions.count,
                    choices: choices
                ))
            }
            return questions
        }
    }

    private struct MultipleChoiceCandidate {
        let wordID: UUID
        let label: String
        let deduplicationKey: String
        let matchedMeaningID: UUID?
    }

    private func multipleChoiceOptions(
        for target: MultipleChoiceCandidate,
        candidates: [MultipleChoiceCandidate],
        sessionID: UUID,
        questionIndex: Int
    ) -> [MultipleChoiceOption]? {
        let correct = MultipleChoiceOption(
            id: UUID(),
            label: target.label,
            isCorrect: true,
            matchedMeaningID: target.matchedMeaningID
        )
        let distractors = multipleChoiceDistractors(
            for: target,
            candidates: candidates,
            seed: "\(sessionID.uuidString)-\(questionIndex)-\(target.wordID.uuidString)-distractors"
        )
        let options = [correct] + distractors
        guard options.count == 4 else { return nil }
        return stableShuffle(
            options,
            seed: "\(sessionID.uuidString)-\(questionIndex)-\(target.wordID.uuidString)"
        )
    }

    private func multipleChoiceDistractors(
        for target: MultipleChoiceCandidate,
        candidates: [MultipleChoiceCandidate],
        seed: String
    ) -> [MultipleChoiceOption] {
        var selected: [(rank: UInt64, tieBreaker: String, key: String, option: MultipleChoiceOption)] = []
        var selectedKeys = Set([target.deduplicationKey])
        for candidate in candidates where candidate.wordID != target.wordID {
            guard !selectedKeys.contains(candidate.deduplicationKey) else { continue }
            let tieBreaker = candidate.wordID.uuidString
            let entry = (
                rank: stableHash("\(seed)-\(tieBreaker)"),
                tieBreaker: tieBreaker,
                key: candidate.deduplicationKey,
                option: MultipleChoiceOption(
                    id: UUID(),
                    label: candidate.label,
                    isCorrect: false,
                    matchedMeaningID: nil
                )
            )
            selected.append(entry)
            selectedKeys.insert(candidate.deduplicationKey)
            selected.sort {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                return $0.tieBreaker < $1.tieBreaker
            }
            if selected.count > 3 {
                selectedKeys.remove(selected.removeLast().key)
            }
        }
        return selected.map(\.option)
    }

    private func multipleChoiceCandidate(
        for word: WordRecord,
        direction: PracticeDirection
    ) -> MultipleChoiceCandidate? {
        switch direction {
        case .enToKo:
            let meanings = word.activeMeanings.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !meanings.isEmpty else { return nil }
            let matchedMeaningID = meanings.first(where: \.isTrackableCoreMeaning)?.id
                ?? meanings.first(where: \.isCore)?.id
                ?? meanings.first?.id
            let label = meanings.map(\.text).joined(separator: ", ")
            return MultipleChoiceCandidate(
                wordID: word.id,
                label: label,
                deduplicationKey: TextNormalizer.normalizeKorean(label),
                matchedMeaningID: matchedMeaningID
            )
        case .koToEn:
            let term = word.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            return MultipleChoiceCandidate(
                wordID: word.id,
                label: term,
                deduplicationKey: TextNormalizer.normalizeEnglish(term),
                matchedMeaningID: nil
            )
        }
    }

    private func stableShuffle<T>(_ values: [T], seed: String) -> [T] {
        values.enumerated().sorted { lhs, rhs in
            let left = stableHash("\(seed)-\(lhs.offset)")
            let right = stableHash("\(seed)-\(rhs.offset)")
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func invalidateSessionCandidateCache() {
        invalidateWordCandidateCaches()
        dailySetCache = nil
        dailySetMembershipIndexCache = nil
    }

    private func invalidateWordCandidateCaches() {
        activeWordCache = nil
        activeWordByIDCache = nil
        consolidatingWordCache = nil
    }

    private func dailySetMembershipIndex(for sets: [DailySetRecord]) -> DailySetMembershipIndex {
        if let dailySetMembershipIndexCache { return dailySetMembershipIndexCache }
        var linkedWordIDs = Set<UUID>()
        var wordIDsBySetID: [UUID: [UUID]] = [:]
        wordIDsBySetID.reserveCapacity(sets.count)
        for set in sets {
            let orderedWordIDs = set.allItems
                .filter { $0.deletedAt == nil }
                .sorted { $0.orderIndex < $1.orderIndex }
                .map(\.wordID)
            var seenWordIDs = Set<UUID>()
            let wordIDs = orderedWordIDs.filter { seenWordIDs.insert($0).inserted }
            wordIDsBySetID[set.id] = wordIDs
            linkedWordIDs.formUnion(wordIDs)
        }
        let index = DailySetMembershipIndex(
            linkedWordIDs: linkedWordIDs,
            wordIDsBySetID: wordIDsBySetID
        )
        dailySetMembershipIndexCache = index
        return index
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
        let ranked = candidates.map { word in
            let presentation = exposure[word.id] ?? PresentationStats()
            return FairCandidate(
                word: word,
                presentationCount: presentation.count,
                lastPresentedAt: presentation.lastPresentedAt,
                randomRank: Int.random(in: Int.min...Int.max)
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.presentationCount != rhs.presentationCount {
                return lhs.presentationCount < rhs.presentationCount
            }
            if lhs.lastPresentedAt != rhs.lastPresentedAt {
                return (lhs.lastPresentedAt ?? .distantPast) < (rhs.lastPresentedAt ?? .distantPast)
            }
            return lhs.randomRank < rhs.randomRank
        }.map(\.word)
    }

    private func orderedMasteryMaintenanceCandidates(
        _ words: [WordRecord],
        policy: MasteryMaintenancePolicy,
        asOf date: Date,
        exposure: [UUID: PresentationStats],
        alreadyPresentedTodayIDs: Set<UUID>,
        preferUnseenToday: Bool
    ) -> [WordRecord] {
        let candidates = words.compactMap { word -> MasteryMaintenanceCandidate? in
            let successDayCount = eligibleMasterySuccessDays(for: word).count
            let lastTestedAt = word.reviewState?.lastTestedAt ?? word.updatedAt
            guard policy.needsRevalidation(
                lastTestedAt: lastTestedAt,
                verifiedSuccessDayCount: successDayCount,
                asOf: date
            ), let dueAt = policy.nextRevalidationDate(
                lastTestedAt: lastTestedAt,
                verifiedSuccessDayCount: successDayCount
            ) else { return nil }
            return MasteryMaintenanceCandidate(
                word: word,
                dueAt: dueAt,
                wasPresentedToday: alreadyPresentedTodayIDs.contains(word.id),
                presentationCount: exposure[word.id]?.count ?? 0,
                lastPresentedAt: exposure[word.id]?.lastPresentedAt,
                randomRank: Int.random(in: Int.min...Int.max)
            )
        }
        return candidates.sorted { lhs, rhs in
            if preferUnseenToday, lhs.wasPresentedToday != rhs.wasPresentedToday {
                return !lhs.wasPresentedToday
            }
            if lhs.dueAt != rhs.dueAt { return lhs.dueAt < rhs.dueAt }
            if lhs.presentationCount != rhs.presentationCount {
                return lhs.presentationCount < rhs.presentationCount
            }
            if lhs.lastPresentedAt != rhs.lastPresentedAt {
                return (lhs.lastPresentedAt ?? .distantPast) < (rhs.lastPresentedAt ?? .distantPast)
            }
            return lhs.randomRank < rhs.randomRank
        }.map(\.word)
    }

    private func fairOrderPreferUnseenToday(
        _ candidates: [WordRecord],
        exposure: [UUID: PresentationStats],
        alreadyPresentedTodayIDs: Set<UUID>
    ) -> [WordRecord] {
        let unseenToday = candidates.filter { !alreadyPresentedTodayIDs.contains($0.id) }
        let seenToday = candidates.filter { alreadyPresentedTodayIDs.contains($0.id) }
        return fairOrder(unseenToday, exposure: exposure) + fairOrder(seenToday, exposure: exposure)
    }

    private func reviewOrder(_ candidates: [WordRecord], exposure: [UUID: PresentationStats]) -> [WordRecord] {
        let ranked = candidates.map { word in
            let state = word.reviewState
            let presentation = exposure[word.id] ?? PresentationStats()
            return ReviewCandidate(
                word: word,
                activePriority: state?.activePriority ?? 0,
                failureCheck: state?.failureCheck ?? 0,
                latestWrongAt: state?.latestWrongAt,
                presentationCount: presentation.count,
                lastPresentedAt: presentation.lastPresentedAt,
                randomRank: Int.random(in: Int.min...Int.max)
            )
        }
        return ranked.sorted { lhs, rhs in
            if lhs.activePriority != rhs.activePriority {
                return lhs.activePriority > rhs.activePriority
            }
            if lhs.failureCheck != rhs.failureCheck {
                return lhs.failureCheck > rhs.failureCheck
            }
            if lhs.presentationCount != rhs.presentationCount {
                return lhs.presentationCount < rhs.presentationCount
            }
            if lhs.lastPresentedAt != rhs.lastPresentedAt {
                return (lhs.lastPresentedAt ?? .distantPast) < (rhs.lastPresentedAt ?? .distantPast)
            }
            if lhs.latestWrongAt != rhs.latestWrongAt {
                return (lhs.latestWrongAt ?? .distantPast) > (rhs.latestWrongAt ?? .distantPast)
            }
            return lhs.randomRank < rhs.randomRank
        }.map(\.word)
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

    private func scrubAndTombstoneWord(_ word: WordRecord, at now: Date = .now) throws {
        try scrubAndTombstoneWords([word], at: now)
    }

    private func scrubAndTombstoneWords(_ words: [WordRecord], at now: Date) throws {
        let uniqueWords = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wordIDs = Set(uniqueWords.keys)
        guard !wordIDs.isEmpty else { return }

        for item in try context.fetch(FetchDescriptor<DailySetItemRecord>())
            where wordIDs.contains(item.wordID) && item.deletedAt == nil {
            tombstone(item, at: now)
        }
        for session in try context.fetch(FetchDescriptor<TestSessionRecord>())
            where !wordIDs.isDisjoint(with: session.wordIDs) {
            session.wordIDs.removeAll(where: wordIDs.contains)
            session.updatedAt = max(session.updatedAt, now)
        }
        for memoryAid in try context.fetch(FetchDescriptor<MemoryAidCacheRecord>())
            where wordIDs.contains(memoryAid.wordID) && memoryAid.deletedAt == nil {
            memoryAid.scrubDeletedContent()
            tombstone(memoryAid, at: now)
        }

        for word in uniqueWords.values {
            for attempt in word.allAttempts where attempt.deletedAt == nil {
                attempt.scrubDeletedContent()
                tombstone(attempt, at: now)
            }
            if let reviewState = word.reviewState, reviewState.deletedAt == nil {
                reviewState.scrubDeletedContent()
                tombstone(reviewState, at: now)
            }
            for meaning in word.activeMeanings {
                meaning.scrubDeletedContent()
                tombstone(meaning, at: now)
            }
            word.scrubDeletedContent()
            tombstone(word, at: now)
        }
    }

    private func scrubPreviouslyDeletedIdentifyingRecords(at now: Date) throws -> Bool {
        var changed = false

        func scrub<T: PersistentModel & VocabSoftDeletableRecord>(_ type: T.Type) throws {
            for record in try context.fetch(FetchDescriptor<T>()) where record.deletedAt != nil {
                guard record.scrubDeletedContent() else { continue }
                record.updatedAt = max(record.updatedAt, now)
                changed = true
            }
        }

        try scrub(WordRecord.self)
        try scrub(MeaningRecord.self)
        try scrub(AttemptRecord.self)
        try scrub(ReviewStateRecord.self)
        try scrub(MemoryAidCacheRecord.self)
        return changed
    }

    private func requireVocabularyAuthoring() throws {
        guard authoringCapability == .macAuthor else {
            throw LearningError.vocabularyAuthoringRequiresMac
        }
    }

    private func requireLearningFactWriting() throws {
        guard learningFactAuthority == .allowed else {
            context.rollback()
            throw LearningError.mutationsBlockedForIntegrity
        }
        guard syncMode == .localOnly || VocabMutationAuthorityRuntime.permitsMutation(
            container: context.container,
            context: context
        ) else {
            context.rollback()
            throw LearningError.mutationsBlockedForIntegrity
        }
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

    private func tombstone(_ attempt: AttemptRecord, at date: Date = .now) {
        attempt.deletedAt = date
        attempt.updatedAt = date
        context.insert(RecordTombstone(recordID: attempt.id, recordType: "AttemptRecord", deletedAt: date))
    }

    private func tombstone(_ reviewState: ReviewStateRecord, at date: Date = .now) {
        reviewState.deletedAt = date
        reviewState.updatedAt = date
        context.insert(RecordTombstone(recordID: reviewState.id, recordType: "ReviewStateRecord", deletedAt: date))
    }

    private func tombstone(_ memoryAid: MemoryAidCacheRecord, at date: Date = .now) {
        memoryAid.deletedAt = date
        memoryAid.updatedAt = date
        context.insert(RecordTombstone(recordID: memoryAid.id, recordType: "MemoryAidCacheRecord", deletedAt: date))
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

enum LearningError: LocalizedError {
    case dailySetCountOutOfRange
    case dailySetExceeds100(remaining: Int)
    case dailySetAlreadyExists
    case meaningRequired
    case termRequired
    case duplicateHeadword
    case onlyMasteredCanBeDeleted
    case setRequired
    case noSessionCandidates
    case vocabularyAuthoringRequiresMac
    case mutationsBlockedForIntegrity

    var errorDescription: String? {
        switch self {
        case .dailySetCountOutOfRange: "한 번에 1개 이상 100개 이하의 단어를 입력하세요."
        case .dailySetExceeds100(let remaining): "오늘 세트에는 \(remaining)개를 더 저장할 수 있습니다. 입력 개수를 줄여주세요."
        case .dailySetAlreadyExists: "오늘의 완료 세트가 이미 저장되어 있습니다."
        case .meaningRequired: "각 표제어에 뜻을 하나 이상 입력해야 합니다."
        case .termRequired: "영단어 표제어를 입력해야 합니다."
        case .duplicateHeadword: "이미 존재하는 표제어입니다. 기존 단어를 직접 수정하세요."
        case .onlyMasteredCanBeDeleted: "Mastered 단어만 삭제할 수 있습니다."
        case .setRequired: "테스트할 입력 세트를 선택하세요."
        case .noSessionCandidates: "선택한 범위에 출제 가능한 단어가 없습니다."
        case .vocabularyAuthoringRequiresMac: "단어장의 추가, 수정, 삭제는 Mac Vocab에서만 할 수 있습니다."
        case .mutationsBlockedForIntegrity: "동기화 데이터 무결성 확인이 필요하여 변경 작업을 중단했습니다. 조회는 계속할 수 있습니다."
        }
    }
}
