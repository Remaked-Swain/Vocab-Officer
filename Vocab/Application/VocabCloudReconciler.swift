import Foundation
import SwiftData

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

    static func lightweightStatus(
        context: ModelContext,
        syncMode: VocabSyncMode
    ) throws -> VocabHydrationStatus {
        guard syncMode == .cloudKitPrivate else {
            return VocabHydrationStatus(
                state: .localOnly,
                counts: .zero,
                expectedBootstrapUUID: nil,
                message: nil
            )
        }
        let metadata = try context.fetch(FetchDescriptor<CloudBootstrapRecord>())
            .filter { $0.deletedAt == nil && $0.key == "primary" }
            .max { $0.createdAt < $1.createdAt }
        guard let metadata else {
            return VocabHydrationStatus(
                state: .awaitingBootstrapMetadata,
                counts: .zero,
                expectedBootstrapUUID: nil,
                message: "최초 동기화 정보가 아직 도착하지 않았습니다."
            )
        }
        guard metadata.schemaVersion == metadataSchemaVersion,
              !metadata.contentFingerprint.isEmpty else {
            return VocabHydrationStatus(
                state: .failed,
                counts: .zero,
                expectedBootstrapUUID: metadata.bootstrapUUID,
                message: "iCloud의 최초 동기화 정보가 손상되었거나 현재 앱과 호환되지 않습니다."
            )
        }
        return VocabHydrationStatus(
            state: metadata.lastReconciledAt == nil ? .reconciling : .ready,
            counts: .zero,
            expectedBootstrapUUID: metadata.bootstrapUUID,
            message: nil
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
                message: "최초 동기화 정보가 아직 도착하지 않았습니다."
            )
        }
        guard metadata.schemaVersion == metadataSchemaVersion, !metadata.contentFingerprint.isEmpty else {
            return VocabHydrationStatus(
                state: .failed,
                counts: actual,
                expectedBootstrapUUID: metadata.bootstrapUUID,
                message: "iCloud의 최초 동기화 정보가 손상되었거나 현재 앱과 호환되지 않습니다."
            )
        }
        guard actual.satisfies(metadata) else {
            return VocabHydrationStatus(
                state: .hydrating,
                counts: actual,
                expectedBootstrapUUID: metadata.bootstrapUUID,
                message: "필요한 단어장 데이터가 아직 모두 도착하지 않았습니다."
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
        func apply<T: PersistentModel & VocabSoftDeletableRecord>(
            _ type: T.Type,
            typeName: String
        ) throws {
            for record in try context.fetch(FetchDescriptor<T>()) {
                guard let date = deletion(typeName, record.id) else { continue }
                let appliesDeletion = record.deletedAt == nil || record.deletedAt! < date
                let scrubbed = record.scrubDeletedContent()
                guard appliesDeletion || scrubbed else { continue }
                record.deletedAt = max(record.deletedAt ?? .distantPast, date)
                record.updatedAt = max(record.updatedAt, date)
                didChange = true
            }
        }
        try apply(WordRecord.self, typeName: "WordRecord")
        try apply(MeaningRecord.self, typeName: "MeaningRecord")
        try apply(DailySetRecord.self, typeName: "DailySetRecord")
        try apply(DailySetItemRecord.self, typeName: "DailySetItemRecord")
        try apply(AttemptRecord.self, typeName: "AttemptRecord")
        try apply(ReviewStateRecord.self, typeName: "ReviewStateRecord")
        try apply(MemoryAidCacheRecord.self, typeName: "MemoryAidCacheRecord")
        let retiredWordIDs = Set(tombstones.lazy.filter { $0.recordType == "WordRecord" }.map(\.recordID))
        didChange = try sanitizeSessionReferences(
            context: context,
            retiredWordIDs: retiredWordIDs,
            now: now
        ) || didChange

        if syncMode == .cloudKitPrivate {
            let coordinator = LearningCoordinator(context: context, syncMode: syncMode)
            for word in try context.fetch(FetchDescriptor<WordRecord>()) where word.deletedAt == nil {
                let calculation = coordinator.expectedReviewState(
                    for: word,
                    attempts: (attemptsByWordID[word.id] ?? []).filter { $0.deletedAt == nil }
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
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    guard let target else { continue }
                    affectedWordIDs.insert(target.id)
                    didChange = true
                }
            case "MeaningRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    guard let target else { continue }
                    if let wordID = target.word?.id { affectedWordIDs.insert(wordID) }
                    didChange = true
                }
            case "DailySetRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<DailySetRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    didChange = true
                }
            case "DailySetItemRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<DailySetItemRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    didChange = true
                }
            case "AttemptRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    guard let target else { continue }
                    if let wordID = target.word?.id { affectedWordIDs.insert(wordID) }
                    didChange = true
                }
            case "ReviewStateRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<ReviewStateRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    guard let target else { continue }
                    if let wordID = target.word?.id { affectedWordIDs.insert(wordID) }
                    didChange = true
                }
            case "MemoryAidCacheRecord":
                let recordID = tombstone.recordID
                let target = try context.fetch(FetchDescriptor<MemoryAidCacheRecord>(predicate: #Predicate { $0.id == recordID })).first
                if applyDeletionTombstone(target, at: tombstone.deletedAt) {
                    guard let target else { continue }
                    affectedWordIDs.insert(target.wordID)
                    didChange = true
                }
            default:
                continue
            }
        }
        let retiredWordIDs = Set(try context.fetch(FetchDescriptor<RecordTombstone>())
            .lazy.filter { $0.recordType == "WordRecord" }.map(\.recordID))
        didChange = try sanitizeSessionReferences(
            context: context,
            retiredWordIDs: retiredWordIDs,
            now: now
        ) || didChange

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

    static func sanitizeSessionReferences(
        context: ModelContext,
        retiredWordIDs: Set<UUID>,
        now: Date
    ) throws -> Bool {
        guard !retiredWordIDs.isEmpty else { return false }
        var changed = false
        for session in try context.fetch(FetchDescriptor<TestSessionRecord>())
            where !retiredWordIDs.isDisjoint(with: session.wordIDs) {
            session.wordIDs.removeAll(where: retiredWordIDs.contains)
            session.updatedAt = max(session.updatedAt, now)
            changed = true
        }
        return changed
    }

    private static func applyDeletionTombstone<T: VocabSoftDeletableRecord>(
        _ record: T?,
        at date: Date
    ) -> Bool {
        guard let record else { return false }
        let appliesDeletion = record.deletedAt == nil || record.deletedAt! < date
        let scrubbed = record.scrubDeletedContent()
        guard appliesDeletion || scrubbed else { return false }
        record.deletedAt = max(record.deletedAt ?? .distantPast, date)
        record.updatedAt = max(record.updatedAt, date)
        return true
    }

}
