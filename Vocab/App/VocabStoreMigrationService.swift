import Foundation
import SwiftData

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
            "iCloud 전환을 위해 복사한 단어장이 원본과 일치하지 않습니다. 기존 Mac 단어장은 유지됩니다."
        case .mirroredStoreAlreadyContainsData:
            "이미 iCloud에 단어장 데이터가 있어 자동 전환을 중단했습니다. 기존 iCloud 데이터 손실을 막기 위한 보호 장치입니다."
        case .bootstrapAlreadyCompleted:
            "iCloud 최초 동기화가 이미 완료되어 Mac 데이터를 다시 업로드하지 않았습니다."
        case .bootstrapUnsupportedOnIOS:
            "iPhone에서는 Mac의 기존 단어장을 최초 업로드할 수 없습니다."
        case .bootstrapClaimDenied(let reason):
            "iCloud 최초 동기화가 승인되지 않아 업로드를 중단했습니다. \(reason.userFacingReason)"
        case .bootstrapClaimMismatch:
            "iCloud 최초 동기화 정보가 현재 단어장과 일치하지 않아 업로드를 중단했습니다."
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
                // A failed fetch is "no match yet": never proof of export.
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
