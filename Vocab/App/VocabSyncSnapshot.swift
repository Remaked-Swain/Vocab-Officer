import Foundation
import CryptoKit
import SwiftData

struct VocabSyncSnapshot: Codable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    var words: [WordPayload]
    var dailySets: [DailySetPayload]
    var testSessions: [TestSessionPayload] = []
    var attempts: [AttemptPayload] = []
    var anonymousAggregates: [AnonymousAggregatePayload] = []
    var memoryAidCaches: [MemoryAidCachePayload] = []

    struct WordPayload: Codable, Equatable {
        var id: UUID
        var term: String
        var englishAliases: [String]
        var createdAt: Date
        var statusRaw: String
        var deletedAt: Date?
        var meanings: [MeaningPayload]
        var reviewState: ReviewStatePayload?
    }

    struct MeaningPayload: Codable, Equatable {
        var id: UUID
        var text: String
        var isCore: Bool
        var aliases: [String]
        var successDays: [String]
    }

    struct ReviewStatePayload: Codable, Equatable {
        var failureCheck: Int
        var activePriority: Int
        var enToKoStreak: Int
        var koToEnStreak: Int
        var koToEnSuccessDays: [String]
        var latestWrongDirection: String?
        var latestWrongAt: Date?
        var lastTestedAt: Date?
        var presentationCount: Int?
        var lastPresentedAt: Date?
    }

    struct DailySetPayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var createdAt: Date
        var completedAt: Date?
        var items: [DailySetItemPayload]
    }

    struct DailySetItemPayload: Codable, Equatable {
        var id: UUID
        var orderIndex: Int
        var entryKind: String
        var wordID: UUID
    }

    struct TestSessionPayload: Codable, Equatable {
        var id: UUID
        var directionRaw: String
        var modeRaw: String
        var seoulDay: String
        var startedAt: Date
        var completedAt: Date?
        var wordIDs: [UUID]
        var wasReduced: Bool
    }

    struct AttemptPayload: Codable, Equatable {
        var id: UUID
        var directionRaw: String
        var modeRaw: String
        var sessionID: UUID
        var questionIndex: Int
        var seoulDay: String
        var prompt: String
        var submittedAnswer: String
        var automaticJudgementRaw: String
        var finalJudgementRaw: String
        var correctionRaw: String?
        var matchedMeaningID: UUID?
        var answeredAt: Date
        var wordID: UUID?
    }

    struct AnonymousAggregatePayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var modeRaw: String
        var correctCount: Int
        var incorrectCount: Int
        var unknownCount: Int
        var deletedMasteredCount: Int
    }

    struct MemoryAidCachePayload: Codable, Equatable {
        var id: UUID
        var wordID: UUID
        var modelRaw: String
        var promptVersion: Int
        var contentSignature: String
        var markdown: String
        var generatedAt: Date
    }
}

extension VocabSyncSnapshot {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case words
        case dailySets
        case testSessions
        case attempts
        case anonymousAggregates
        case memoryAidCaches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        words = try container.decode([WordPayload].self, forKey: .words)
        dailySets = try container.decode([DailySetPayload].self, forKey: .dailySets)
        testSessions = try container.decodeIfPresent([TestSessionPayload].self, forKey: .testSessions) ?? []
        attempts = try container.decodeIfPresent([AttemptPayload].self, forKey: .attempts) ?? []
        anonymousAggregates = try container.decodeIfPresent(
            [AnonymousAggregatePayload].self,
            forKey: .anonymousAggregates
        ) ?? []
        memoryAidCaches = try container.decodeIfPresent([MemoryAidCachePayload].self, forKey: .memoryAidCaches) ?? []
    }
}

extension VocabSyncSnapshot {
    func contentFingerprint() throws -> String {
        var normalized = self
        normalized.exportedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(normalized)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum VocabSyncSnapshotService {
    static let currentFormatVersion = 1

    enum SnapshotValidationError: Error, Equatable {
        case unsupportedFormatVersion(Int)
        case duplicateWordID(UUID)
        case duplicateMeaningID(UUID)
        case duplicateDailySetID(UUID)
        case duplicateDailySetItemID(UUID)
        case duplicateTestSessionID(UUID)
        case duplicateAttemptID(UUID)
        case duplicateAnonymousAggregateID(UUID)
        case duplicateMemoryAidCacheID(UUID)
        case missingWordForDailySetItem(UUID)
        case missingWordForTestSession(UUID)
        case missingSessionForAttempt(UUID)
        case missingWordForAttempt(UUID)
        case missingMeaningForAttempt(UUID)
        case missingWordForMemoryAidCache(UUID)
    }

    static func exportSnapshot(context: ModelContext, exportedAt: Date = .now) throws -> VocabSyncSnapshot {
        let words = try context.fetch(
            FetchDescriptor<WordRecord>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.normalizedTerm)]
            )
        )
        let sets = try context.fetch(
            FetchDescriptor<DailySetRecord>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )

        return VocabSyncSnapshot(
            formatVersion: currentFormatVersion,
            exportedAt: exportedAt,
            words: words.map(wordPayload),
            dailySets: sets.map(dailySetPayload),
            testSessions: try context.fetch(FetchDescriptor<TestSessionRecord>(
                sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.id)]
            )).map(testSessionPayload),
            attempts: try context.fetch(FetchDescriptor<AttemptRecord>(
                sortBy: [SortDescriptor(\.answeredAt), SortDescriptor(\.id)]
            )).map(attemptPayload),
            anonymousAggregates: try context.fetch(FetchDescriptor<AnonymousAggregateRecord>(
                sortBy: [SortDescriptor(\.seoulDay), SortDescriptor(\.modeRaw)]
            )).map(anonymousAggregatePayload),
            memoryAidCaches: try context.fetch(FetchDescriptor<MemoryAidCacheRecord>(
                sortBy: [SortDescriptor(\.generatedAt), SortDescriptor(\.id)]
            )).map(memoryAidCachePayload)
        )
    }

    static func replaceLocalStore(with snapshot: VocabSyncSnapshot, context: ModelContext) throws {
        try validate(snapshot)
        try deleteExistingSyncData(context: context)

        var wordsByID: [UUID: WordRecord] = [:]
        for payload in snapshot.words {
            let word = WordRecord(term: payload.term, createdAt: payload.createdAt)
            word.id = payload.id
            word.normalizedTerm = TextNormalizer.normalizeEnglish(payload.term)
            word.englishAliases = payload.englishAliases
            word.statusRaw = payload.statusRaw
            word.deletedAt = payload.deletedAt

            for meaningPayload in payload.meanings {
                let meaning = MeaningRecord(
                    text: meaningPayload.text,
                    isCore: meaningPayload.isCore,
                    aliases: meaningPayload.aliases
                )
                meaning.id = meaningPayload.id
                meaning.normalizedText = TextNormalizer.normalizeKorean(meaningPayload.text)
                meaning.successDays = meaningPayload.successDays
                meaning.word = word
                word.meanings.append(meaning)
                context.insert(meaning)
            }

            if let statePayload = payload.reviewState {
                let state = ReviewStateRecord()
                state.failureCheck = statePayload.failureCheck
                state.activePriority = statePayload.activePriority
                state.enToKoStreak = statePayload.enToKoStreak
                state.koToEnStreak = statePayload.koToEnStreak
                state.koToEnSuccessDays = statePayload.koToEnSuccessDays
                state.latestWrongDirection = statePayload.latestWrongDirection
                state.latestWrongAt = statePayload.latestWrongAt
                state.lastTestedAt = statePayload.lastTestedAt
                state.presentationCount = statePayload.presentationCount
                state.lastPresentedAt = statePayload.lastPresentedAt
                state.word = word
                word.reviewState = state
                context.insert(state)
            }

            context.insert(word)
            wordsByID[word.id] = word
        }

        for payload in snapshot.dailySets {
            let set = DailySetRecord(seoulDay: payload.seoulDay, createdAt: payload.createdAt)
            set.id = payload.id
            set.completedAt = payload.completedAt

            for itemPayload in payload.items {
                guard wordsByID[itemPayload.wordID] != nil else { continue }
                let item = DailySetItemRecord(
                    orderIndex: itemPayload.orderIndex,
                    entryKind: itemPayload.entryKind,
                    wordID: itemPayload.wordID
                )
                item.id = itemPayload.id
                item.set = set
                set.items.append(item)
                context.insert(item)
            }

            context.insert(set)
        }

        for payload in snapshot.testSessions {
            let session = TestSessionRecord(
                id: payload.id,
                directionRaw: payload.directionRaw,
                modeRaw: payload.modeRaw,
                seoulDay: payload.seoulDay,
                wordIDs: payload.wordIDs,
                wasReduced: payload.wasReduced,
                startedAt: payload.startedAt
            )
            session.completedAt = payload.completedAt
            context.insert(session)
        }

        for payload in snapshot.attempts {
            let attempt = AttemptRecord(
                directionRaw: payload.directionRaw,
                modeRaw: payload.modeRaw,
                sessionID: payload.sessionID,
                questionIndex: payload.questionIndex,
                seoulDay: payload.seoulDay,
                prompt: payload.prompt,
                submittedAnswer: payload.submittedAnswer,
                automaticJudgementRaw: payload.automaticJudgementRaw,
                finalJudgementRaw: payload.finalJudgementRaw,
                matchedMeaningID: payload.matchedMeaningID,
                answeredAt: payload.answeredAt
            )
            attempt.id = payload.id
            attempt.correctionRaw = payload.correctionRaw
            if let wordID = payload.wordID {
                attempt.word = wordsByID[wordID]
            }
            context.insert(attempt)
        }

        for payload in snapshot.anonymousAggregates {
            let aggregate = AnonymousAggregateRecord(seoulDay: payload.seoulDay, modeRaw: payload.modeRaw)
            aggregate.id = payload.id
            aggregate.correctCount = payload.correctCount
            aggregate.incorrectCount = payload.incorrectCount
            aggregate.unknownCount = payload.unknownCount
            aggregate.deletedMasteredCount = payload.deletedMasteredCount
            context.insert(aggregate)
        }

        for payload in snapshot.memoryAidCaches {
            let cache = MemoryAidCacheRecord(
                wordID: payload.wordID,
                modelRaw: payload.modelRaw,
                promptVersion: payload.promptVersion,
                contentSignature: payload.contentSignature,
                markdown: payload.markdown,
                generatedAt: payload.generatedAt
            )
            cache.id = payload.id
            context.insert(cache)
        }

        try context.save()
    }

    static func validate(_ snapshot: VocabSyncSnapshot) throws {
        guard snapshot.formatVersion == currentFormatVersion else {
            throw SnapshotValidationError.unsupportedFormatVersion(snapshot.formatVersion)
        }

        var wordIDs = Set<UUID>()
        var meaningIDs = Set<UUID>()
        var dailySetIDs = Set<UUID>()
        var dailySetItemIDs = Set<UUID>()
        var sessionIDs = Set<UUID>()
        var attemptIDs = Set<UUID>()
        var aggregateIDs = Set<UUID>()
        var memoryAidCacheIDs = Set<UUID>()

        for word in snapshot.words {
            guard wordIDs.insert(word.id).inserted else {
                throw SnapshotValidationError.duplicateWordID(word.id)
            }
            for meaning in word.meanings {
                guard meaningIDs.insert(meaning.id).inserted else {
                    throw SnapshotValidationError.duplicateMeaningID(meaning.id)
                }
            }
        }

        for set in snapshot.dailySets {
            guard dailySetIDs.insert(set.id).inserted else {
                throw SnapshotValidationError.duplicateDailySetID(set.id)
            }
            for item in set.items {
                guard dailySetItemIDs.insert(item.id).inserted else {
                    throw SnapshotValidationError.duplicateDailySetItemID(item.id)
                }
                guard wordIDs.contains(item.wordID) else {
                    throw SnapshotValidationError.missingWordForDailySetItem(item.wordID)
                }
            }
        }

        for session in snapshot.testSessions {
            guard sessionIDs.insert(session.id).inserted else {
                throw SnapshotValidationError.duplicateTestSessionID(session.id)
            }
            for wordID in session.wordIDs where !wordIDs.contains(wordID) {
                throw SnapshotValidationError.missingWordForTestSession(wordID)
            }
        }

        for attempt in snapshot.attempts {
            guard attemptIDs.insert(attempt.id).inserted else {
                throw SnapshotValidationError.duplicateAttemptID(attempt.id)
            }
            if !sessionIDs.contains(attempt.sessionID) {
                throw SnapshotValidationError.missingSessionForAttempt(attempt.sessionID)
            }
            if let wordID = attempt.wordID, !wordIDs.contains(wordID) {
                throw SnapshotValidationError.missingWordForAttempt(wordID)
            }
            if let meaningID = attempt.matchedMeaningID, !meaningIDs.contains(meaningID) {
                throw SnapshotValidationError.missingMeaningForAttempt(meaningID)
            }
        }

        for aggregate in snapshot.anonymousAggregates {
            guard aggregateIDs.insert(aggregate.id).inserted else {
                throw SnapshotValidationError.duplicateAnonymousAggregateID(aggregate.id)
            }
        }

        for cache in snapshot.memoryAidCaches {
            guard memoryAidCacheIDs.insert(cache.id).inserted else {
                throw SnapshotValidationError.duplicateMemoryAidCacheID(cache.id)
            }
            guard wordIDs.contains(cache.wordID) else {
                throw SnapshotValidationError.missingWordForMemoryAidCache(cache.wordID)
            }
        }
    }

    private static func wordPayload(_ word: WordRecord) -> VocabSyncSnapshot.WordPayload {
        VocabSyncSnapshot.WordPayload(
            id: word.id,
            term: word.term,
            englishAliases: word.englishAliases,
            createdAt: word.createdAt,
            statusRaw: word.statusRaw,
            deletedAt: word.deletedAt,
            meanings: word.meanings.sorted { $0.text < $1.text }.map(meaningPayload),
            reviewState: word.reviewState.map(reviewPayload)
        )
    }

    private static func meaningPayload(_ meaning: MeaningRecord) -> VocabSyncSnapshot.MeaningPayload {
        VocabSyncSnapshot.MeaningPayload(
            id: meaning.id,
            text: meaning.text,
            isCore: meaning.isCore,
            aliases: meaning.aliases,
            successDays: meaning.successDays
        )
    }

    private static func reviewPayload(_ state: ReviewStateRecord) -> VocabSyncSnapshot.ReviewStatePayload {
        VocabSyncSnapshot.ReviewStatePayload(
            failureCheck: state.failureCheck,
            activePriority: state.activePriority,
            enToKoStreak: state.enToKoStreak,
            koToEnStreak: state.koToEnStreak,
            koToEnSuccessDays: state.koToEnSuccessDays,
            latestWrongDirection: state.latestWrongDirection,
            latestWrongAt: state.latestWrongAt,
            lastTestedAt: state.lastTestedAt,
            presentationCount: state.presentationCount,
            lastPresentedAt: state.lastPresentedAt
        )
    }

    private static func dailySetPayload(_ set: DailySetRecord) -> VocabSyncSnapshot.DailySetPayload {
        VocabSyncSnapshot.DailySetPayload(
            id: set.id,
            seoulDay: set.seoulDay,
            createdAt: set.createdAt,
            completedAt: set.completedAt,
            items: set.items.sorted { $0.orderIndex < $1.orderIndex }.map(itemPayload)
        )
    }

    private static func itemPayload(_ item: DailySetItemRecord) -> VocabSyncSnapshot.DailySetItemPayload {
        VocabSyncSnapshot.DailySetItemPayload(
            id: item.id,
            orderIndex: item.orderIndex,
            entryKind: item.entryKind,
            wordID: item.wordID
        )
    }

    private static func testSessionPayload(_ session: TestSessionRecord) -> VocabSyncSnapshot.TestSessionPayload {
        VocabSyncSnapshot.TestSessionPayload(
            id: session.id,
            directionRaw: session.directionRaw,
            modeRaw: session.modeRaw,
            seoulDay: session.seoulDay,
            startedAt: session.startedAt,
            completedAt: session.completedAt,
            wordIDs: session.wordIDs,
            wasReduced: session.wasReduced
        )
    }

    private static func attemptPayload(_ attempt: AttemptRecord) -> VocabSyncSnapshot.AttemptPayload {
        VocabSyncSnapshot.AttemptPayload(
            id: attempt.id,
            directionRaw: attempt.directionRaw,
            modeRaw: attempt.modeRaw,
            sessionID: attempt.sessionID,
            questionIndex: attempt.questionIndex,
            seoulDay: attempt.seoulDay,
            prompt: attempt.prompt,
            submittedAnswer: attempt.submittedAnswer,
            automaticJudgementRaw: attempt.automaticJudgementRaw,
            finalJudgementRaw: attempt.finalJudgementRaw,
            correctionRaw: attempt.correctionRaw,
            matchedMeaningID: attempt.matchedMeaningID,
            answeredAt: attempt.answeredAt,
            wordID: attempt.word?.id
        )
    }

    private static func anonymousAggregatePayload(_ aggregate: AnonymousAggregateRecord) -> VocabSyncSnapshot.AnonymousAggregatePayload {
        VocabSyncSnapshot.AnonymousAggregatePayload(
            id: aggregate.id,
            seoulDay: aggregate.seoulDay,
            modeRaw: aggregate.modeRaw,
            correctCount: aggregate.correctCount,
            incorrectCount: aggregate.incorrectCount,
            unknownCount: aggregate.unknownCount,
            deletedMasteredCount: aggregate.deletedMasteredCount
        )
    }

    private static func memoryAidCachePayload(_ cache: MemoryAidCacheRecord) -> VocabSyncSnapshot.MemoryAidCachePayload {
        VocabSyncSnapshot.MemoryAidCachePayload(
            id: cache.id,
            wordID: cache.wordID,
            modelRaw: cache.modelRaw,
            promptVersion: cache.promptVersion,
            contentSignature: cache.contentSignature,
            markdown: cache.markdown,
            generatedAt: cache.generatedAt
        )
    }

    private static func deleteExistingSyncData(context: ModelContext) throws {
        for record in try context.fetch(FetchDescriptor<TestSessionRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<MemoryAidCacheRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<WordRecord>()) {
            context.delete(record)
        }
    }
}

struct VocabStoreMigrationReport: Equatable {
    let checkpointDirectoryName: String
    let wordCount: Int
    let dailySetCount: Int
    let testSessionCount: Int
    let attemptCount: Int
    let anonymousAggregateCount: Int
    let memoryAidCacheCount: Int
    let contentFingerprint: String
}

struct VocabStoreContentCounts: Equatable {
    let words: Int
    let dailySets: Int
    let testSessions: Int
    let attempts: Int
    let anonymousAggregates: Int
    let memoryAidCaches: Int

    var isEmpty: Bool {
        words == 0
            && dailySets == 0
            && testSessions == 0
            && attempts == 0
            && anonymousAggregates == 0
            && memoryAidCaches == 0
    }
}

enum VocabStoreMigrationError: LocalizedError, Equatable {
    case verificationMismatch
    case mirroredStoreAlreadyContainsData(VocabStoreContentCounts)

    var errorDescription: String? {
        switch self {
        case .verificationMismatch:
            "mirrored store 이관 후 검증값이 원본과 일치하지 않습니다. 기존 로컬 단어장은 유지됩니다."
        case .mirroredStoreAlreadyContainsData:
            "이미 iCloud mirrored 저장소에 단어장 데이터가 있어 자동 이관을 중단했습니다. 기존 iCloud 데이터 삭제를 막기 위한 보호 장치입니다."
        }
    }
}

@MainActor
enum VocabStoreMigrationService {
    static func migrateLocalSnapshotToMirroredStore(
        localContext: ModelContext,
        mirroredContext: ModelContext,
        createCheckpoint: () throws -> VocabLocalStoreCheckpoint
    ) throws -> VocabStoreMigrationReport {
        try localContext.save()
        let checkpoint = try createCheckpoint()
        let sourceSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: localContext)
        let sourceFingerprint = try sourceSnapshot.contentFingerprint()
        let mirroredCounts = try contentCounts(context: mirroredContext)
        guard mirroredCounts.isEmpty else {
            throw VocabStoreMigrationError.mirroredStoreAlreadyContainsData(mirroredCounts)
        }

        try VocabSyncSnapshotService.replaceLocalStore(with: sourceSnapshot, context: mirroredContext)
        let restoredSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: mirroredContext)
        let restoredFingerprint = try restoredSnapshot.contentFingerprint()
        guard sourceFingerprint == restoredFingerprint else {
            throw VocabStoreMigrationError.verificationMismatch
        }

        return VocabStoreMigrationReport(
            checkpointDirectoryName: checkpoint.directory.lastPathComponent,
            wordCount: sourceSnapshot.words.count,
            dailySetCount: sourceSnapshot.dailySets.count,
            testSessionCount: sourceSnapshot.testSessions.count,
            attemptCount: sourceSnapshot.attempts.count,
            anonymousAggregateCount: sourceSnapshot.anonymousAggregates.count,
            memoryAidCacheCount: sourceSnapshot.memoryAidCaches.count,
            contentFingerprint: sourceFingerprint
        )
    }

    private static func contentCounts(context: ModelContext) throws -> VocabStoreContentCounts {
        VocabStoreContentCounts(
            words: try context.fetchCount(FetchDescriptor<WordRecord>()),
            dailySets: try context.fetchCount(FetchDescriptor<DailySetRecord>()),
            testSessions: try context.fetchCount(FetchDescriptor<TestSessionRecord>()),
            attempts: try context.fetchCount(FetchDescriptor<AttemptRecord>()),
            anonymousAggregates: try context.fetchCount(FetchDescriptor<AnonymousAggregateRecord>()),
            memoryAidCaches: try context.fetchCount(FetchDescriptor<MemoryAidCacheRecord>())
        )
    }
}
