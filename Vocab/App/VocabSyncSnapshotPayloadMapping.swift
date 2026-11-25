import Foundation

/// Maps persisted records to their snapshot payloads. Pure value mapping:
/// no fetches, saves or validation.
extension VocabSyncSnapshotService {
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
            questionFormatRaw: session.questionFormatRaw,
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
            questionFormatRaw: attempt.questionFormatRaw,
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
}
