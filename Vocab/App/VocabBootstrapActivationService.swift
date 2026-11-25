import Foundation
import SwiftData

#if os(macOS)
struct VocabBootstrapActivationOutcome: Equatable {
    enum Disposition: Equatable {
        case noAction
        case restartRequired
    }

    let disposition: Disposition
    let message: String
}

enum VocabBootstrapActivationError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let message): message
        }
    }
}

@MainActor
enum VocabBootstrapActivationService {
    static func activate(
        localContext: ModelContext,
        allowsNewClaim: Bool,
        claimService: VocabCloudKitBootstrapClaimService = VocabCloudKitBootstrapClaimService()
    ) async throws -> VocabBootstrapActivationOutcome {
        let status = await claimService.fixedClaimStatus()
        let credential = try VocabBootstrapTokenStore.load()
        let localSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: localContext)
        let fingerprint = try localSnapshot.contentFingerprint()
        let manifest = try VocabBootstrapRecoveryManifestStore.load()
        if let outcome = try await recoverLegacySeedingIfVerified(
            localFingerprint: fingerprint,
            credential: credential,
            serverStatus: status,
            claimService: claimService
        ) {
            return outcome
        }
        let storedRequest = recoveredStoredRequest(
            credential: credential,
            serverStatus: status,
            currentCanonicalFingerprint: fingerprint
        )
        let legacyRecoveryDiagnostic = legacyRecoveryDiagnostic(
            credential: credential,
            serverStatus: status,
            currentCanonicalFingerprint: fingerprint
        )
        let receiptIsValid: Bool
        if storedRequest != nil {
            receiptIsValid = true
        } else {
            receiptIsValid = try validReceiptExists(status: status, credential: credential)
        }
        let decision = VocabBootstrapResumePolicy.decide(
            serverStatus: status,
            storedRequest: storedRequest,
            currentCanonicalFingerprint: fingerprint,
            checkpointManifest: manifest,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            receiptIsValid: receiptIsValid
        )

        let token: VocabBootstrapToken
        let existingClaimRequest: VocabBootstrapClaimRequest?
        switch decision {
        case .hydrateCompleted:
            enableMirroredMode()
            return VocabBootstrapActivationOutcome(
                disposition: .restartRequired,
                message: "Mac 최초 동기화 완료를 확인했습니다. Vocab을 다시 열면 iCloud 단어장을 사용합니다."
            )
        case .createNew where !allowsNewClaim:
            return VocabBootstrapActivationOutcome(
                disposition: .noAction,
                message: "기존 최초 동기화 작업이 없어 자동 전환하지 않았습니다. 최초 전환은 설정에서 직접 승인해야 합니다."
            )
        case .createNew:
            token = try VocabBootstrapTokenStore.createAndPersist().token
            existingClaimRequest = nil
        case .resume(let request), .recoverExisting(let request):
            try VocabBootstrapTokenStore.persist(request)
            token = VocabBootstrapToken(claimID: request.claimID, requestID: request.requestID)
            existingClaimRequest = request
        case .blocked(let message):
            throw VocabBootstrapActivationError.blocked("\(message) 자동 진단: \(legacyRecoveryDiagnostic)")
        }

        let mirroredContainer = try VocabModelContainerFactory.makeContainer(syncMode: .cloudKitPrivate)
        defer { withExtendedLifetime(mirroredContainer) {} }
        let report = try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
            localContext: localContext,
            mirroredContext: ModelContext(mirroredContainer),
            bootstrapToken: token,
            existingClaimRequest: existingClaimRequest,
            claimService: claimService,
            mirroredStoreURL: try VocabModelContainerFactory.mirroredStoreURL(),
            exportObserver: VocabPersistentCloudKitExportObserver(),
            createCheckpoint: {
                let checkpoint = try VocabLocalStoreCheckpointStore.createDefaultStoreCheckpoint()
                _ = try VocabLocalStoreCheckpointStore.rehearseCheckpoint(checkpoint)
                return checkpoint
            },
            persistClaimRequest: { request in
                try VocabBootstrapTokenStore.persist(request)
            },
            persistRecoveryManifest: { checkpoint, fingerprint, request in
                try VocabBootstrapRecoveryManifestStore.save(
                    checkpoint: checkpoint,
                    fingerprint: fingerprint,
                    request: request
                )
            }
        )
        enableMirroredMode()
        return VocabBootstrapActivationOutcome(
            disposition: .restartRequired,
            message: "\(report.wordCount)개 단어와 \(report.dailySetCount)개 세트의 iCloud 업로드를 확인했습니다. Vocab을 다시 열면 자동 동기화가 시작됩니다."
        )
    }

    private static func recoverLegacySeedingIfVerified(
        localFingerprint: String,
        credential: VocabBootstrapTokenStore.Credential?,
        serverStatus: VocabBootstrapServerClaimStatus,
        claimService: VocabCloudKitBootstrapClaimService
    ) async throws -> VocabBootstrapActivationOutcome? {
        guard let credential, credential.request == nil,
              case .available(let claim) = serverStatus,
              claim.state == .claimed || claim.state == .seeding,
              credential.token.claimID == claim.request.claimID,
              credential.token.requestID == claim.request.requestID,
              credential.originDeviceID == claim.request.ownerDeviceID,
              claim.request.schemaVersion == VocabCloudReconciler.metadataSchemaVersion,
              claim.request.sourceFingerprint != localFingerprint else {
            return nil
        }

        let mirroredContainer = try VocabModelContainerFactory.makeContainer(syncMode: .cloudKitPrivate)
        defer { withExtendedLifetime(mirroredContainer) {} }
        let mirroredContext = ModelContext(mirroredContainer)
        let mirroredSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: mirroredContext)
        let mirroredFingerprint = try mirroredSnapshot.contentFingerprint()
        let metadata = mirroredSnapshot.syncMetadata
        let actualCounts = try VocabCloudReconciler.counts(context: mirroredContext)
        guard let metadata,
              legacySnapshotsMatch(
                localFingerprint: localFingerprint,
                mirroredFingerprint: mirroredFingerprint,
                metadataFingerprint: metadata.contentFingerprint,
                expectedCounts: metadata.expectedCounts,
                actualCounts: actualCounts
              ),
              metadata.bootstrapUUID == claim.request.requestID,
              metadata.schemaVersion == claim.request.schemaVersion,
              metadata.originDeviceID == claim.request.ownerDeviceID else {
            return nil
        }
        let hydration = try VocabCloudReconciler.hydrationStatus(
            context: mirroredContext,
            syncMode: .cloudKitPrivate
        )
        guard hydration.state == .ready || hydration.state == .reconciling else { return nil }

        let checkpoint = try VocabLocalStoreCheckpointStore.createDefaultStoreCheckpoint()
        _ = try VocabLocalStoreCheckpointStore.rehearseCheckpoint(checkpoint)
        try VocabBootstrapTokenStore.persist(claim.request)
        try VocabBootstrapRecoveryManifestStore.save(
            checkpoint: checkpoint,
            fingerprint: localFingerprint,
            request: claim.request
        )

        if claim.state == .claimed {
            let seedingTransition = await claimService.transition(
                claim.request,
                from: .claimed,
                to: .seeding
            )
            guard case .resumed(let approval) = seedingTransition,
                  approval.request == claim.request,
                  approval.state == .seeding else {
                throw VocabBootstrapActivationError.blocked("이전 방식의 최초 업로드 전환을 확인하지 못했습니다.")
            }
        }

        let expectation = try VocabPersistentCloudKitExportObserver().beginWaiting(
            storeURL: try VocabModelContainerFactory.mirroredStoreURL(),
            requestID: claim.request.requestID,
            fingerprint: claim.request.sourceFingerprint,
            receiptMatches: { boundary in
                // A failed fetch is "no match yet": never proof of export.
                let receipts = try? mirroredContext.fetch(FetchDescriptor<BootstrapExportReceipt>())
                return receipts?.contains {
                    $0.requestID == boundary.requestID
                        && $0.fingerprint == boundary.fingerprint
                        && $0.storeUUID == boundary.storeUUID
                        && $0.transactionCommittedAt == boundary.transactionCommittedAt
                        && $0.probeGeneration == boundary.probeGeneration
                        && $0.nonce == boundary.nonce
                        && $0.state == "awaitingExport"
                } == true
            }
        )
        let exportNotBefore = Date.now
        let receipt = BootstrapExportReceipt(
            requestID: claim.request.requestID,
            fingerprint: claim.request.sourceFingerprint,
            storeUUID: expectation.storeIdentifier,
            transactionCommittedAt: exportNotBefore
        )
        mirroredContext.insert(receipt)
        try mirroredContext.save()
        let boundary = VocabBootstrapExportBoundary(
            requestID: receipt.requestID,
            fingerprint: receipt.fingerprint,
            storeUUID: receipt.storeUUID,
            transactionCommittedAt: receipt.transactionCommittedAt,
            exportNotBefore: exportNotBefore,
            probeGeneration: receipt.probeGeneration,
            nonce: receipt.nonce
        )
        expectation.setCommittedBoundary(boundary)
        try await expectation.waitForResult(timeout: 120)
        receipt.state = "exported"
        try mirroredContext.save()

        let transition = await claimService.transition(
            claim.request,
            from: .seeding,
            to: .completed
        )
        guard case .resumed(let approval) = transition,
              approval.request == claim.request,
              approval.state == .completed else {
            throw VocabBootstrapActivationError.blocked("이전 방식의 최초 업로드 후 서버 완료 상태를 확인하지 못했습니다.")
        }
        _ = try VocabCloudReconciler.reconcile(context: mirroredContext, syncMode: .cloudKitPrivate)
        enableMirroredMode()
        return VocabBootstrapActivationOutcome(
            disposition: .restartRequired,
            message: "이전 검증 규칙으로 중단된 최초 동기화를 Mac과 iCloud 데이터 일치 확인 후 완료했습니다. Vocab을 다시 열면 자동 동기화가 시작됩니다."
        )
    }

    static func legacySnapshotsMatch(
        localFingerprint: String,
        mirroredFingerprint: String,
        metadataFingerprint: String,
        expectedCounts: VocabEntityCounts,
        actualCounts: VocabEntityCounts
    ) -> Bool {
        localFingerprint == mirroredFingerprint
            && metadataFingerprint == mirroredFingerprint
            && expectedCounts == actualCounts
    }

    static func recoveredStoredRequest(
        credential: VocabBootstrapTokenStore.Credential?,
        serverStatus: VocabBootstrapServerClaimStatus,
        currentCanonicalFingerprint: String
    ) -> VocabBootstrapClaimRequest? {
        guard let credential else { return nil }
        if let request = credential.request { return request }
        guard case .available(let serverClaim) = serverStatus,
              credential.token.claimID == serverClaim.request.claimID,
              credential.token.requestID == serverClaim.request.requestID,
              credential.originDeviceID == serverClaim.request.ownerDeviceID,
              currentCanonicalFingerprint == serverClaim.request.sourceFingerprint,
              serverClaim.request.schemaVersion == VocabCloudReconciler.metadataSchemaVersion else {
            return nil
        }
        return serverClaim.request
    }

    static func legacyRecoveryDiagnostic(
        credential: VocabBootstrapTokenStore.Credential?,
        serverStatus: VocabBootstrapServerClaimStatus,
        currentCanonicalFingerprint: String
    ) -> String {
        guard let credential else { return "이 Mac에 이전 작업의 보안 정보가 없습니다." }
        if credential.request != nil { return "이 Mac에 이전 작업을 재개할 수 있는 보안 정보가 있습니다." }
        guard case .available(let serverClaim) = serverStatus else { return "iCloud의 이전 작업 상태를 읽지 못했습니다." }
        guard credential.token.claimID == serverClaim.request.claimID,
              credential.token.requestID == serverClaim.request.requestID else {
            return "이 Mac의 보안 정보와 iCloud 작업 정보가 다릅니다."
        }
        guard credential.originDeviceID == serverClaim.request.ownerDeviceID else {
            return "최초 동기화를 시작한 Mac과 현재 보안 정보가 다릅니다."
        }
        guard serverClaim.request.schemaVersion == VocabCloudReconciler.metadataSchemaVersion else {
            return "이전 작업 정보가 현재 앱과 호환되지 않습니다."
        }
        guard currentCanonicalFingerprint == serverClaim.request.sourceFingerprint else {
            return "현재 Mac 단어장과 iCloud의 이전 작업 대상이 다릅니다."
        }
        return "이전 작업을 안전하게 재개할 조건이 모두 일치합니다."
    }

    private static func validReceiptExists(
        status: VocabBootstrapServerClaimStatus,
        credential: VocabBootstrapTokenStore.Credential?
    ) throws -> Bool {
        guard case .available(let claim) = status, credential?.request == nil else {
            return credential?.request != nil
        }
        let mirrored = try VocabModelContainerFactory.makeContainer(syncMode: .cloudKitPrivate)
        defer { withExtendedLifetime(mirrored) {} }
        let receipts = try ModelContext(mirrored).fetch(FetchDescriptor<BootstrapExportReceipt>())
        return receipts.contains {
            $0.requestID == claim.request.requestID
                && $0.fingerprint == claim.request.sourceFingerprint
                && !$0.storeUUID.isEmpty
                && $0.transactionCommittedAt > .distantPast
                && ($0.state == "awaitingExport" || $0.state == "exported")
        }
    }

    private static func enableMirroredMode() {
        UserDefaults.standard.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)
    }
}
#endif
