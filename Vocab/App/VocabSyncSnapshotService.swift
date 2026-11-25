import Foundation
import SwiftData

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
        // Each importer fetches its own record type before inserting it; no
        // importer inserts another importer's type, so fetch order is free.
        if includeSyncMetadata {
            try importSyncMetadata(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
        }
        let wordsByID = try importWords(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
        try importDailySets(snapshot, wordsByID: wordsByID, context: context, onlyInsertMissing: onlyInsertMissing)
        try importTestSessions(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
        try importAttempts(snapshot, wordsByID: wordsByID, context: context, onlyInsertMissing: onlyInsertMissing)
        try importAnonymousAggregates(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
        try importMemoryAidCaches(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
        try importTombstones(snapshot, context: context, onlyInsertMissing: onlyInsertMissing)
    }

    nonisolated private static func importSyncMetadata(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        if let payload = snapshot.syncMetadata {
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
    }

    /// Imports words with their meanings and review states; returns every
    /// imported word by ID for the importers that link to words.
    nonisolated private static func importWords(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws -> [UUID: WordRecord] {
        let existingWords = indexByID(try context.fetch(FetchDescriptor<WordRecord>()), id: \.id)
        let existingMeanings = indexByID(try context.fetch(FetchDescriptor<MeaningRecord>()), id: \.id)
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
        return wordsByID
    }

    nonisolated private static func importDailySets(
        _ snapshot: VocabSyncSnapshot,
        wordsByID: [UUID: WordRecord],
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingSets = indexByID(try context.fetch(FetchDescriptor<DailySetRecord>()), id: \.id)
        let existingItems = indexByID(try context.fetch(FetchDescriptor<DailySetItemRecord>()), id: \.id)
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
    }

    nonisolated private static func importTestSessions(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingSessions = indexByID(try context.fetch(FetchDescriptor<TestSessionRecord>()), id: \.id)
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
                session.questionFormatRaw = payload.questionFormatRaw
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
    }

    nonisolated private static func importAttempts(
        _ snapshot: VocabSyncSnapshot,
        wordsByID: [UUID: WordRecord],
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingAttempts = indexByID(try context.fetch(FetchDescriptor<AttemptRecord>()), id: \.id)
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
                attempt.questionFormatRaw = payload.questionFormatRaw
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
    }

    nonisolated private static func importAnonymousAggregates(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingAggregates = indexByID(try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()), id: \.id)
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
    }

    nonisolated private static func importMemoryAidCaches(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingCaches = indexByID(try context.fetch(FetchDescriptor<MemoryAidCacheRecord>()), id: \.id)
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
    }

    nonisolated private static func importTombstones(
        _ snapshot: VocabSyncSnapshot,
        context: ModelContext,
        onlyInsertMissing: Bool
    ) throws {
        let existingTombstones = indexByID(try context.fetch(FetchDescriptor<RecordTombstone>()), id: \.id)
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
            if attempt.deletedAt == nil, !sessionIDs.contains(attempt.sessionID) {
                throw SnapshotValidationError.missingSessionForAttempt(attempt.sessionID)
            }
            if attempt.deletedAt == nil,
               let wordID = attempt.wordID,
               !wordIDs.contains(wordID) {
                throw SnapshotValidationError.missingWordForAttempt(wordID)
            }
            if attempt.deletedAt == nil,
               let meaningID = attempt.matchedMeaningID,
               !meaningIDs.contains(meaningID) {
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
