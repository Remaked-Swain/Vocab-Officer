import Foundation
import CryptoKit
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

enum VocabAuthoringCapability: Sendable {
    case macAuthor
    case readOnlyVocabulary

    static var currentPlatform: VocabAuthoringCapability {
#if os(macOS)
        .macAuthor
#else
        .readOnlyVocabulary
#endif
    }
}

enum VocabMutationAuthority: Equatable, Sendable {
    case allowed
    case integrityBlocked

    static var runtimeCurrent: VocabMutationAuthority {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return .allowed
        }
        return VocabMutationAuthorityRuntime.current
    }
}

enum VocabMutationAuthorityRuntime {
    private static let store = VocabMutationLeaseStore()
    private static let lock = NSLock()
    private static var validationEpoch = UUID()
    private static var authorizedEpoch: UUID?

    static var current: VocabMutationAuthority {
        let epochIsAuthorized = lock.withLock { authorizedEpoch == validationEpoch }
        return epochIsAuthorized && store.load() != nil ? .allowed : .integrityBlocked
    }

    static func set(_ authority: VocabMutationAuthority) {
        if authority == .integrityBlocked { store.invalidate() }
    }

    static func invalidate() {
        lock.withLock {
            validationEpoch = UUID()
            authorizedEpoch = nil
        }
        store.invalidate()
    }

    @discardableResult
    static func beginValidationEpoch() -> UUID {
        invalidate()
        return currentValidationEpoch
    }

    static func noteForegroundReentry() {
        // Foreground reentry is informational; real store-change events still rotate the epoch.
        _ = currentValidationEpoch
    }

    static var currentValidationEpoch: UUID {
        lock.withLock { validationEpoch }
    }

    static func prepareForFullAudit() -> UUID {
        let epoch = lock.withLock { () -> UUID in
            authorizedEpoch = nil
            return validationEpoch
        }
        store.invalidate()
        return epoch
    }

    static func authorize(
        container: ModelContainer,
        context: ModelContext,
        receipt: VocabFullAuditReceipt,
        validationEpoch expectedEpoch: UUID
    ) throws {
        guard lock.withLock({ validationEpoch == expectedEpoch }) else {
            store.invalidate()
            return
        }
        guard let metadata = try VocabMutationLeaseStore.activeMetadata(context: context) else {
            store.invalidate()
            return
        }
        store.save(VocabMutationLease(
            formatVersion: VocabMutationLease.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: metadata.schemaVersion,
            metadataFingerprint: metadata.contentFingerprint,
            canonicalFingerprint: receipt.canonicalFingerprint,
            issuedAt: receipt.auditedAt
        ))
        lock.withLock {
            if validationEpoch == expectedEpoch { authorizedEpoch = expectedEpoch }
        }
    }

    static func permitsMutation(container: ModelContainer, context: ModelContext) -> Bool {
        do {
            guard lock.withLock({ authorizedEpoch == validationEpoch }),
                  let lease = store.load(),
                  lease.formatVersion == VocabMutationLease.currentFormatVersion,
                  lease.storeIdentity == VocabFullAuditReceipt.storeIdentity(for: container),
                  let metadata = try VocabMutationLeaseStore.activeMetadata(context: context),
                  metadata.bootstrapUUID == lease.bootstrapUUID,
                  metadata.schemaVersion == lease.schemaVersion,
                  metadata.schemaVersion == VocabCloudReconciler.metadataSchemaVersion,
                  !metadata.contentFingerprint.isEmpty,
                  metadata.lastReconciledAt != nil else {
                store.invalidate()
                return false
            }
            return true
        } catch {
            store.invalidate()
            return false
        }
    }
}

struct VocabMutationLease: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let storeIdentity: String
    let bootstrapUUID: UUID
    let schemaVersion: Int
    let metadataFingerprint: String
    let canonicalFingerprint: String
    let issuedAt: Date
}

struct VocabMutationLeaseStore {
    private static let key = "vocabSyncRuntime.mutationLease.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = Self.defaultDefaults()) {
        self.defaults = defaults
    }

    private static func defaultDefaults() -> UserDefaults {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            return .standard
        }
        let suiteName = "VocabMutationLeaseTests-\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    func load() -> VocabMutationLease? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(VocabMutationLease.self, from: data)
    }

    func save(_ lease: VocabMutationLease) {
        guard let data = try? JSONEncoder().encode(lease) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func invalidate() {
        defaults.removeObject(forKey: Self.key)
    }

    static func activeMetadata(context: ModelContext) throws -> CloudBootstrapRecord? {
        var descriptor = FetchDescriptor<CloudBootstrapRecord>(predicate: #Predicate {
            $0.key == "primary" && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

enum VocabMutationAuthorityPolicy {
    static func shouldInvalidateForStoreEvent(reason: VocabHydrationRefreshReason) -> Bool {
        switch reason {
        case .successfulImport:
            // CloudKit imports may apply external writes over the local store, so keep this
            // fail-closed until reconciliation refreshes the authority.
            return true
        case .initial, .foreground, .manual, .remoteStoreChange, .pollingTick(_):
            return false
        }
    }

    static func authority(for state: VocabHydrationState) -> VocabMutationAuthority? {
        switch state {
        case .localOnly, .ready:
            .allowed
        case .awaitingBootstrapMetadata, .hydrating, .reconciling:
            .integrityBlocked
        case .failed:
            .integrityBlocked
        }
    }

    static func authority(for error: Error) -> VocabMutationAuthority? {
        error is VocabCloudReconciliationError ? .integrityBlocked : nil
    }
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
    private var dailySetCache: [DailySetRecord]?

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
        try context.save()
        NotificationCenter.default.post(name: .vocabLearningStoreDidChange, object: nil)
    }

    func saveDailySet(_ drafts: [WordDraft], date: Date = .now) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
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
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
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

    func generateSession(mode: SessionMode, direction: PracticeDirection, setID: UUID? = nil, date: Date = .now, format: QuestionFormat = .typed) throws -> (TestSessionRecord, [SessionQuestion]) {
        try requireLearningFactWriting()
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
        let sessionID = UUID()
        let questions = makeQuestions(
            selected: selected,
            allWords: words,
            direction: direction,
            format: format,
            sessionID: sessionID
        )
        guard !questions.isEmpty else { throw LearningError.noSessionCandidates }
        selected = questions.map(\.word)
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
        try requireLearningFactWriting()
        for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
            compactAttempts(for: word, now: now)
        }
        compactSessionHistory(now: now)
        try saveAndNotifyChange()
    }

    func deleteMastered(_ word: WordRecord) throws {
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
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
        try requireLearningFactWriting()
        try requireVocabularyAuthoring()
        var deletedIDs = Set<UUID>()
        for word in words where deletedIDs.insert(word.id).inserted {
            try deleteWordRecord(word)
        }
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
        let calculation = expectedReviewState(for: word, attempts: sourceAttempts)
        guard calculation.conflicts.isEmpty, let expected = calculation.expected else {
            return calculation.conflicts
        }
        _ = applyExpectedReviewState(expected, to: word)
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
        let coreMeaningIDs = activeMeanings.filter(\.isCore).map(\.id)
        var expected = RecomputedWordReviewState(
            statusRaw: word.deletedAt == nil ? "active" : word.statusRaw,
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
            let format = QuestionFormat(rawValue: attempt.questionFormatRaw) ?? .typed
            let contributesToMastery = format == .typed
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
                if direction == .enToKo {
                    expected.enToKoStreak += 1
                    if contributesToMastery,
                       let meaningID = attempt.matchedMeaningID,
                       trackableCoreMeaningIDs.contains(meaningID),
                       expected.meaningSuccessDays[meaningID]?.contains(day) == false {
                        expected.meaningSuccessDays[meaningID, default: []].append(day)
                    }
                } else {
                    expected.koToEnStreak += 1
                    if contributesToMastery, !expected.koToEnSuccessDays.contains(day) {
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

            let coreIsTrackable = !coreMeaningIDs.isEmpty
                && coreMeaningIDs.allSatisfy(trackableCoreMeaningIDs.contains)
            let coreSatisfied = coreIsTrackable && coreMeaningIDs.allSatisfy {
                Set(expected.meaningSuccessDays[$0] ?? []).count >= 3
            }
            let koToEnSatisfied = Set(expected.koToEnSuccessDays).count >= 3
            let noRecentFailure = expected.latestWrongAt.map {
                $0 < SeoulCalendar.daysAgo(14, from: attempt.answeredAt)
            } ?? true
            if coreSatisfied && koToEnSatisfied && noRecentFailure {
                expected.statusRaw = "mastered"
            }
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
            for word in selected {
                guard let choices = multipleChoiceOptions(
                    for: word,
                    candidates: selected + allWords,
                    direction: direction,
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

    private func multipleChoiceOptions(
        for target: WordRecord,
        candidates: [WordRecord],
        direction: PracticeDirection,
        sessionID: UUID,
        questionIndex: Int
    ) -> [MultipleChoiceOption]? {
        guard let correct = multipleChoiceOption(for: target, direction: direction, isCorrect: true) else { return nil }
        let correctKey = multipleChoiceDeduplicationKey(correct.label, direction: direction)
        var seen = Set([correctKey])
        var options = [correct]
        let distractorCandidates = stableShuffleWords(
            uniqueWords(candidates.filter { $0.id != target.id }),
            seed: "\(sessionID.uuidString)-\(questionIndex)-\(target.id.uuidString)-\(direction.rawValue)-distractors"
        )
        for candidate in distractorCandidates {
            guard let option = multipleChoiceOption(for: candidate, direction: direction, isCorrect: false) else { continue }
            let key = multipleChoiceDeduplicationKey(option.label, direction: direction)
            guard seen.insert(key).inserted else { continue }
            options.append(option)
            if options.count == 4 { break }
        }
        guard options.count == 4 else { return nil }
        return stableShuffle(
            options,
            seed: "\(sessionID.uuidString)-\(questionIndex)-\(target.id.uuidString)-\(direction.rawValue)"
        )
    }

    private func multipleChoiceOption(
        for word: WordRecord,
        direction: PracticeDirection,
        isCorrect: Bool
    ) -> MultipleChoiceOption? {
        switch direction {
        case .enToKo:
            let meanings = word.activeMeanings.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !meanings.isEmpty else { return nil }
            let matchedMeaningID = meanings.first(where: \.isTrackableCoreMeaning)?.id
                ?? meanings.first(where: \.isCore)?.id
                ?? meanings.first?.id
            return MultipleChoiceOption(
                id: UUID(),
                label: meanings.map(\.text).joined(separator: ", "),
                isCorrect: isCorrect,
                matchedMeaningID: isCorrect ? matchedMeaningID : nil
            )
        case .koToEn:
            let term = word.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return nil }
            return MultipleChoiceOption(id: UUID(), label: term, isCorrect: isCorrect, matchedMeaningID: nil)
        }
    }

    private func multipleChoiceDeduplicationKey(_ label: String, direction: PracticeDirection) -> String {
        switch direction {
        case .enToKo: TextNormalizer.normalizeKorean(label)
        case .koToEn: TextNormalizer.normalizeEnglish(label)
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

    private func stableShuffleWords(_ values: [WordRecord], seed: String) -> [WordRecord] {
        values.sorted { lhs, rhs in
            let left = stableHash("\(seed)-\(lhs.id.uuidString)")
            let right = stableHash("\(seed)-\(rhs.id.uuidString)")
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
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

enum VocabHydrationState: String, Equatable, Sendable {
    case localOnly
    case awaitingBootstrapMetadata
    case hydrating
    case reconciling
    case ready
    case failed
}

enum VocabSyncHealth: Equatable, Sendable {
    case healthy
    case incompleteCanonicalState
    case integrityInvalid
}

struct VocabEntityCounts: Codable, Equatable, Sendable {
    var words: Int
    var meanings: Int
    var dailySets: Int
    var dailySetItems: Int
    var testSessions: Int
    var attempts: Int
    var anonymousAggregates: Int
    var memoryAidCaches: Int
    var tombstones: Int

    static let zero = VocabEntityCounts(
        words: 0,
        meanings: 0,
        dailySets: 0,
        dailySetItems: 0,
        testSessions: 0,
        attempts: 0,
        anonymousAggregates: 0,
        memoryAidCaches: 0,
        tombstones: 0
    )

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

struct VocabHydrationStatus: Equatable, Sendable {
    let state: VocabHydrationState
    let counts: VocabEntityCounts
    let expectedBootstrapUUID: UUID?
    let message: String?

    var permitsUserDataMutation: Bool {
        health == .healthy
    }

    var health: VocabSyncHealth {
        switch state {
        case .localOnly, .ready:
            .healthy
        case .awaitingBootstrapMetadata, .hydrating, .reconciling:
            .incompleteCanonicalState
        case .failed:
            .integrityInvalid
        }
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

struct VocabImportedChangeIndex: Codable, Equatable {
    static let currentFormatVersion = 2

    struct Entry: Codable, Equatable {
        var signature: String
        var wordID: UUID?
    }

    var formatVersion: Int
    var canonicalAttemptSignatureVersion: Int
    var attempts: [String: Entry]
    var words: [String: Entry]
    var meanings: [String: Entry]
    var tombstones: [String: Entry]
}

struct VocabImportedChangeSet {
    var affectedWordIDs: Set<UUID>
    var changedTombstoneIDs: Set<UUID>
    var nextIndex: VocabImportedChangeIndex
    var requiresFullAudit: Bool
}

enum VocabImportedChangeSource: Equatable, Sendable {
    case trustedLocalIdentifiers
    case cloudImportWithoutIdentifiers
}

struct VocabChangedRecordID: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case attempt
        case word
        case meaning
        case tombstone
    }

    let kind: Kind
    let id: UUID

    init?(_ model: any PersistentModel) {
        switch model {
        case let record as AttemptRecord: kind = .attempt; id = record.id
        case let record as WordRecord: kind = .word; id = record.id
        case let record as MeaningRecord: kind = .meaning; id = record.id
        case let record as RecordTombstone: kind = .tombstone; id = record.id
        default: return nil
        }
    }

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

struct VocabImportedIdentifierBatch: Codable, Equatable, Sendable {
    var records: Set<VocabChangedRecordID>
    var requiresFullAudit: Bool

    static let empty = VocabImportedIdentifierBatch(records: [], requiresFullAudit: false)
}

actor VocabImportedIdentifierBuffer {
    static let shared = VocabImportedIdentifierBuffer()

    private let url: URL?
    private var pending: VocabImportedIdentifierBatch

    init(url: URL? = nil) {
        let resolvedURL = url ?? (try? Self.defaultURL())
        self.url = resolvedURL
        if let resolvedURL,
           let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? JSONDecoder().decode(VocabImportedIdentifierBatch.self, from: data) {
            pending = decoded
        } else {
            pending = .empty
        }
    }

    func capture(_ records: Set<VocabChangedRecordID>, requiresFullAudit: Bool = false) {
        guard !records.isEmpty || requiresFullAudit else { return }
        pending.records.formUnion(records)
        pending.requiresFullAudit = pending.requiresFullAudit || requiresFullAudit
        persist()
    }

    func snapshot() -> VocabImportedIdentifierBatch { pending }

    func acknowledge(_ batch: VocabImportedIdentifierBatch) {
        pending.records.subtract(batch.records)
        if batch.requiresFullAudit { pending.requiresFullAudit = false }
        persist()
    }

    private func persist() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if pending == .empty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(pending) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime/imported-identifiers-v1.json")
    }
}

enum VocabModelContextChangeEvent {
    static func changes(
        from notification: Notification,
        context: ModelContext
    ) -> VocabImportedIdentifierBatch {
        func identifiers(for key: ModelContext.NotificationKey) -> Set<PersistentIdentifier> {
            if let values = notification.userInfo?[key.rawValue] as? Set<PersistentIdentifier> {
                return values
            } else if let values = notification.userInfo?[key] as? Set<PersistentIdentifier> {
                return values
            }
            return []
        }
        let resolvableIdentifiers = identifiers(for: .insertedIdentifiers)
            .union(identifiers(for: .updatedIdentifiers))
        let deletedIdentifiers = identifiers(for: .deletedIdentifiers)
        var records = Set<VocabChangedRecordID>()
        var unresolved = !deletedIdentifiers.isEmpty
        for identifier in resolvableIdentifiers {
            let model = context.model(for: identifier)
            guard let record = VocabChangedRecordID(model) else {
                unresolved = true
                continue
            }
            records.insert(record)
        }
        return VocabImportedIdentifierBatch(records: records, requiresFullAudit: unresolved)
    }
}

enum VocabImportedChangeIndexStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("import-index-v2.json")
    }

    static func load(from url: URL) throws -> VocabImportedChangeIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(VocabImportedChangeIndex.self, from: Data(contentsOf: url))
    }

    static func save(_ index: VocabImportedChangeIndex, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }
}

enum VocabImportedChangeDiscovery {
    static func discover(
        context: ModelContext,
        previous: VocabImportedChangeIndex?,
        changedRecords: Set<VocabChangedRecordID>
    ) throws -> VocabImportedChangeSet {
        guard let previous,
              previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
              previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion else {
            return try discover(context: context, previous: nil)
        }

        var next = previous
        var affectedWordIDs = Set<UUID>()
        var changedTombstoneIDs = Set<UUID>()
        var hasUnresolvedIdentifier = false
        for changedRecord in changedRecords {
            if changedRecord.kind == .attempt {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = attemptEntry(record)
                if previous.attempts[key] != entry {
                    if let old = previous.attempts[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    next.attempts[key] = entry
                }
            } else if changedRecord.kind == .word {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = wordEntry(record)
                if previous.words[key] != entry {
                    affectedWordIDs.insert(record.id)
                    next.words[key] = entry
                }
            } else if changedRecord.kind == .meaning {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = meaningEntry(record)
                if previous.meanings[key] != entry {
                    if let old = previous.meanings[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    next.meanings[key] = entry
                }
            } else if changedRecord.kind == .tombstone {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<RecordTombstone>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = try tombstoneEntry(record, context: context)
                if previous.tombstones[key] != entry {
                    if let old = previous.tombstones[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    changedTombstoneIDs.insert(record.id)
                    next.tombstones[key] = entry
                }
            }
        }
        return VocabImportedChangeSet(
            affectedWordIDs: affectedWordIDs,
            changedTombstoneIDs: changedTombstoneIDs,
            nextIndex: next,
            requiresFullAudit: hasUnresolvedIdentifier
        )
    }

    static func discover(
        context: ModelContext,
        previous: VocabImportedChangeIndex?
    ) throws -> VocabImportedChangeSet {
        let words = try context.fetch(FetchDescriptor<WordRecord>())
        let meanings = try context.fetch(FetchDescriptor<MeaningRecord>())
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        let tombstones = try context.fetch(FetchDescriptor<RecordTombstone>())

        let next = VocabImportedChangeIndex(
            formatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalAttemptSignatureVersion: VocabAttemptCanonicalPayload.signatureVersion,
            attempts: Dictionary(uniqueKeysWithValues: attempts.map { ($0.id.uuidString, attemptEntry($0)) }),
            words: Dictionary(uniqueKeysWithValues: words.map { ($0.id.uuidString, wordEntry($0)) }),
            meanings: Dictionary(uniqueKeysWithValues: meanings.map { ($0.id.uuidString, meaningEntry($0)) }),
            tombstones: Dictionary(uniqueKeysWithValues: tombstones.map {
                ($0.id.uuidString, tombstoneEntry($0, words: words, meanings: meanings))
            })
        )

        guard let previous,
              previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
              previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion else {
            return VocabImportedChangeSet(
                affectedWordIDs: Set(words.map(\.id)),
                changedTombstoneIDs: Set(tombstones.map(\.id)),
                nextIndex: next,
                requiresFullAudit: true
            )
        }

        var affected = changedWordIDs(previous: previous.attempts, next: next.attempts)
        affected.formUnion(changedWordIDs(previous: previous.words, next: next.words))
        affected.formUnion(changedWordIDs(previous: previous.meanings, next: next.meanings))
        affected.formUnion(changedWordIDs(previous: previous.tombstones, next: next.tombstones))
        let changedTombstones = changedKeys(previous: previous.tombstones, next: next.tombstones)
            .compactMap(UUID.init(uuidString:))

        return VocabImportedChangeSet(
            affectedWordIDs: affected,
            changedTombstoneIDs: Set(changedTombstones),
            nextIndex: next,
            requiresFullAudit: false
        )
    }

    private static func changedWordIDs(
        previous: [String: VocabImportedChangeIndex.Entry],
        next: [String: VocabImportedChangeIndex.Entry]
    ) -> Set<UUID> {
        changedKeys(previous: previous, next: next).reduce(into: Set<UUID>()) { result, key in
            if let id = next[key]?.wordID ?? previous[key]?.wordID { result.insert(id) }
        }
    }

    static func attemptEntry(_ record: AttemptRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString
        ] + VocabAttemptCanonicalPayload(record).signatureComponents + [
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.word?.id)
    }

    static func wordEntry(_ record: WordRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.term, record.statusRaw,
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.id)
    }

    static func meaningEntry(_ record: MeaningRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.word?.id.uuidString ?? "", record.text,
            String(record.isCore), record.aliases.sorted().joined(separator: "\u{1f}"),
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.word?.id)
    }

    static func tombstoneEntry(
        _ record: RecordTombstone,
        words: [WordRecord],
        meanings: [MeaningRecord]
    ) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.recordType, record.recordID.uuidString,
            timestamp(record.deletedAt), timestamp(record.updatedAt)
        ]), wordID: tombstoneWordID(record, words: words, meanings: meanings))
    }

    static func tombstoneEntry(
        _ record: RecordTombstone,
        context: ModelContext
    ) throws -> VocabImportedChangeIndex.Entry {
        let wordID: UUID?
        switch record.recordType {
        case "WordRecord":
            wordID = record.recordID
        case "MeaningRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.word?.id
        case "DailySetItemRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<DailySetItemRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.wordID
        default:
            wordID = nil
        }
        return .init(signature: digest([
            record.id.uuidString, record.recordType, record.recordID.uuidString,
            timestamp(record.deletedAt), timestamp(record.updatedAt)
        ]), wordID: wordID)
    }

    private static func changedKeys(
        previous: [String: VocabImportedChangeIndex.Entry],
        next: [String: VocabImportedChangeIndex.Entry]
    ) -> Set<String> {
        Set(previous.keys).union(next.keys).filter { previous[$0] != next[$0] }
    }

    private static func tombstoneWordID(
        _ tombstone: RecordTombstone,
        words: [WordRecord],
        meanings: [MeaningRecord]
    ) -> UUID? {
        switch tombstone.recordType {
        case "WordRecord": tombstone.recordID
        case "MeaningRecord": meanings.first(where: { $0.id == tombstone.recordID })?.word?.id
        default: nil
        }
    }

    private static func timestamp(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"
    }

    private static func digest(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\u{1e}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct VocabFullAuditReceipt: Codable, Equatable {
    static let currentFormatVersion = 1
    static let reconciliationVersion = 2

    var formatVersion: Int
    var storeIdentity: String
    var bootstrapUUID: UUID
    var schemaVersion: Int
    var reconciliationVersion: Int
    var importIndexFormatVersion: Int
    var canonicalFingerprint: String
    var expectedCounts: VocabEntityCounts? = nil
    var requiredIDDigest: String? = nil
    var auditedAt: Date

    func validates(container: ModelContainer, snapshot: VocabSyncSnapshot) throws -> Bool {
        let currentFingerprint = try snapshot.contentFingerprint()
        return formatVersion == Self.currentFormatVersion
            && storeIdentity == Self.storeIdentity(for: container)
            && bootstrapUUID == snapshot.syncMetadata?.bootstrapUUID
            && schemaVersion == VocabCloudReconciler.metadataSchemaVersion
            && reconciliationVersion == Self.reconciliationVersion
            && importIndexFormatVersion == VocabImportedChangeIndex.currentFormatVersion
            && canonicalFingerprint == currentFingerprint
    }

    static func storeIdentity(for container: ModelContainer) -> String {
        container.configurations.map { $0.url.standardizedFileURL.path }.sorted().joined(separator: "|")
    }
}

enum VocabRequiredIDDigest {
    static func make(snapshot: VocabSyncSnapshot) -> String {
        var ids = snapshot.words.map { "w:\($0.id.uuidString)" }
        ids.append(contentsOf: snapshot.words.flatMap { word in word.meanings.map { "m:\($0.id.uuidString)" } })
        ids.append(contentsOf: snapshot.dailySets.map { "s:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.dailySets.flatMap { set in set.items.map { "i:\($0.id.uuidString)" } })
        ids.append(contentsOf: snapshot.testSessions.map { "t:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.attempts.map { "a:\($0.id.uuidString)" })
        ids.append(contentsOf: snapshot.tombstones.map { "d:\($0.id.uuidString)" })
        return SHA256.hash(data: Data(ids.sorted().joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func counts(snapshot: VocabSyncSnapshot) -> VocabEntityCounts {
        VocabEntityCounts(
            words: snapshot.words.count,
            meanings: snapshot.words.reduce(0) { $0 + $1.meanings.count },
            dailySets: snapshot.dailySets.count,
            dailySetItems: snapshot.dailySets.reduce(0) { $0 + $1.items.count },
            testSessions: snapshot.testSessions.count,
            attempts: snapshot.attempts.count,
            anonymousAggregates: snapshot.anonymousAggregates.count,
            memoryAidCaches: snapshot.memoryAidCaches.count,
            tombstones: snapshot.tombstones.count
        )
    }
}

enum VocabFullAuditReceiptStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("full-audit-receipt-v1.json")
    }

    static func load(from url: URL) throws -> VocabFullAuditReceipt? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabFullAuditReceipt.self,
            from: Data(contentsOf: url)
        )
    }

    static func save(_ receipt: VocabFullAuditReceipt, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.vocabSnapshotEncoder.encode(receipt).write(to: url, options: .atomic)
    }

    static func invalidateDefault() {
        guard let url = try? defaultURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

actor VocabSyncWorkBarrier {
    static let shared = VocabSyncWorkBarrier()

    private var revision: UInt64 = 0
    private var activeReconciliations = 0

    func notePotentialStoreChange() {
        revision &+= 1
    }

    func beginReconciliation() -> UInt64 {
        activeReconciliations += 1
        revision &+= 1
        return revision
    }

    func finishReconciliation() {
        activeReconciliations = max(0, activeReconciliations - 1)
        revision &+= 1
    }

    func beginReplicaObservation() -> UInt64? {
        guard activeReconciliations == 0 else { return nil }
        return revision
    }

    func remainsStable(since observedRevision: UInt64) -> Bool {
        activeReconciliations == 0 && revision == observedRevision
    }
}

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
        var attemptsByWordID: [UUID: [AttemptRecord]] = [:]
        attemptsByWordID.reserveCapacity(allAttempts.count)
        for attempt in allAttempts {
            guard let wordID = attempt.word?.id else { continue }
            attemptsByWordID[wordID, default: []].append(attempt)
        }
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
        var didChange = false
        for record in try context.fetch(FetchDescriptor<WordRecord>()) {
            if let date = deletion("WordRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
                didChange = true
            }
        }
        for record in try context.fetch(FetchDescriptor<MeaningRecord>()) {
            if let date = deletion("MeaningRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
                didChange = true
            }
        }
        for record in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            if let date = deletion("DailySetRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
                didChange = true
            }
        }
        for record in try context.fetch(FetchDescriptor<DailySetItemRecord>()) {
            if let date = deletion("DailySetItemRecord", record.id), record.deletedAt == nil || record.deletedAt! < date {
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
                didChange = true
            }
        }

        if syncMode == .cloudKitPrivate {
            let coordinator = LearningCoordinator(context: context, syncMode: syncMode)
            for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
                let calculation = coordinator.expectedReviewState(
                    for: word,
                    attempts: attemptsByWordID[word.id] ?? []
                )
                guard let expected = calculation.expected else { continue }
                if coordinator.applyExpectedReviewState(expected, to: word) {
                    didChange = true
                }
            }
        }
        if syncMode == .cloudKitPrivate {
            let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
                .first { $0.deletedAt == nil && $0.key == "primary" }
            if metadata?.lastReconciledAt == nil {
                metadata?.lastReconciledAt = now
                metadata?.updatedAt = now
                didChange = true
            }
        }
        if didChange || syncMode == .localOnly {
            try context.save()
        } else if context.hasChanges {
            context.rollback()
        }
        return try hydrationStatus(context: context, syncMode: syncMode)
    }

    @discardableResult
    static func reconcileAffected(
        context: ModelContext,
        syncMode: VocabSyncMode,
        wordIDs: Set<UUID>,
        tombstoneIDs: Set<UUID>,
        now: Date = .now
    ) throws -> VocabHydrationStatus {
        guard syncMode == .cloudKitPrivate else {
            return try reconcile(context: context, syncMode: syncMode, now: now)
        }
        guard let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
            .first(where: { $0.deletedAt == nil && $0.key == "primary" }) else {
            throw VocabCloudReconciliationError.hydrationNotReady(.awaitingBootstrapMetadata)
        }
        guard metadata.schemaVersion == metadataSchemaVersion else {
            throw VocabCloudReconciliationError.unsupportedSchemaVersion(metadata.schemaVersion)
        }

        var affectedWordIDs = wordIDs
        var didChange = false
        for tombstoneID in tombstoneIDs {
            let descriptor = FetchDescriptor<RecordTombstone>(predicate: #Predicate { $0.id == tombstoneID })
            guard let tombstone = try context.fetch(descriptor).first else { continue }
            switch tombstone.recordType {
            case "WordRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate { $0.id == recordID })).first
                if let target, target.deletedAt == nil || target.deletedAt! < tombstone.deletedAt {
                    target.deletedAt = tombstone.deletedAt
                    target.updatedAt = max(target.updatedAt, tombstone.deletedAt)
                    affectedWordIDs.insert(target.id)
                    didChange = true
                }
            case "MeaningRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })).first
                if let target, target.deletedAt == nil || target.deletedAt! < tombstone.deletedAt {
                    target.deletedAt = tombstone.deletedAt
                    target.updatedAt = max(target.updatedAt, tombstone.deletedAt)
                    if let wordID = target.word?.id { affectedWordIDs.insert(wordID) }
                    didChange = true
                }
            case "DailySetRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate { $0.id == recordID })).first
                if let target, target.deletedAt == nil || target.deletedAt! < tombstone.deletedAt {
                    target.deletedAt = tombstone.deletedAt
                    target.updatedAt = max(target.updatedAt, tombstone.deletedAt)
                    didChange = true
                }
            case "DailySetItemRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<DailySetItemRecord>(predicate: #Predicate { $0.id == recordID })).first
                if let target, target.deletedAt == nil || target.deletedAt! < tombstone.deletedAt {
                    target.deletedAt = tombstone.deletedAt
                    target.updatedAt = max(target.updatedAt, tombstone.deletedAt)
                    didChange = true
                }
            default:
                continue
            }
        }

        let coordinator = LearningCoordinator(context: context, syncMode: syncMode)
        for wordID in affectedWordIDs {
            let descriptor = FetchDescriptor<WordRecord>(predicate: #Predicate { $0.id == wordID })
            guard let word = try context.fetch(descriptor).first, word.deletedAt == nil else { continue }
            let calculation = coordinator.expectedReviewState(for: word, attempts: word.allAttempts)
            guard calculation.conflicts.isEmpty else {
                throw VocabCloudReconciliationError.attemptReplayConflicts(calculation.conflicts)
            }
            if let expected = calculation.expected,
               coordinator.applyExpectedReviewState(expected, to: word) {
                didChange = true
            }
        }

        if metadata.lastReconciledAt == nil {
            metadata.lastReconciledAt = now
            metadata.updatedAt = now
            didChange = true
        }
        if didChange {
            try context.save()
        } else if context.hasChanges {
            context.rollback()
        }
        return VocabHydrationStatus(
            state: .ready,
            counts: .zero,
            expectedBootstrapUUID: metadata.bootstrapUUID,
            message: nil
        )
    }

}

@ModelActor
actor VocabCloudReconciliationWorker {
    private let createdOnMainThread = Thread.isMainThread
    private let auditBatchSize = 500

    func hydrationStatus(syncMode: VocabSyncMode) throws -> VocabHydrationStatus {
        try VocabCloudReconciler.hydrationStatus(context: modelContext, syncMode: syncMode)
    }

    func reconcile(syncMode: VocabSyncMode, now: Date = .now) throws -> VocabHydrationStatus {
        try VocabCloudReconciler.reconcile(context: modelContext, syncMode: syncMode, now: now)
    }

    func reconcileFullCooperatively(
        syncMode: VocabSyncMode,
        now: Date = .now
    ) async throws -> VocabHydrationStatus {
        let initial = try VocabCloudReconciler.hydrationStatus(context: modelContext, syncMode: syncMode)
        guard initial.state == .localOnly || initial.state == .reconciling || initial.state == .ready else {
            throw VocabCloudReconciliationError.hydrationNotReady(initial.state)
        }

        var attemptsByWordID: [UUID: [AttemptRecord]] = [:]
        var activeAttempts: [AttemptRecord] = []
        try await forEachBatch(AttemptRecord.self) { attempts in
            for attempt in attempts where attempt.deletedAt == nil {
                activeAttempts.append(attempt)
                if let wordID = attempt.word?.id {
                    attemptsByWordID[wordID, default: []].append(attempt)
                }
            }
        }
        if syncMode == .cloudKitPrivate {
            let replayPlan = LearningCoordinator.attemptReplayPlan(activeAttempts)
            guard replayPlan.conflicts.isEmpty else {
                throw VocabCloudReconciliationError.attemptReplayConflicts(replayPlan.conflicts)
            }
        }

        var winningDeletion: [String: Date] = [:]
        try await forEachBatch(RecordTombstone.self) { tombstones in
            for tombstone in tombstones {
                let key = "\(tombstone.recordType):\(tombstone.recordID.uuidString)"
                winningDeletion[key] = max(winningDeletion[key] ?? .distantPast, tombstone.deletedAt)
            }
        }

        try await applyDeletionBatches(WordRecord.self, typeName: "WordRecord", winningDeletion: winningDeletion)
        try await applyDeletionBatches(MeaningRecord.self, typeName: "MeaningRecord", winningDeletion: winningDeletion)
        try await applyDeletionBatches(DailySetRecord.self, typeName: "DailySetRecord", winningDeletion: winningDeletion)
        try await applyDeletionBatches(DailySetItemRecord.self, typeName: "DailySetItemRecord", winningDeletion: winningDeletion)

        if syncMode == .cloudKitPrivate {
            let coordinator = LearningCoordinator(context: modelContext, syncMode: syncMode)
            try await forEachBatch(WordRecord.self) { words in
                var changed = false
                for word in words where word.deletedAt == nil {
                    let calculation = coordinator.expectedReviewState(
                        for: word,
                        attempts: attemptsByWordID[word.id] ?? []
                    )
                    guard let expected = calculation.expected else { continue }
                    changed = coordinator.applyExpectedReviewState(expected, to: word) || changed
                }
                if changed { try modelContext.save() }
            }
            let metadata = try modelContext.fetch(FetchDescriptor<CloudBootstrapRecord>())
                .first { $0.deletedAt == nil && $0.key == "primary" }
            if metadata?.lastReconciledAt == nil {
                metadata?.lastReconciledAt = now
                metadata?.updatedAt = now
                try modelContext.save()
            }
        } else if modelContext.hasChanges {
            try modelContext.save()
        }
        return try VocabCloudReconciler.hydrationStatus(context: modelContext, syncMode: syncMode)
    }

    private func fullImportIndexCooperatively() async throws -> VocabImportedChangeIndex {
        var attempts: [String: VocabImportedChangeIndex.Entry] = [:]
        var words: [String: VocabImportedChangeIndex.Entry] = [:]
        var meanings: [String: VocabImportedChangeIndex.Entry] = [:]
        var tombstones: [String: VocabImportedChangeIndex.Entry] = [:]
        var wordIDs = Set<UUID>()
        var meaningWordIDs: [UUID: UUID] = [:]
        var itemWordIDs: [UUID: UUID] = [:]

        try await forEachBatch(WordRecord.self) { batch in
            for record in batch {
                words[record.id.uuidString] = VocabImportedChangeDiscovery.wordEntry(record)
                wordIDs.insert(record.id)
            }
        }
        try await forEachBatch(MeaningRecord.self) { batch in
            for record in batch {
                meanings[record.id.uuidString] = VocabImportedChangeDiscovery.meaningEntry(record)
                if let wordID = record.word?.id { meaningWordIDs[record.id] = wordID }
            }
        }
        try await forEachBatch(DailySetItemRecord.self) { batch in
            for record in batch { itemWordIDs[record.id] = record.wordID }
        }
        try await forEachBatch(AttemptRecord.self) { batch in
            for record in batch {
                attempts[record.id.uuidString] = VocabImportedChangeDiscovery.attemptEntry(record)
            }
        }
        try await forEachBatch(RecordTombstone.self) { batch in
            for record in batch {
                let wordID: UUID?
                switch record.recordType {
                case "WordRecord": wordID = record.recordID
                case "MeaningRecord": wordID = meaningWordIDs[record.recordID]
                case "DailySetItemRecord": wordID = itemWordIDs[record.recordID]
                default: wordID = nil
                }
                let signature = VocabImportedChangeDiscovery.tombstoneEntry(
                    record,
                    words: [],
                    meanings: []
                ).signature
                tombstones[record.id.uuidString] = .init(signature: signature, wordID: wordID)
            }
        }
        return VocabImportedChangeIndex(
            formatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalAttemptSignatureVersion: VocabAttemptCanonicalPayload.signatureVersion,
            attempts: attempts,
            words: words,
            meanings: meanings,
            tombstones: tombstones
        )
    }

    private func forEachBatch<T: PersistentModel & VocabStableIdentifiedRecord>(
        _ type: T.Type,
        body: ([T]) throws -> Void
    ) async throws {
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<T>()
            descriptor.sortBy = [SortDescriptor(\T.id, order: .forward)]
            descriptor.fetchLimit = auditBatchSize
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { return }
            try body(batch)
            offset += batch.count
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    private func applyDeletionBatches<T: PersistentModel & VocabSoftDeletableRecord>(
        _ type: T.Type,
        typeName: String,
        winningDeletion: [String: Date]
    ) async throws {
        try await forEachBatch(type) { records in
            var changed = false
            for record in records {
                let key = "\(typeName):\(record.id.uuidString)"
                guard let date = winningDeletion[key], record.deletedAt == nil || record.deletedAt! < date else {
                    continue
                }
                record.deletedAt = date
                record.updatedAt = max(record.updatedAt, date)
                changed = true
            }
            if changed { try modelContext.save() }
        }
    }

    func auditAll(
        syncMode: VocabSyncMode,
        now: Date = .now,
        indexURL: URL? = nil,
        auditReceiptURL: URL? = nil
    ) async throws -> VocabHydrationStatus {
        let validationEpoch = syncMode == .cloudKitPrivate
            ? VocabMutationAuthorityRuntime.prepareForFullAudit()
            : nil
        _ = await VocabSyncWorkBarrier.shared.beginReconciliation()
        do {
            let result = try await reconcileFullCooperatively(syncMode: syncMode, now: now)
            if syncMode == .cloudKitPrivate {
                let index = try await fullImportIndexCooperatively()
                try VocabImportedChangeIndexStore.save(
                    index,
                    to: try indexURL ?? VocabImportedChangeIndexStore.defaultURL()
                )
                let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: modelContext, exportedAt: now)
                guard let bootstrapUUID = snapshot.syncMetadata?.bootstrapUUID else {
                    throw VocabCloudReconciliationError.hydrationNotReady(.awaitingBootstrapMetadata)
                }
                let receipt = VocabFullAuditReceipt(
                    formatVersion: VocabFullAuditReceipt.currentFormatVersion,
                    storeIdentity: VocabFullAuditReceipt.storeIdentity(for: modelContainer),
                    bootstrapUUID: bootstrapUUID,
                    schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                    reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
                    importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
                    canonicalFingerprint: try snapshot.contentFingerprint(),
                    expectedCounts: VocabRequiredIDDigest.counts(snapshot: snapshot),
                    requiredIDDigest: VocabRequiredIDDigest.make(snapshot: snapshot),
                    auditedAt: now
                )
                try VocabFullAuditReceiptStore.save(
                    receipt,
                    to: try auditReceiptURL ?? VocabFullAuditReceiptStore.defaultURL()
                )
                try VocabMutationAuthorityRuntime.authorize(
                    container: modelContainer,
                    context: modelContext,
                    receipt: receipt,
                    validationEpoch: validationEpoch!
                )
                await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted(at: now)
            }
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            return result
        } catch {
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            throw error
        }
    }

    func reconcileImportedChanges(
        syncMode: VocabSyncMode,
        now: Date = .now,
        indexURL: URL? = nil,
        auditReceiptURL: URL? = nil,
        identifierBuffer: VocabImportedIdentifierBuffer = .shared,
        source: VocabImportedChangeSource = .cloudImportWithoutIdentifiers
    ) async throws -> VocabHydrationStatus {
        let validationEpoch = syncMode == .cloudKitPrivate
            ? VocabMutationAuthorityRuntime.prepareForFullAudit()
            : nil
        _ = await VocabSyncWorkBarrier.shared.beginReconciliation()
        do {
        guard syncMode == .cloudKitPrivate else {
            let result = try VocabCloudReconciler.reconcile(context: modelContext, syncMode: syncMode, now: now)
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            return result
        }
        let resolvedURL = try indexURL ?? VocabImportedChangeIndexStore.defaultURL()
        let previous = try? VocabImportedChangeIndexStore.load(from: resolvedURL)
        let pendingChanges = await identifierBuffer.snapshot()
        let auditFallback = VocabImportedChangeSet(
            affectedWordIDs: [],
            changedTombstoneIDs: [],
            nextIndex: previous ?? VocabImportedChangeIndex(
                formatVersion: VocabImportedChangeIndex.currentFormatVersion,
                canonicalAttemptSignatureVersion: VocabAttemptCanonicalPayload.signatureVersion,
                attempts: [:],
                words: [:],
                meanings: [:],
                tombstones: [:]
            ),
            requiresFullAudit: true
        )
        let changes: VocabImportedChangeSet
        switch source {
        case .trustedLocalIdentifiers:
            if !pendingChanges.records.isEmpty,
               !pendingChanges.requiresFullAudit,
               let previous,
               previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
               previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion {
                changes = try VocabImportedChangeDiscovery.discover(
                    context: modelContext,
                    previous: previous,
                    changedRecords: pendingChanges.records
                )
            } else {
                changes = auditFallback
            }
        case .cloudImportWithoutIdentifiers:
            changes = auditFallback
        }
        let periodicAuditIsDue = await VocabSyncRuntimeStateStore.shared.shouldRunFullAudit(now: now)
        let needsAudit = source == .cloudImportWithoutIdentifiers
            || pendingChanges.records.isEmpty
            || pendingChanges.requiresFullAudit
            || changes.requiresFullAudit
            || periodicAuditIsDue
        let result: VocabHydrationStatus
        if needsAudit {
            result = try await reconcileFullCooperatively(syncMode: syncMode, now: now)
            let auditedIndex = try await fullImportIndexCooperatively()
            let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: modelContext, exportedAt: now)
            guard let bootstrapUUID = snapshot.syncMetadata?.bootstrapUUID else {
                throw VocabCloudReconciliationError.hydrationNotReady(.awaitingBootstrapMetadata)
            }
            let receipt = VocabFullAuditReceipt(
                formatVersion: VocabFullAuditReceipt.currentFormatVersion,
                storeIdentity: VocabFullAuditReceipt.storeIdentity(for: modelContainer),
                bootstrapUUID: bootstrapUUID,
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
                importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
                canonicalFingerprint: try snapshot.contentFingerprint(),
                expectedCounts: VocabRequiredIDDigest.counts(snapshot: snapshot),
                requiredIDDigest: VocabRequiredIDDigest.make(snapshot: snapshot),
                auditedAt: now
            )
            try VocabFullAuditReceiptStore.save(
                receipt,
                to: try auditReceiptURL ?? VocabFullAuditReceiptStore.defaultURL()
            )
            try VocabMutationAuthorityRuntime.authorize(
                container: modelContainer,
                context: modelContext,
                receipt: receipt,
                validationEpoch: validationEpoch!
            )
            await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted(at: now)
            try VocabImportedChangeIndexStore.save(auditedIndex, to: resolvedURL)
        } else {
            result = try VocabCloudReconciler.reconcileAffected(
                context: modelContext,
                syncMode: syncMode,
                wordIDs: changes.affectedWordIDs,
                tombstoneIDs: changes.changedTombstoneIDs,
                now: now
            )
        }
        if !needsAudit {
            try VocabImportedChangeIndexStore.save(changes.nextIndex, to: resolvedURL)
        }
        await identifierBuffer.acknowledge(pendingChanges)
        await VocabSyncWorkBarrier.shared.finishReconciliation()
        return result
        } catch {
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            throw error
        }
    }

    func wasCreatedOnMainThread() -> Bool {
        createdOnMainThread
    }
}

protocol VocabStableIdentifiedRecord: AnyObject {
    var id: UUID { get }
}

private protocol VocabSoftDeletableRecord: VocabStableIdentifiedRecord {
    var id: UUID { get }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }
}

extension WordRecord: VocabSoftDeletableRecord {}
extension MeaningRecord: VocabSoftDeletableRecord {}
extension DailySetRecord: VocabSoftDeletableRecord {}
extension DailySetItemRecord: VocabSoftDeletableRecord {}
extension AttemptRecord: VocabStableIdentifiedRecord {}
extension RecordTombstone: VocabStableIdentifiedRecord {}
extension TestSessionRecord: VocabStableIdentifiedRecord {}
extension AnonymousAggregateRecord: VocabStableIdentifiedRecord {}
extension MemoryAidCacheRecord: VocabStableIdentifiedRecord {}

enum VocabCloudReconciliationWorkerFactory {
    static func make(modelContainer: ModelContainer) async -> VocabCloudReconciliationWorker {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: VocabCloudReconciliationWorker(modelContainer: modelContainer)
                )
            }
        }
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
    case vocabularyAuthoringRequiresMac
    case mutationsBlockedForIntegrity

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
        case .vocabularyAuthoringRequiresMac: "단어와 학습세트의 추가, 수정, 삭제는 Mac Vocab에서만 할 수 있습니다."
        case .mutationsBlockedForIntegrity: "동기화 데이터 무결성 확인이 필요하여 변경 작업을 중단했습니다. 조회는 계속할 수 있습니다."
        }
    }
}
