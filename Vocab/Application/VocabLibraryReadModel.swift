import Foundation
import SwiftData

/// Display values of one word, copied out of SwiftData so a page can be
/// prepared off the main actor and rendered without faulting relationships.
struct WordSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let term: String
    let normalizedTerm: String
    let meanings: [String]
    let status: VocabularyLearningStatus
    let createdAt: Date
    let activePriority: Int
    let failureCheck: Int
    let lastPresentedAt: Date?

    /// Every active meaning, joined for display. The relationship stores no order.
    var meaningsText: String {
        meanings.joined(separator: ", ")
    }

    var registrationDay: String {
        SeoulCalendar.day(for: createdAt)
    }
}

extension WordSummary {
    init(_ word: WordRecord) {
        let reviewState = word.reviewState
        self.init(
            id: word.id,
            term: word.term,
            normalizedTerm: word.normalizedTerm,
            meanings: word.activeMeanings.map(\.text),
            status: word.learningStatus,
            createdAt: word.createdAt,
            activePriority: reviewState?.activePriority ?? 0,
            failureCheck: reviewState?.failureCheck ?? 0,
            lastPresentedAt: reviewState?.lastPresentedAt
        )
    }
}

/// Display values of one answer record for the history page.
struct AttemptSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let prompt: String
    let directionRaw: String
    let submittedAnswer: String
    let questionFormatRaw: String
    let answeredAt: Date
    let automaticJudgementRaw: String
    let finalJudgementRaw: String

    init(_ attempt: AttemptRecord) {
        id = attempt.id
        prompt = attempt.prompt
        directionRaw = attempt.directionRaw
        submittedAnswer = attempt.submittedAnswer
        questionFormatRaw = attempt.questionFormatRaw
        answeredAt = attempt.answeredAt
        automaticJudgementRaw = attempt.automaticJudgementRaw
        finalJudgementRaw = attempt.finalJudgementRaw
    }
}

/// Words grouped by their first-registration Seoul day, newest day first, with
/// each day's words in registration order. Built once per library change so
/// flipping a card never regroups the library.
struct RegistrationDayGroup: Identifiable, Hashable, Sendable {
    let day: String
    let words: [WordSummary]

    var id: String { day }

    static func groups(from words: [WordSummary]) -> [RegistrationDayGroup] {
        Dictionary(grouping: words, by: \.registrationDay)
            .map { day, words in
                RegistrationDayGroup(day: day, words: words.sorted(by: isRegisteredBefore))
            }
            .sorted { $0.day > $1.day }
    }

    private static func isRegisteredBefore(_ lhs: WordSummary, _ rhs: WordSummary) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.normalizedTerm < rhs.normalizedTerm
    }
}

/// Review lists on both platforms: active, nondeleted words with positive
/// priority, by priority, failure checks, then oldest presentation.
enum ReviewCandidateList {
    static func words(from states: [ReviewStateRecord]) -> [WordSummary] {
        words(from: states.compactMap(\.word))
    }

    static func words(from words: [WordRecord]) -> [WordSummary] {
        words
            .filter { $0.deletedAt == nil }
            .map(WordSummary.init)
            .filter { $0.status == .active && $0.activePriority > 0 }
            .sorted(by: isOrderedBefore)
    }

    static func isOrderedBefore(_ lhs: WordSummary, _ rhs: WordSummary) -> Bool {
        if lhs.activePriority != rhs.activePriority { return lhs.activePriority > rhs.activePriority }
        if lhs.failureCheck != rhs.failureCheck { return lhs.failureCheck > rhs.failureCheck }
        let lhsPresented = lhs.lastPresentedAt ?? .distantPast
        let rhsPresented = rhs.lastPresentedAt ?? .distantPast
        if lhsPresented != rhsPresented { return lhsPresented < rhsPresented }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
    }
}

struct StudyCardsSnapshot: Sendable {
    let groups: [RegistrationDayGroup]
    let wordCount: Int
}

struct AttemptHistoryPage: Sendable {
    let attempts: [AttemptSummary]
    let totalCount: Int
}

/// Prepares page snapshots on a fresh background context. Pages call these
/// instead of `@Query` so a tab switch never fetches, faults or sorts the
/// library on the main actor; a fresh context per call also reads the latest
/// saved and imported state without a stale object cache.
enum VocabLibraryReadModel {
    @concurrent
    static func studyCards(in container: ModelContainer) async throws -> StudyCardsSnapshot {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WordRecord>(predicate: #Predicate { $0.deletedAt == nil })
        descriptor.relationshipKeyPathsForPrefetching = [\.meanings, \.reviewState]
        let words = try context.fetch(descriptor).map(WordSummary.init)
        return StudyCardsSnapshot(groups: RegistrationDayGroup.groups(from: words), wordCount: words.count)
    }

    @concurrent
    static func consolidatingWords(in container: ModelContainer) async throws -> [WordSummary] {
        let context = ModelContext(container)
        // Narrow in the store first; legacy raw values still map through
        // `learningStatus`, so the final status check stays in Swift.
        let activeRaw = VocabularyLearningStatus.active.rawValue
        let masteredRaw = VocabularyLearningStatus.mastered.rawValue
        var descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                word.deletedAt == nil && word.statusRaw != activeRaw && word.statusRaw != masteredRaw
            },
            sortBy: [SortDescriptor(\.normalizedTerm)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.meanings, \.reviewState]
        return try context.fetch(descriptor)
            .map(WordSummary.init)
            .filter { $0.status == .consolidating }
    }

    @concurrent
    static func reviewCandidates(in container: ModelContainer) async throws -> [WordSummary] {
        let context = ModelContext(container)
        // Fetching the words, not their review states, lets meanings and review
        // state arrive in batched prefetches instead of one fault per candidate.
        var descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                word.deletedAt == nil && (word.reviewState?.activePriority ?? 0) > 0
            }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.meanings, \.reviewState]
        return ReviewCandidateList.words(from: try context.fetch(descriptor))
    }

    /// Resolves a library search to ordered word IDs, or `nil` for a blank query
    /// (the whole library in headword order).
    @concurrent
    static func librarySearchIDs(for query: String, in container: ModelContainer) async throws -> [UUID]? {
        try WordLibrarySearch(context: ModelContext(container)).resolveWordIDs(for: query)
    }

    @concurrent
    static func libraryWords(
        matching searchIDs: [UUID]?,
        offset: Int,
        limit: Int,
        in container: ModelContainer
    ) async throws -> [WordSummary] {
        let context = ModelContext(container)
        guard let searchIDs else {
            var descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.normalizedTerm)]
            )
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            descriptor.relationshipKeyPathsForPrefetching = [\.meanings, \.reviewState]
            return try context.fetch(descriptor).map(WordSummary.init)
        }

        guard offset < searchIDs.count else { return [] }
        let pageIDs = Array(searchIDs[offset..<min(offset + limit, searchIDs.count)])
        var descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                pageIDs.contains(word.id) && word.deletedAt == nil
            }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.meanings, \.reviewState]
        let wordsByID = Dictionary(
            uniqueKeysWithValues: try context.fetch(descriptor).map { ($0.id, WordSummary($0)) }
        )
        return pageIDs.compactMap { wordsByID[$0] }
    }

    @concurrent
    static func attemptHistory(
        offset: Int,
        limit: Int,
        in container: ModelContainer
    ) async throws -> AttemptHistoryPage {
        let context = ModelContext(container)
        let predicate = #Predicate<AttemptRecord> { $0.deletedAt == nil }
        var descriptor = FetchDescriptor<AttemptRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.answeredAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset
        let attempts = try context.fetch(descriptor).map(AttemptSummary.init)
        let totalCount = try context.fetchCount(FetchDescriptor<AttemptRecord>(predicate: predicate))
        return AttemptHistoryPage(attempts: attempts, totalCount: totalCount)
    }
}

extension ModelContext {
    /// One nondeleted word by ID, for an action that needs the live record
    /// behind a prepared summary (edit, memory aid).
    func activeWord(id: UUID) throws -> WordRecord? {
        var descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in word.id == id && word.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }
}
