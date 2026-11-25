import Foundation
import SwiftData

@ModelActor
actor VocabMasteryCleanupWorker {
    func run(
        syncMode: VocabSyncMode,
        now: Date = .now
    ) throws -> LearningCoordinator.MasteryCleanupResult {
        try LearningCoordinator(
            context: modelContext,
            syncMode: syncMode
        ).normalizeAndRetireMasteredWords(now: now)
    }
}

@ModelActor
actor VocabCloudReconciliationWorker {
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
        try await applyDeletionBatches(AttemptRecord.self, typeName: "AttemptRecord", winningDeletion: winningDeletion)
        try await applyDeletionBatches(ReviewStateRecord.self, typeName: "ReviewStateRecord", winningDeletion: winningDeletion)
        try await applyDeletionBatches(MemoryAidCacheRecord.self, typeName: "MemoryAidCacheRecord", winningDeletion: winningDeletion)
        let retiredWordIDs = Set(winningDeletion.keys.compactMap { key -> UUID? in
            guard key.hasPrefix("WordRecord:") else { return nil }
            return UUID(uuidString: String(key.dropFirst("WordRecord:".count)))
        })
        if try VocabCloudReconciler.sanitizeSessionReferences(
            context: modelContext,
            retiredWordIDs: retiredWordIDs,
            now: now
        ) {
            try modelContext.save()
        }

        if syncMode == .cloudKitPrivate {
            let coordinator = LearningCoordinator(context: modelContext, syncMode: syncMode)
            try await forEachBatch(WordRecord.self) { words in
                var changed = false
                for word in words where word.deletedAt == nil {
                    let calculation = coordinator.expectedReviewState(
                        for: word,
                        attempts: (attemptsByWordID[word.id] ?? []).filter { $0.deletedAt == nil }
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
        var attemptWordIDs: [UUID: UUID] = [:]
        var reviewWordIDs: [UUID: UUID] = [:]
        var memoryAidWordIDs: [UUID: UUID] = [:]

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
                if let wordID = record.word?.id { attemptWordIDs[record.id] = wordID }
            }
        }
        try await forEachBatch(ReviewStateRecord.self) { batch in
            for record in batch {
                if let wordID = record.word?.id { reviewWordIDs[record.id] = wordID }
            }
        }
        try await forEachBatch(MemoryAidCacheRecord.self) { batch in
            for record in batch { memoryAidWordIDs[record.id] = record.wordID }
        }
        try await forEachBatch(RecordTombstone.self) { batch in
            for record in batch {
                let wordID: UUID?
                switch record.recordType {
                case "WordRecord": wordID = record.recordID
                case "MeaningRecord": wordID = meaningWordIDs[record.recordID]
                case "DailySetItemRecord": wordID = itemWordIDs[record.recordID]
                case "AttemptRecord": wordID = attemptWordIDs[record.recordID]
                case "ReviewStateRecord": wordID = reviewWordIDs[record.recordID]
                case "MemoryAidCacheRecord": wordID = memoryAidWordIDs[record.recordID]
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

    /// Records a completed full audit: a receipt for the audited content, the
    /// mutation lease bound to it, then the runtime audit timestamp.
    private func recordCompletedFullAudit(
        now: Date,
        auditReceiptURL: URL?,
        validationEpoch: UUID,
        runtimeStateStore: VocabSyncRuntimeStateStore
    ) async throws {
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
            validationEpoch: validationEpoch
        )
        await runtimeStateStore.markFullAuditCompleted(at: now)
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
        let prefix = "\(typeName):"
        let targetIDs = winningDeletion.keys.compactMap { key -> UUID? in
            guard key.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(key.dropFirst(prefix.count)))
        }.sorted { $0.uuidString < $1.uuidString }
        guard !targetIDs.isEmpty else { return }

        for start in stride(from: 0, to: targetIDs.count, by: auditBatchSize) {
            try Task.checkCancellation()
            let end = min(start + auditBatchSize, targetIDs.count)
            let batchIDs = Set(targetIDs[start..<end])
            let descriptor = FetchDescriptor<T>(predicate: #Predicate { batchIDs.contains($0.id) })
            var changed = false
            for record in try modelContext.fetch(descriptor) {
                let key = "\(typeName):\(record.id.uuidString)"
                guard let date = winningDeletion[key] else { continue }
                let appliesDeletion = record.deletedAt == nil || record.deletedAt! < date
                let scrubbed = record.scrubDeletedContent()
                guard appliesDeletion || scrubbed else { continue }
                record.deletedAt = max(record.deletedAt ?? .distantPast, date)
                record.updatedAt = max(record.updatedAt, date)
                changed = true
            }
            if changed { try modelContext.save() }
            await Task.yield()
        }
    }

    func auditAll(
        syncMode: VocabSyncMode,
        now: Date = .now,
        indexURL: URL? = nil,
        auditReceiptURL: URL? = nil,
        historyCursorURL: URL? = nil
    ) async throws -> VocabHydrationStatus {
        let validationEpoch = syncMode == .cloudKitPrivate
            ? VocabMutationAuthorityRuntime.prepareForMaintenanceAudit(
                container: modelContainer,
                context: modelContext
            )
            : nil
        _ = await VocabSyncWorkBarrier.shared.beginReconciliation()
        do {
            // Read before the audit, so changes committed during it are
            // reconciled again from the saved cursor.
            let auditedHistoryToken = syncMode == .cloudKitPrivate
                ? try VocabImportHistoryReader.latestToken(context: modelContext)
                : nil
            let result = try await reconcileFullCooperatively(syncMode: syncMode, now: now)
            if syncMode == .cloudKitPrivate {
                let index = try await fullImportIndexCooperatively()
                try VocabImportedChangeIndexStore.save(
                    index,
                    to: try indexURL ?? VocabImportedChangeIndexStore.defaultURL()
                )
                try await recordCompletedFullAudit(
                    now: now,
                    auditReceiptURL: auditReceiptURL,
                    validationEpoch: validationEpoch!,
                    runtimeStateStore: .shared
                )
                if let auditedHistoryToken {
                    try VocabImportHistoryCursorStore.save(
                        auditedHistoryToken,
                        to: try historyCursorURL ?? VocabImportHistoryCursorStore.defaultURL()
                    )
                }
            }
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            return result
        } catch is CancellationError {
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            throw CancellationError()
        } catch {
            if syncMode == .cloudKitPrivate,
               error is VocabCloudReconciliationError {
                let resolvedReceiptURL = try? auditReceiptURL ?? VocabFullAuditReceiptStore.defaultURL()
                VocabMutationAuthorityRuntime.invalidatePersistedEvidence(receiptURL: resolvedReceiptURL)
            }
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            throw error
        }
    }

    func reconcileImportedChanges(
        syncMode: VocabSyncMode,
        now: Date = .now,
        indexURL: URL? = nil,
        auditReceiptURL: URL? = nil,
        historyCursorURL: URL? = nil,
        source: VocabImportedChangeSource = .cloudImportWithoutIdentifiers,
        allowsFullAudit: Bool = true,
        runtimeStateStore: VocabSyncRuntimeStateStore = .shared
    ) async throws -> VocabHydrationStatus {
        _ = await VocabSyncWorkBarrier.shared.beginReconciliation()
        do {
        guard syncMode == .cloudKitPrivate else {
            let result = try VocabCloudReconciler.reconcile(context: modelContext, syncMode: syncMode, now: now)
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            return result
        }
        let resolvedURL = try indexURL ?? VocabImportedChangeIndexStore.defaultURL()
        let previous = try? VocabImportedChangeIndexStore.load(from: resolvedURL)
        let resolvedCursorURL = try historyCursorURL ?? VocabImportHistoryCursorStore.defaultURL()
        // Read before any reconciliation write, so a change committed while
        // this pass runs lies after the cursor it saves.
        let history: VocabImportHistoryChanges
        switch source {
        case .persistentHistory:
            history = try VocabImportHistoryReader.changes(
                since: VocabImportHistoryCursorStore.load(from: resolvedCursorURL),
                context: modelContext
            )
        case .cloudImportWithoutIdentifiers:
            history = VocabImportHistoryChanges(
                records: [],
                requiresFullAudit: true,
                latestToken: try VocabImportHistoryReader.latestToken(context: modelContext)
            )
        }
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
        if !history.requiresFullAudit,
           let previous,
           previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
           previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion {
            changes = try VocabImportedChangeDiscovery.discover(
                context: modelContext,
                previous: previous,
                changedRecords: history.records
            )
        } else {
            changes = auditFallback
        }
        let needsAudit = history.requiresFullAudit || changes.requiresFullAudit
        let result: VocabHydrationStatus
        if needsAudit {
            guard allowsFullAudit else {
                await runtimeStateStore.requestFullAudit()
                let status = try VocabCloudReconciler.lightweightStatus(
                    context: modelContext,
                    syncMode: syncMode
                )
                await VocabSyncWorkBarrier.shared.finishReconciliation()
                return status
            }
            let validationEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
            result = try await reconcileFullCooperatively(syncMode: syncMode, now: now)
            let auditedIndex = try await fullImportIndexCooperatively()
            try await recordCompletedFullAudit(
                now: now,
                auditReceiptURL: auditReceiptURL,
                validationEpoch: validationEpoch,
                runtimeStateStore: runtimeStateStore
            )
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
        if let latestToken = history.latestToken {
            try VocabImportHistoryCursorStore.save(latestToken, to: resolvedCursorURL)
        }
        await VocabSyncWorkBarrier.shared.finishReconciliation()
        return result
        } catch {
            await VocabSyncWorkBarrier.shared.finishReconciliation()
            throw error
        }
    }
}

/// A `@ModelActor` serializes on the thread that creates it, so creating a
/// worker from the main actor would run its store work on the main thread.
/// The `@concurrent` factories run the initializer on the global executor.
enum VocabCloudReconciliationWorkerFactory {
    @concurrent
    static func make(modelContainer: ModelContainer) async -> VocabCloudReconciliationWorker {
        VocabCloudReconciliationWorker(modelContainer: modelContainer)
    }
}

enum VocabMasteryCleanupWorkerFactory {
    @concurrent
    static func make(modelContainer: ModelContainer) async -> VocabMasteryCleanupWorker {
        VocabMasteryCleanupWorker(modelContainer: modelContainer)
    }
}
