import Foundation
import CryptoKit
import SwiftData

struct VocabSyncSnapshot: Codable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    var syncMetadata: SyncMetadataPayload? = nil
    var words: [WordPayload]
    var dailySets: [DailySetPayload]
    var testSessions: [TestSessionPayload] = []
    var attempts: [AttemptPayload] = []
    var anonymousAggregates: [AnonymousAggregatePayload] = []
    var memoryAidCaches: [MemoryAidCachePayload] = []
    var tombstones: [TombstonePayload] = []

    struct SyncMetadataPayload: Codable, Equatable {
        var schemaVersion: Int
        var bootstrapUUID: UUID
        var contentFingerprint: String
        var expectedCounts: VocabEntityCounts
        var createdAt: Date
        var completedAt: Date? = nil
        var lastReconciledAt: Date? = nil
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct WordPayload: Codable, Equatable {
        var id: UUID
        var term: String
        var englishAliases: [String]
        var createdAt: Date
        var statusRaw: String
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
        var meanings: [MeaningPayload]
        var reviewState: ReviewStatePayload?
    }

    struct MeaningPayload: Codable, Equatable {
        var id: UUID
        var text: String
        var isCore: Bool
        var aliases: [String]
        var successDays: [String]
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
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
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct DailySetPayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var createdAt: Date
        var completedAt: Date?
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
        var items: [DailySetItemPayload]
    }

    struct DailySetItemPayload: Codable, Equatable {
        var id: UUID
        var orderIndex: Int
        var entryKind: String
        var wordID: UUID
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date?
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
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
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
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct AnonymousAggregatePayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var modeRaw: String
        var correctCount: Int
        var incorrectCount: Int
        var unknownCount: Int
        var deletedMasteredCount: Int
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct MemoryAidCachePayload: Codable, Equatable {
        var id: UUID
        var wordID: UUID
        var modelRaw: String
        var promptVersion: Int
        var contentSignature: String
        var markdown: String
        var generatedAt: Date
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct TombstonePayload: Codable, Equatable {
        var id: UUID
        var recordID: UUID
        var recordType: String
        var deletedAt: Date
        var updatedAt: Date? = nil
        var originDeviceID: String
    }
}

extension VocabSyncSnapshot {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case syncMetadata
        case words
        case dailySets
        case testSessions
        case attempts
        case anonymousAggregates
        case memoryAidCaches
        case tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        syncMetadata = try container.decodeIfPresent(SyncMetadataPayload.self, forKey: .syncMetadata)
        words = try container.decode([WordPayload].self, forKey: .words)
        dailySets = try container.decode([DailySetPayload].self, forKey: .dailySets)
        testSessions = try container.decodeIfPresent([TestSessionPayload].self, forKey: .testSessions) ?? []
        attempts = try container.decodeIfPresent([AttemptPayload].self, forKey: .attempts) ?? []
        anonymousAggregates = try container.decodeIfPresent(
            [AnonymousAggregatePayload].self,
            forKey: .anonymousAggregates
        ) ?? []
        memoryAidCaches = try container.decodeIfPresent([MemoryAidCachePayload].self, forKey: .memoryAidCaches) ?? []
        tombstones = try container.decodeIfPresent([TombstonePayload].self, forKey: .tombstones) ?? []
    }
}

extension VocabSyncSnapshot {
    func contentFingerprint() throws -> String {
        var normalized = self
        normalized.exportedAt = Date(timeIntervalSince1970: 0)
        normalized.syncMetadata = nil
        let deletionMarker = Date(timeIntervalSince1970: 0)
        func stableDate(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        func stableDate(_ date: Date?) -> Date? {
            date.map(stableDate)
        }
        func stableSetCreationDate(_ date: Date) -> Date {
            // Legacy sets stored a missing required date as NULL. CloudKit materializes
            // the same sentinel as its reference date, so both represent no user data.
            guard date > Date(timeIntervalSinceReferenceDate: 0) else { return deletionMarker }
            return stableDate(date)
        }
        let tombstoned = Set(tombstones.map { "\($0.recordType):\($0.recordID.uuidString)" })
        func isDeleted(_ recordType: String, _ id: UUID, _ deletedAt: Date?) -> Bool {
            deletedAt != nil || tombstoned.contains("\(recordType):\(id.uuidString)")
        }

        normalized.words = normalized.words.map { word in
            var word = word
            word.updatedAt = nil
            word.originDeviceID = nil
            word.statusRaw = ""
            word.createdAt = stableDate(word.createdAt)
            word.deletedAt = isDeleted("WordRecord", word.id, word.deletedAt) ? deletionMarker : nil
            word.meanings = word.meanings.map { meaning in
                var meaning = meaning
                meaning.updatedAt = nil
                meaning.originDeviceID = nil
                meaning.deletedAt = isDeleted("MeaningRecord", meaning.id, meaning.deletedAt) ? deletionMarker : nil
                meaning.aliases.sort()
                meaning.successDays = []
                return meaning
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            word.reviewState = nil
            word.englishAliases.sort()
            return word
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.dailySets = normalized.dailySets.map { set in
            var set = set
            set.createdAt = stableSetCreationDate(set.createdAt)
            set.completedAt = stableDate(set.completedAt)
            set.updatedAt = nil
            set.originDeviceID = nil
            set.deletedAt = isDeleted("DailySetRecord", set.id, set.deletedAt) ? deletionMarker : nil
            set.items = set.items.map { item in
                var item = item
                item.updatedAt = nil
                item.originDeviceID = nil
                item.deletedAt = isDeleted("DailySetItemRecord", item.id, item.deletedAt) ? deletionMarker : nil
                return item
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return set
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.testSessions = normalized.testSessions.map { record in
            var record = record
            record.startedAt = stableDate(record.startedAt)
            record.completedAt = stableDate(record.completedAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.attempts = normalized.attempts.map { record in
            var record = record
            record.answeredAt = stableDate(record.answeredAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.anonymousAggregates = normalized.anonymousAggregates.map { record in
            var record = record
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.memoryAidCaches = normalized.memoryAidCaches.map { record in
            var record = record
            record.generatedAt = stableDate(record.generatedAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.tombstones = normalized.tombstones.map { record in
            var record = record
            record.deletedAt = deletionMarker
            record.updatedAt = nil
            record.originDeviceID = ""
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(normalized)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum VocabSyncSnapshotService {
    nonisolated static let currentFormatVersion = 2

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
        case mirroredWholeReplaceForbidden
        case legacySnapshotRequiresLocalOnly
        case missingSyncMetadata
        case missingRecordMetadata(String, UUID)
        case contentFingerprintMismatch
    }

    nonisolated static func exportSnapshot(context: ModelContext, exportedAt: Date = .now) throws -> VocabSyncSnapshot {
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

        var snapshot = VocabSyncSnapshot(
            formatVersion: currentFormatVersion,
            exportedAt: exportedAt,
            syncMetadata: nil,
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
            )).map(memoryAidCachePayload),
            tombstones: try context.fetch(FetchDescriptor<RecordTombstone>())
                .sorted { lhs, rhs in
                    lhs.deletedAt == rhs.deletedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.deletedAt < rhs.deletedAt
                }
                .map(tombstonePayload)
        )
        let counts = try VocabCloudReconciler.counts(context: context)
        if let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>()).first(where: { $0.deletedAt == nil }) {
            snapshot.syncMetadata = metadataPayload(metadata)
        } else {
            snapshot.syncMetadata = VocabSyncSnapshot.SyncMetadataPayload(
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                bootstrapUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                contentFingerprint: "",
                expectedCounts: counts,
                createdAt: exportedAt,
                completedAt: exportedAt,
                updatedAt: exportedAt,
                originDeviceID: VocabDeviceIdentity.current
            )
        }
        let fingerprint = try snapshot.contentFingerprint()
        snapshot.syncMetadata?.contentFingerprint = fingerprint
        return snapshot
    }

    nonisolated static func replaceLocalStore(
        with snapshot: VocabSyncSnapshot,
        context: ModelContext,
        syncMode: VocabSyncMode
    ) throws {
        guard syncMode == .localOnly else { throw SnapshotValidationError.mirroredWholeReplaceForbidden }
        if snapshot.formatVersion == 1, syncMode != .localOnly {
            throw SnapshotValidationError.legacySnapshotRequiresLocalOnly
        }
        try validate(snapshot)
        try deleteExistingSyncData(context: context)
        try importSnapshotRecords(snapshot, context: context)
        try context.save()
    }

    nonisolated static func importSnapshotRecords(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        includeSyncMetadata: Bool = true,
        onlyInsertMissing: Bool = false
    ) throws {
        try validate(snapshot)

        let existingWords = indexByID(try context.fetch(FetchDescriptor<WordRecord>()), id: \.id)
        let existingMeanings = indexByID(try context.fetch(FetchDescriptor<MeaningRecord>()), id: \.id)
        let existingSets = indexByID(try context.fetch(FetchDescriptor<DailySetRecord>()), id: \.id)
        let existingItems = indexByID(try context.fetch(FetchDescriptor<DailySetItemRecord>()), id: \.id)
        let existingSessions = indexByID(try context.fetch(FetchDescriptor<TestSessionRecord>()), id: \.id)
        let existingAttempts = indexByID(try context.fetch(FetchDescriptor<AttemptRecord>()), id: \.id)
        let existingAggregates = indexByID(try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()), id: \.id)
        let existingCaches = indexByID(try context.fetch(FetchDescriptor<MemoryAidCacheRecord>()), id: \.id)
        let existingTombstones = indexByID(try context.fetch(FetchDescriptor<RecordTombstone>()), id: \.id)

        if includeSyncMetadata, let payload = snapshot.syncMetadata {
            let existingMetadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
                .first { $0.bootstrapUUID == payload.bootstrapUUID }
            let metadata = existingMetadata ?? CloudBootstrapRecord(
                bootstrapUUID: payload.bootstrapUUID,
                contentFingerprint: payload.contentFingerprint,
                completedAt: payload.createdAt
            )
            if existingMetadata == nil || !onlyInsertMissing {
                metadata.schemaVersion = payload.schemaVersion
                metadata.expectedWordCount = payload.expectedCounts.words
                metadata.expectedMeaningCount = payload.expectedCounts.meanings
                metadata.expectedDailySetCount = payload.expectedCounts.dailySets
                metadata.expectedDailySetItemCount = payload.expectedCounts.dailySetItems
                metadata.expectedTestSessionCount = payload.expectedCounts.testSessions
                metadata.expectedAttemptCount = payload.expectedCounts.attempts
                metadata.expectedAnonymousAggregateCount = payload.expectedCounts.anonymousAggregates
                metadata.expectedMemoryAidCacheCount = payload.expectedCounts.memoryAidCaches
                metadata.expectedTombstoneCount = payload.expectedCounts.tombstones
                metadata.completedAt = payload.completedAt ?? payload.createdAt
                metadata.lastReconciledAt = payload.lastReconciledAt
                metadata.updatedAt = payload.updatedAt ?? payload.createdAt
                metadata.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                metadata.deletedAt = payload.deletedAt
            }
            if existingMetadata == nil { context.insert(metadata) }
        }

        var wordsByID: [UUID: WordRecord] = [:]
        for payload in snapshot.words {
            let existingWord = existingWords[payload.id]
            let word = existingWord ?? WordRecord(term: payload.term, createdAt: payload.createdAt)
            if existingWord == nil || !onlyInsertMissing {
                word.id = payload.id
                word.term = payload.term
                word.normalizedTerm = TextNormalizer.normalizeEnglish(payload.term)
                word.englishAliases = payload.englishAliases
                word.statusRaw = payload.statusRaw
                word.updatedAt = payload.updatedAt ?? payload.createdAt
                word.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                word.deletedAt = payload.deletedAt
            }

            for meaningPayload in payload.meanings {
                let existingMeaning = existingMeanings[meaningPayload.id]
                let meaning = existingMeaning ?? MeaningRecord(
                    text: meaningPayload.text,
                    isCore: meaningPayload.isCore,
                    aliases: meaningPayload.aliases
                )
                if existingMeaning == nil || !onlyInsertMissing {
                    meaning.id = meaningPayload.id
                    meaning.text = meaningPayload.text
                    meaning.normalizedText = TextNormalizer.normalizeKorean(meaningPayload.text)
                    meaning.isCore = meaningPayload.isCore
                    meaning.aliases = meaningPayload.aliases
                    meaning.successDays = meaningPayload.successDays
                    meaning.updatedAt = meaningPayload.updatedAt ?? payload.createdAt
                    meaning.originDeviceID = meaningPayload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                    meaning.deletedAt = meaningPayload.deletedAt
                }
                meaning.word = word
                if !word.allMeanings.contains(where: { $0.id == meaning.id }) { word.appendMeaning(meaning) }
                if existingMeaning == nil { context.insert(meaning) }
            }

            if let statePayload = payload.reviewState {
                let existingState = word.reviewState
                let state = existingState ?? ReviewStateRecord()
                if existingState == nil || !onlyInsertMissing {
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
                    state.updatedAt = statePayload.updatedAt ?? payload.createdAt
                    state.originDeviceID = statePayload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                    state.deletedAt = statePayload.deletedAt
                }
                state.word = word
                word.reviewState = state
                if existingState == nil { context.insert(state) }
            }

            if existingWord == nil { context.insert(word) }
            wordsByID[word.id] = word
        }

        for payload in snapshot.dailySets {
            let existingSet = existingSets[payload.id]
            let set = existingSet ?? DailySetRecord(seoulDay: payload.seoulDay, createdAt: payload.createdAt)
            if existingSet == nil || !onlyInsertMissing {
                set.id = payload.id
                set.seoulDay = payload.seoulDay
                set.completedAt = payload.completedAt
                set.updatedAt = payload.updatedAt ?? payload.createdAt
                set.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                set.deletedAt = payload.deletedAt
            }

            for itemPayload in payload.items {
                guard wordsByID[itemPayload.wordID] != nil else { continue }
                let existingItem = existingItems[itemPayload.id]
                let item = existingItem ?? DailySetItemRecord(
                    orderIndex: itemPayload.orderIndex,
                    entryKind: itemPayload.entryKind,
                    wordID: itemPayload.wordID
                )
                if existingItem == nil || !onlyInsertMissing {
                    item.id = itemPayload.id
                    item.orderIndex = itemPayload.orderIndex
                    item.entryKind = itemPayload.entryKind
                    item.wordID = itemPayload.wordID
                    item.updatedAt = itemPayload.updatedAt ?? payload.createdAt
                    item.originDeviceID = itemPayload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                    item.deletedAt = itemPayload.deletedAt
                }
                item.set = set
                if !set.allItems.contains(where: { $0.id == item.id }) { set.appendItem(item) }
                if existingItem == nil { context.insert(item) }
            }

            if existingSet == nil { context.insert(set) }
        }

        for payload in snapshot.testSessions {
            let existingSession = existingSessions[payload.id]
            let session = existingSession ?? TestSessionRecord(
                id: payload.id,
                directionRaw: payload.directionRaw,
                modeRaw: payload.modeRaw,
                seoulDay: payload.seoulDay,
                wordIDs: payload.wordIDs,
                wasReduced: payload.wasReduced,
                startedAt: payload.startedAt
            )
            if existingSession == nil || !onlyInsertMissing {
                session.id = payload.id
                session.directionRaw = payload.directionRaw
                session.modeRaw = payload.modeRaw
                session.seoulDay = payload.seoulDay
                session.startedAt = payload.startedAt
                session.completedAt = payload.completedAt
                session.wordIDs = payload.wordIDs
                session.wasReduced = payload.wasReduced
                session.updatedAt = payload.updatedAt ?? payload.startedAt
                session.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                session.deletedAt = payload.deletedAt
            }
            if existingSession == nil { context.insert(session) }
        }

        for payload in snapshot.attempts {
            let existingAttempt = existingAttempts[payload.id]
            let attempt = existingAttempt ?? AttemptRecord(
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
            if existingAttempt == nil || !onlyInsertMissing {
                attempt.id = payload.id
                attempt.directionRaw = payload.directionRaw
                attempt.modeRaw = payload.modeRaw
                attempt.sessionID = payload.sessionID
                attempt.questionIndex = payload.questionIndex
                attempt.seoulDay = payload.seoulDay
                attempt.prompt = payload.prompt
                attempt.submittedAnswer = payload.submittedAnswer
                attempt.automaticJudgementRaw = payload.automaticJudgementRaw
                attempt.finalJudgementRaw = payload.finalJudgementRaw
                attempt.correctionRaw = payload.correctionRaw
                attempt.matchedMeaningID = payload.matchedMeaningID
                attempt.answeredAt = payload.answeredAt
                attempt.updatedAt = payload.updatedAt ?? payload.answeredAt
                attempt.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                attempt.deletedAt = payload.deletedAt
            }
            if let wordID = payload.wordID {
                attempt.word = wordsByID[wordID]
                if let word = wordsByID[wordID], !word.allAttempts.contains(where: { $0.id == attempt.id }) {
                    word.appendAttempt(attempt)
                }
            }
            if existingAttempt == nil { context.insert(attempt) }
        }

        for payload in snapshot.anonymousAggregates {
            let existingAggregate = existingAggregates[payload.id]
            let aggregate = existingAggregate ?? AnonymousAggregateRecord(seoulDay: payload.seoulDay, modeRaw: payload.modeRaw)
            if existingAggregate == nil || !onlyInsertMissing {
                aggregate.id = payload.id
                aggregate.seoulDay = payload.seoulDay
                aggregate.modeRaw = payload.modeRaw
                aggregate.correctCount = payload.correctCount
                aggregate.incorrectCount = payload.incorrectCount
                aggregate.unknownCount = payload.unknownCount
                aggregate.deletedMasteredCount = payload.deletedMasteredCount
                aggregate.updatedAt = payload.updatedAt ?? .distantPast
                aggregate.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                aggregate.deletedAt = payload.deletedAt
            }
            if existingAggregate == nil { context.insert(aggregate) }
        }

        for payload in snapshot.memoryAidCaches {
            let existingCache = existingCaches[payload.id]
            let cache = existingCache ?? MemoryAidCacheRecord(
                wordID: payload.wordID,
                modelRaw: payload.modelRaw,
                promptVersion: payload.promptVersion,
                contentSignature: payload.contentSignature,
                markdown: payload.markdown,
                generatedAt: payload.generatedAt
            )
            if existingCache == nil || !onlyInsertMissing {
                cache.id = payload.id
                cache.wordID = payload.wordID
                cache.modelRaw = payload.modelRaw
                cache.promptVersion = payload.promptVersion
                cache.contentSignature = payload.contentSignature
                cache.markdown = payload.markdown
                cache.generatedAt = payload.generatedAt
                cache.updatedAt = payload.updatedAt ?? payload.generatedAt
                cache.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
                cache.deletedAt = payload.deletedAt
            }
            if existingCache == nil { context.insert(cache) }
        }
        for payload in snapshot.tombstones {
            let existingTombstone = existingTombstones[payload.id]
            let tombstone = existingTombstone ?? RecordTombstone(
                recordID: payload.recordID,
                recordType: payload.recordType,
                deletedAt: payload.deletedAt,
                originDeviceID: payload.originDeviceID
            )
            if existingTombstone == nil || !onlyInsertMissing {
                tombstone.id = payload.id
                tombstone.recordID = payload.recordID
                tombstone.recordType = payload.recordType
                tombstone.deletedAt = payload.deletedAt
                tombstone.updatedAt = payload.updatedAt ?? payload.deletedAt
                tombstone.originDeviceID = payload.originDeviceID
            }
            if existingTombstone == nil { context.insert(tombstone) }
        }
    }

    nonisolated static func importAttemptPayloads(
        _ payloads: ArraySlice<VocabSyncSnapshot.AttemptPayload>,
        context: ModelContext,
        wordsByID: [UUID: WordRecord]
    ) {
        for payload in payloads {
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
            attempt.updatedAt = payload.updatedAt ?? payload.answeredAt
            attempt.originDeviceID = payload.originDeviceID ?? VocabRecordMetadata.legacyOriginDeviceID
            attempt.deletedAt = payload.deletedAt
            if let wordID = payload.wordID, let word = wordsByID[wordID] {
                attempt.word = word
                word.appendAttempt(attempt)
            }
            context.insert(attempt)
        }
    }

    nonisolated private static func indexByID<Record>(
        _ records: [Record],
        id: KeyPath<Record, UUID>
    ) -> [UUID: Record] {
        records.reduce(into: [:]) { indexed, record in
            let recordID = record[keyPath: id]
            if indexed[recordID] == nil { indexed[recordID] = record }
        }
    }

    nonisolated static func validate(_ snapshot: VocabSyncSnapshot) throws {
        guard snapshot.formatVersion == 1 || snapshot.formatVersion == currentFormatVersion else {
            throw SnapshotValidationError.unsupportedFormatVersion(snapshot.formatVersion)
        }
        if snapshot.formatVersion == currentFormatVersion, snapshot.syncMetadata == nil {
            throw SnapshotValidationError.missingSyncMetadata
        }
        if snapshot.formatVersion == currentFormatVersion, let metadata = snapshot.syncMetadata {
            guard metadata.updatedAt != nil, metadata.originDeviceID != nil else {
                throw SnapshotValidationError.missingRecordMetadata("CloudBootstrapRecord", metadata.bootstrapUUID)
            }
            guard !metadata.contentFingerprint.isEmpty,
                  metadata.contentFingerprint == (try snapshot.contentFingerprint()) else {
                throw SnapshotValidationError.contentFingerprintMismatch
            }
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
            try requireV2Metadata(snapshot, type: "WordRecord", id: word.id, updatedAt: word.updatedAt, originDeviceID: word.originDeviceID)
            guard wordIDs.insert(word.id).inserted else {
                throw SnapshotValidationError.duplicateWordID(word.id)
            }
            for meaning in word.meanings {
                try requireV2Metadata(snapshot, type: "MeaningRecord", id: meaning.id, updatedAt: meaning.updatedAt, originDeviceID: meaning.originDeviceID)
                guard meaningIDs.insert(meaning.id).inserted else {
                    throw SnapshotValidationError.duplicateMeaningID(meaning.id)
                }
            }
            if let reviewState = word.reviewState {
                try requireV2Metadata(snapshot, type: "ReviewStateRecord", id: word.id, updatedAt: reviewState.updatedAt, originDeviceID: reviewState.originDeviceID)
            }
        }

        for set in snapshot.dailySets {
            try requireV2Metadata(snapshot, type: "DailySetRecord", id: set.id, updatedAt: set.updatedAt, originDeviceID: set.originDeviceID)
            guard dailySetIDs.insert(set.id).inserted else {
                throw SnapshotValidationError.duplicateDailySetID(set.id)
            }
            for item in set.items {
                try requireV2Metadata(snapshot, type: "DailySetItemRecord", id: item.id, updatedAt: item.updatedAt, originDeviceID: item.originDeviceID)
                guard dailySetItemIDs.insert(item.id).inserted else {
                    throw SnapshotValidationError.duplicateDailySetItemID(item.id)
                }
                guard wordIDs.contains(item.wordID) else {
                    throw SnapshotValidationError.missingWordForDailySetItem(item.wordID)
                }
            }
        }

        for session in snapshot.testSessions {
            try requireV2Metadata(snapshot, type: "TestSessionRecord", id: session.id, updatedAt: session.updatedAt, originDeviceID: session.originDeviceID)
            guard sessionIDs.insert(session.id).inserted else {
                throw SnapshotValidationError.duplicateTestSessionID(session.id)
            }
            for wordID in session.wordIDs where !wordIDs.contains(wordID) {
                throw SnapshotValidationError.missingWordForTestSession(wordID)
            }
        }

        for attempt in snapshot.attempts {
            try requireV2Metadata(snapshot, type: "AttemptRecord", id: attempt.id, updatedAt: attempt.updatedAt, originDeviceID: attempt.originDeviceID)
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
            try requireV2Metadata(snapshot, type: "AnonymousAggregateRecord", id: aggregate.id, updatedAt: aggregate.updatedAt, originDeviceID: aggregate.originDeviceID)
            guard aggregateIDs.insert(aggregate.id).inserted else {
                throw SnapshotValidationError.duplicateAnonymousAggregateID(aggregate.id)
            }
        }

        for cache in snapshot.memoryAidCaches {
            try requireV2Metadata(snapshot, type: "MemoryAidCacheRecord", id: cache.id, updatedAt: cache.updatedAt, originDeviceID: cache.originDeviceID)
            guard memoryAidCacheIDs.insert(cache.id).inserted else {
                throw SnapshotValidationError.duplicateMemoryAidCacheID(cache.id)
            }
            guard wordIDs.contains(cache.wordID) else {
                throw SnapshotValidationError.missingWordForMemoryAidCache(cache.wordID)
            }
        }
        for tombstone in snapshot.tombstones {
            try requireV2Metadata(snapshot, type: "RecordTombstone", id: tombstone.id, updatedAt: tombstone.updatedAt, originDeviceID: tombstone.originDeviceID)
        }
    }

    nonisolated private static func requireV2Metadata(
        _ snapshot: VocabSyncSnapshot,
        type: String,
        id: UUID,
        updatedAt: Date?,
        originDeviceID: String?
    ) throws {
        guard snapshot.formatVersion == currentFormatVersion else { return }
        guard updatedAt != nil, originDeviceID != nil else {
            throw SnapshotValidationError.missingRecordMetadata(type, id)
        }
    }

    nonisolated static func wordPayload(_ word: WordRecord) -> VocabSyncSnapshot.WordPayload {
        VocabSyncSnapshot.WordPayload(
            id: word.id,
            term: word.term,
            englishAliases: word.englishAliases,
            createdAt: word.createdAt,
            statusRaw: word.statusRaw,
            updatedAt: word.updatedAt,
            originDeviceID: word.originDeviceID,
            deletedAt: word.deletedAt,
            meanings: word.allMeanings.sorted { $0.text < $1.text }.map(meaningPayload),
            reviewState: word.reviewState.map(reviewPayload)
        )
    }

    nonisolated private static func meaningPayload(_ meaning: MeaningRecord) -> VocabSyncSnapshot.MeaningPayload {
        VocabSyncSnapshot.MeaningPayload(
            id: meaning.id,
            text: meaning.text,
            isCore: meaning.isCore,
            aliases: meaning.aliases,
            successDays: meaning.successDays,
            updatedAt: meaning.updatedAt,
            originDeviceID: meaning.originDeviceID,
            deletedAt: meaning.deletedAt
        )
    }

    nonisolated private static func reviewPayload(_ state: ReviewStateRecord) -> VocabSyncSnapshot.ReviewStatePayload {
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
            lastPresentedAt: state.lastPresentedAt,
            updatedAt: state.updatedAt,
            originDeviceID: state.originDeviceID,
            deletedAt: state.deletedAt
        )
    }

    nonisolated static func dailySetPayload(_ set: DailySetRecord) -> VocabSyncSnapshot.DailySetPayload {
        VocabSyncSnapshot.DailySetPayload(
            id: set.id,
            seoulDay: set.seoulDay,
            createdAt: set.createdAt,
            completedAt: set.completedAt,
            updatedAt: set.updatedAt,
            originDeviceID: set.originDeviceID,
            deletedAt: set.deletedAt,
            items: set.allItems.sorted { $0.orderIndex < $1.orderIndex }.map(itemPayload)
        )
    }

    nonisolated private static func itemPayload(_ item: DailySetItemRecord) -> VocabSyncSnapshot.DailySetItemPayload {
        VocabSyncSnapshot.DailySetItemPayload(
            id: item.id,
            orderIndex: item.orderIndex,
            entryKind: item.entryKind,
            wordID: item.wordID,
            updatedAt: item.updatedAt,
            originDeviceID: item.originDeviceID,
            deletedAt: item.deletedAt
        )
    }

    nonisolated static func testSessionPayload(_ session: TestSessionRecord) -> VocabSyncSnapshot.TestSessionPayload {
        VocabSyncSnapshot.TestSessionPayload(
            id: session.id,
            directionRaw: session.directionRaw,
            modeRaw: session.modeRaw,
            seoulDay: session.seoulDay,
            startedAt: session.startedAt,
            completedAt: session.completedAt,
            wordIDs: session.wordIDs,
            wasReduced: session.wasReduced,
            updatedAt: session.updatedAt,
            originDeviceID: session.originDeviceID,
            deletedAt: session.deletedAt
        )
    }

    nonisolated static func attemptPayload(_ attempt: AttemptRecord) -> VocabSyncSnapshot.AttemptPayload {
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
            wordID: attempt.word?.id,
            updatedAt: attempt.updatedAt,
            originDeviceID: attempt.originDeviceID,
            deletedAt: attempt.deletedAt
        )
    }

    nonisolated static func anonymousAggregatePayload(_ aggregate: AnonymousAggregateRecord) -> VocabSyncSnapshot.AnonymousAggregatePayload {
        VocabSyncSnapshot.AnonymousAggregatePayload(
            id: aggregate.id,
            seoulDay: aggregate.seoulDay,
            modeRaw: aggregate.modeRaw,
            correctCount: aggregate.correctCount,
            incorrectCount: aggregate.incorrectCount,
            unknownCount: aggregate.unknownCount,
            deletedMasteredCount: aggregate.deletedMasteredCount,
            updatedAt: aggregate.updatedAt,
            originDeviceID: aggregate.originDeviceID,
            deletedAt: aggregate.deletedAt
        )
    }

    nonisolated static func memoryAidCachePayload(_ cache: MemoryAidCacheRecord) -> VocabSyncSnapshot.MemoryAidCachePayload {
        VocabSyncSnapshot.MemoryAidCachePayload(
            id: cache.id,
            wordID: cache.wordID,
            modelRaw: cache.modelRaw,
            promptVersion: cache.promptVersion,
            contentSignature: cache.contentSignature,
            markdown: cache.markdown,
            generatedAt: cache.generatedAt,
            updatedAt: cache.updatedAt,
            originDeviceID: cache.originDeviceID,
            deletedAt: cache.deletedAt
        )
    }

    nonisolated static func tombstonePayload(_ tombstone: RecordTombstone) -> VocabSyncSnapshot.TombstonePayload {
        VocabSyncSnapshot.TombstonePayload(
            id: tombstone.id,
            recordID: tombstone.recordID,
            recordType: tombstone.recordType,
            deletedAt: tombstone.deletedAt,
            updatedAt: tombstone.updatedAt,
            originDeviceID: tombstone.originDeviceID
        )
    }

    nonisolated static func metadataPayload(_ metadata: CloudBootstrapRecord) -> VocabSyncSnapshot.SyncMetadataPayload {
        VocabSyncSnapshot.SyncMetadataPayload(
            schemaVersion: metadata.schemaVersion,
            bootstrapUUID: metadata.bootstrapUUID,
            contentFingerprint: metadata.contentFingerprint,
            expectedCounts: VocabEntityCounts(
                words: metadata.expectedWordCount,
                meanings: metadata.expectedMeaningCount,
                dailySets: metadata.expectedDailySetCount,
                dailySetItems: metadata.expectedDailySetItemCount,
                testSessions: metadata.expectedTestSessionCount,
                attempts: metadata.expectedAttemptCount,
                anonymousAggregates: metadata.expectedAnonymousAggregateCount,
                memoryAidCaches: metadata.expectedMemoryAidCacheCount,
                tombstones: metadata.expectedTombstoneCount
            ),
            createdAt: metadata.createdAt,
            completedAt: metadata.completedAt,
            lastReconciledAt: metadata.lastReconciledAt,
            updatedAt: metadata.updatedAt,
            originDeviceID: metadata.originDeviceID,
            deletedAt: metadata.deletedAt
        )
    }

    nonisolated private static func deleteExistingSyncData(context: ModelContext) throws {
        for record in try context.fetch(FetchDescriptor<AttemptRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<ReviewStateRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<MeaningRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<DailySetItemRecord>()) {
            context.delete(record)
        }
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
        for record in try context.fetch(FetchDescriptor<RecordTombstone>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<CloudBootstrapRecord>()) {
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
    case bootstrapAlreadyCompleted
    case bootstrapUnsupportedOnIOS
    case bootstrapClaimDenied(VocabBootstrapClaimDenial)
    case bootstrapClaimMismatch

    var errorDescription: String? {
        switch self {
        case .verificationMismatch:
            "mirrored store 이관 후 검증값이 원본과 일치하지 않습니다. 기존 로컬 단어장은 유지됩니다."
        case .mirroredStoreAlreadyContainsData:
            "이미 iCloud mirrored 저장소에 단어장 데이터가 있어 자동 이관을 중단했습니다. 기존 iCloud 데이터 삭제를 막기 위한 보호 장치입니다."
        case .bootstrapAlreadyCompleted:
            "iCloud mirrored 저장소의 bootstrap이 이미 완료되어 Mac 로컬 데이터를 다시 seed하지 않았습니다."
        case .bootstrapUnsupportedOnIOS:
            "iPhone에서는 mirrored 저장소 bootstrap seed를 실행할 수 없습니다."
        case .bootstrapClaimDenied(let reason):
            "iCloud bootstrap claim이 승인되지 않아 seed를 중단했습니다: \(reason.rawValue)"
        case .bootstrapClaimMismatch:
            "iCloud bootstrap claim이 현재 snapshot과 일치하지 않아 seed를 중단했습니다."
        }
    }
}

@MainActor
enum VocabStoreMigrationService {
    static func claimAndMigrateLocalSnapshotToMirroredStore(
        localContext: ModelContext,
        mirroredContext: ModelContext,
        bootstrapToken: VocabBootstrapToken,
        existingClaimRequest: VocabBootstrapClaimRequest? = nil,
        claimService: any VocabBootstrapClaiming,
        mirroredStoreURL: URL,
        exportObserver: any VocabCloudExportObserving,
        exportTimeout: TimeInterval = 120,
        createCheckpoint: () throws -> VocabLocalStoreCheckpoint,
        persistClaimRequest: (VocabBootstrapClaimRequest) throws -> Void = { _ in },
        persistRecoveryManifest: (
            VocabLocalStoreCheckpoint,
            String,
            VocabBootstrapClaimRequest
        ) throws -> Void = { _, _, _ in },
        beforeImport: () throws -> Void = {}
    ) async throws -> VocabStoreMigrationReport {
#if os(iOS)
        throw VocabStoreMigrationError.bootstrapUnsupportedOnIOS
#else
        try localContext.save()
        var sourceSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: localContext)
        sourceSnapshot.syncMetadata?.bootstrapUUID = bootstrapToken.id
        let sourceFingerprint = try sourceSnapshot.contentFingerprint()
        sourceSnapshot.syncMetadata?.contentFingerprint = sourceFingerprint
        let checkpoint = try createCheckpoint()

        guard let payload = sourceSnapshot.syncMetadata else {
            throw VocabSyncSnapshotService.SnapshotValidationError.missingSyncMetadata
        }
        let generatedRequest = VocabBootstrapClaimRequest(
            claimID: bootstrapToken.claimID,
            requestID: bootstrapToken.requestID,
            ownerDeviceID: VocabDeviceIdentity.current,
            sourceFingerprint: sourceFingerprint,
            schemaVersion: payload.schemaVersion,
            createdAt: sourceSnapshot.exportedAt
        )
        let claimRequest: VocabBootstrapClaimRequest
        if let existingClaimRequest {
            guard existingClaimRequest.claimID == bootstrapToken.claimID,
                  existingClaimRequest.requestID == bootstrapToken.requestID,
                  existingClaimRequest.sourceFingerprint == sourceFingerprint,
                  existingClaimRequest.schemaVersion == payload.schemaVersion else {
                throw VocabStoreMigrationError.bootstrapClaimMismatch
            }
            claimRequest = existingClaimRequest
        } else {
            claimRequest = generatedRequest
        }
        try persistClaimRequest(claimRequest)
        try persistRecoveryManifest(checkpoint, sourceFingerprint, claimRequest)
        let claimResult = await claimService.claim(claimRequest)
        guard case .resumed(let approval) = claimResult else {
            guard case .denied(let reason) = claimResult else {
                throw VocabStoreMigrationError.bootstrapClaimDenied(.unknown)
            }
            throw VocabStoreMigrationError.bootstrapClaimDenied(reason)
        }
        guard approval.request == claimRequest,
              approval.recordName == VocabCloudKitBootstrapClaimService.recordName else {
            throw VocabStoreMigrationError.bootstrapClaimMismatch
        }

        if approval.wasCreated {
            let mirroredCounts = try contentCounts(context: mirroredContext)
            guard mirroredCounts.isEmpty else {
                throw VocabStoreMigrationError.mirroredStoreAlreadyContainsData(mirroredCounts)
            }
        }

        var state = approval.state
        if state == .completed {
            try verifyCompletedSnapshot(sourceSnapshot, context: mirroredContext)
            _ = try VocabCloudReconciler.reconcile(context: mirroredContext, syncMode: .cloudKitPrivate)
            return report(snapshot: sourceSnapshot, checkpoint: checkpoint, fingerprint: sourceFingerprint)
        }

        let exportExpectation = try exportObserver.beginWaiting(
            storeURL: mirroredStoreURL,
            requestID: claimRequest.requestID,
            fingerprint: sourceFingerprint,
            receiptMatches: { boundary in
                let receipts = try? mirroredContext.fetch(FetchDescriptor<BootstrapExportReceipt>())
                return receipts?.filter {
                    $0.requestID == boundary.requestID
                        && $0.fingerprint == boundary.fingerprint
                        && $0.storeUUID == boundary.storeUUID
                        && $0.transactionCommittedAt == boundary.transactionCommittedAt
                        && $0.probeGeneration == boundary.probeGeneration
                        && $0.nonce == boundary.nonce
                        && $0.state == "awaitingExport"
                }.count == 1
            }
        )

        var committedBoundary: VocabBootstrapExportBoundary?
        if state == .claimed {
            var insertedInitialReceipt = false
            try beforeImport()
            try VocabSyncSnapshotService.importSnapshotRecords(sourceSnapshot, context: mirroredContext)
            let existingReceipt = try matchingReceipt(
                context: mirroredContext,
                request: claimRequest,
                storeUUID: exportExpectation.storeIdentifier
            )
            if existingReceipt == nil {
                let committedAt = Date.now
                let receipt = BootstrapExportReceipt(
                    requestID: claimRequest.requestID,
                    fingerprint: sourceFingerprint,
                    storeUUID: exportExpectation.storeIdentifier,
                    transactionCommittedAt: committedAt
                )
                mirroredContext.insert(receipt)
                insertedInitialReceipt = true
            }
            try mirroredContext.save()
            if insertedInitialReceipt, let receipt = try matchingReceipt(
                context: mirroredContext,
                request: claimRequest,
                storeUUID: exportExpectation.storeIdentifier
            ), receipt.probeGeneration == 0 {
                committedBoundary = exportBoundary(receipt, exportNotBefore: .now)
            }
            try verifySeedingSnapshot(sourceSnapshot, context: mirroredContext)
            state = try await transition(
                claimService,
                request: claimRequest,
                from: .claimed,
                to: .seeding
            )
        }

        if state == .seeding {
            if committedBoundary == nil {
                try VocabSyncSnapshotService.importSnapshotRecords(
                    sourceSnapshot,
                    context: mirroredContext,
                    onlyInsertMissing: true
                )
                let existingReceipt = try matchingReceipt(
                    context: mirroredContext,
                    request: claimRequest,
                    storeUUID: exportExpectation.storeIdentifier
                )
                let receipt: BootstrapExportReceipt
                if let existingReceipt {
                    receipt = existingReceipt
                } else {
                    receipt = BootstrapExportReceipt(
                        requestID: claimRequest.requestID,
                        fingerprint: sourceFingerprint,
                        storeUUID: exportExpectation.storeIdentifier,
                        transactionCommittedAt: .distantPast,
                        probeGeneration: -1
                    )
                    mirroredContext.insert(receipt)
                }
                receipt.probeGeneration += 1
                receipt.nonce = UUID()
                receipt.state = "awaitingExport"
                receipt.transactionCommittedAt = .now
                try mirroredContext.save()
                committedBoundary = exportBoundary(receipt, exportNotBefore: .now)
            }
            guard let committedBoundary else {
                throw VocabStoreMigrationError.verificationMismatch
            }
            exportExpectation.setCommittedBoundary(committedBoundary)
            try verifySeedingSnapshot(sourceSnapshot, context: mirroredContext)
            try await exportExpectation.waitForResult(timeout: exportTimeout)
            guard let exportedReceipt = try matchingReceipt(
                context: mirroredContext,
                request: claimRequest,
                storeUUID: exportExpectation.storeIdentifier
            ), exportBoundary(
                exportedReceipt,
                exportNotBefore: committedBoundary.exportNotBefore
            ) == committedBoundary else {
                throw VocabStoreMigrationError.verificationMismatch
            }
            exportedReceipt.state = "exported"
            try mirroredContext.save()
            state = try await transition(claimService, request: claimRequest, from: .seeding, to: .completed)
        }

        guard state == .completed else {
            throw VocabStoreMigrationError.verificationMismatch
        }
        _ = try VocabCloudReconciler.reconcile(context: mirroredContext, syncMode: .cloudKitPrivate)
        return report(snapshot: sourceSnapshot, checkpoint: checkpoint, fingerprint: sourceFingerprint)
#endif
    }

#if !os(iOS)
    private static func transition(
        _ claimService: any VocabBootstrapClaiming,
        request: VocabBootstrapClaimRequest,
        from oldState: VocabBootstrapClaimState,
        to newState: VocabBootstrapClaimState
    ) async throws -> VocabBootstrapClaimState {
        let result = await claimService.transition(request, from: oldState, to: newState)
        guard case .resumed(let approval) = result else {
            guard case .denied(let reason) = result else {
                throw VocabStoreMigrationError.bootstrapClaimDenied(.unknown)
            }
            throw VocabStoreMigrationError.bootstrapClaimDenied(reason)
        }
        guard approval.request == request,
              approval.recordName == VocabCloudKitBootstrapClaimService.recordName,
              approval.state == newState else {
            throw VocabStoreMigrationError.bootstrapClaimMismatch
        }
        return approval.state
    }

    private static func report(
        snapshot: VocabSyncSnapshot,
        checkpoint: VocabLocalStoreCheckpoint,
        fingerprint: String
    ) -> VocabStoreMigrationReport {
        VocabStoreMigrationReport(
            checkpointDirectoryName: checkpoint.directory.lastPathComponent,
            wordCount: snapshot.words.count,
            dailySetCount: snapshot.dailySets.count,
            testSessionCount: snapshot.testSessions.count,
            attemptCount: snapshot.attempts.count,
            anonymousAggregateCount: snapshot.anonymousAggregates.count,
            memoryAidCacheCount: snapshot.memoryAidCaches.count,
            contentFingerprint: fingerprint
        )
    }

    private static func matchingReceipt(
        context: ModelContext,
        request: VocabBootstrapClaimRequest,
        storeUUID: String
    ) throws -> BootstrapExportReceipt? {
        let matches = try context.fetch(FetchDescriptor<BootstrapExportReceipt>()).filter {
            $0.requestID == request.requestID
                && $0.fingerprint == request.sourceFingerprint
                && $0.storeUUID == storeUUID
        }
        guard matches.count <= 1 else {
            throw VocabStoreMigrationError.verificationMismatch
        }
        return matches.first
    }

    private static func exportBoundary(
        _ receipt: BootstrapExportReceipt,
        exportNotBefore: Date
    ) -> VocabBootstrapExportBoundary {
        VocabBootstrapExportBoundary(
            requestID: receipt.requestID,
            fingerprint: receipt.fingerprint,
            storeUUID: receipt.storeUUID,
            transactionCommittedAt: receipt.transactionCommittedAt,
            exportNotBefore: exportNotBefore,
            probeGeneration: receipt.probeGeneration,
            nonce: receipt.nonce
        )
    }

    private static func verifySeedingSnapshot(
        _ source: VocabSyncSnapshot,
        context: ModelContext
    ) throws {
        try verifyExpectedIDs(source, context: context)
        let mirrored = try VocabSyncSnapshotService.exportSnapshot(context: context)
        guard try mirrored.contentFingerprint() == source.contentFingerprint() else {
            throw VocabStoreMigrationError.verificationMismatch
        }
    }

    private static func verifyCompletedSnapshot(
        _ source: VocabSyncSnapshot,
        context: ModelContext
    ) throws {
        try verifyExpectedIDs(source, context: context)
        let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
            .filter { $0.deletedAt == nil && $0.bootstrapUUID == source.syncMetadata?.bootstrapUUID }
        guard metadata.count == 1,
              metadata[0].contentFingerprint == source.syncMetadata?.contentFingerprint else {
            throw VocabStoreMigrationError.verificationMismatch
        }
    }

    private static func verifyExpectedIDs(
        _ source: VocabSyncSnapshot,
        context: ModelContext
    ) throws {
        func matches<Record>(
            _ records: [Record],
            ids: KeyPath<Record, UUID>,
            expected: Set<UUID>
        ) -> Bool {
            records.count == expected.count && Set(records.map { $0[keyPath: ids] }) == expected
        }

        guard matches(try context.fetch(FetchDescriptor<WordRecord>()), ids: \.id, expected: Set(source.words.map(\.id))),
              matches(try context.fetch(FetchDescriptor<MeaningRecord>()), ids: \.id, expected: Set(source.words.flatMap(\.meanings).map(\.id))),
              matches(try context.fetch(FetchDescriptor<DailySetRecord>()), ids: \.id, expected: Set(source.dailySets.map(\.id))),
              matches(try context.fetch(FetchDescriptor<DailySetItemRecord>()), ids: \.id, expected: Set(source.dailySets.flatMap(\.items).map(\.id))),
              matches(try context.fetch(FetchDescriptor<TestSessionRecord>()), ids: \.id, expected: Set(source.testSessions.map(\.id))),
              matches(try context.fetch(FetchDescriptor<AttemptRecord>()), ids: \.id, expected: Set(source.attempts.map(\.id))),
              matches(try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()), ids: \.id, expected: Set(source.anonymousAggregates.map(\.id))),
              matches(try context.fetch(FetchDescriptor<MemoryAidCacheRecord>()), ids: \.id, expected: Set(source.memoryAidCaches.map(\.id))),
              matches(try context.fetch(FetchDescriptor<RecordTombstone>()), ids: \.id, expected: Set(source.tombstones.map(\.id))) else {
            throw VocabStoreMigrationError.verificationMismatch
        }
    }
#endif

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
