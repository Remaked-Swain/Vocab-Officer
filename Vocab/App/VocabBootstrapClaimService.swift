import CloudKit
import CoreData
import Foundation

enum VocabBootstrapClaimState: String, Equatable {
    case claimed
    case seeding
    case completed
}

struct VocabBootstrapClaimRequest: Equatable {
    let claimID: UUID
    let requestID: UUID
    let ownerDeviceID: String
    let sourceFingerprint: String
    let schemaVersion: Int
    let createdAt: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.claimID == rhs.claimID
            && lhs.requestID == rhs.requestID
            && lhs.ownerDeviceID == rhs.ownerDeviceID
            && lhs.sourceFingerprint == rhs.sourceFingerprint
            && lhs.schemaVersion == rhs.schemaVersion
    }
}

struct VocabBootstrapClaimApproval: Equatable {
    let request: VocabBootstrapClaimRequest
    let state: VocabBootstrapClaimState
    let recordName: String
    let wasCreated: Bool
}

enum VocabBootstrapClaimDenial: String, Equatable {
    case existing
    case competing
    case foreign
    case timeout
    case unknown
}

enum VocabBootstrapClaimResult: Equatable {
    case resumed(VocabBootstrapClaimApproval)
    case denied(VocabBootstrapClaimDenial)
}

enum VocabBootstrapServerClaimStatus: Equatable {
    case missing
    case available(VocabBootstrapClaimState)
    case unavailable(String)
}

protocol VocabBootstrapClaimStatusReading {
    func fixedClaimStatus() async -> VocabBootstrapServerClaimStatus
}

protocol VocabBootstrapClaiming {
    func claim(_ request: VocabBootstrapClaimRequest) async -> VocabBootstrapClaimResult
    func transition(
        _ request: VocabBootstrapClaimRequest,
        from expectedState: VocabBootstrapClaimState,
        to newState: VocabBootstrapClaimState
    ) async -> VocabBootstrapClaimResult
}

extension VocabBootstrapClaiming {
    func approval(
        for request: VocabBootstrapClaimRequest,
        state: VocabBootstrapClaimState
    ) -> VocabBootstrapClaimResult {
        .resumed(VocabBootstrapClaimApproval(
            request: request,
            state: state,
            recordName: VocabCloudKitBootstrapClaimService.recordName,
            wasCreated: false
        ))
    }
}

final class VocabCloudKitBootstrapClaimService: VocabBootstrapClaiming, VocabBootstrapClaimStatusReading {
    static let recordType = "VocabBootstrapClaim"
    static let recordName = "VocabBootstrapClaim-v1"

    private enum Field {
        static let claimID = "claimID"
        static let requestID = "requestID"
        static let ownerDeviceID = "ownerDeviceID"
        static let sourceFingerprint = "sourceFingerprint"
        static let schemaVersion = "schemaVersion"
        static let state = "state"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"
    }

    private let database: CKDatabase
    private let timeoutNanoseconds: UInt64

    init(
        container: CKContainer = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier),
        timeout: TimeInterval = 15
    ) {
        database = container.privateCloudDatabase
        timeoutNanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
    }

    func claim(_ request: VocabBootstrapClaimRequest) async -> VocabBootstrapClaimResult {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        switch await fetchRecord(recordID) {
        case .found(let record):
            return result(for: record, matching: request)
        case .unknown:
            return .denied(.unknown)
        case .missing:
            break
        }

        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(request, state: .claimed, to: record, now: request.createdAt)
        return await save(
            record,
            request: request,
            successState: .claimed,
            competingDenial: .competing,
            wasCreated: true
        )
    }

    func fixedClaimStatus() async -> VocabBootstrapServerClaimStatus {
        switch await fetchRecord(CKRecord.ID(recordName: Self.recordName)) {
        case .missing:
            return .missing
        case .unknown:
            return .unavailable("bootstrap claim을 조회하지 못했습니다. 네트워크와 iCloud 상태를 확인하세요.")
        case .found(let record):
            guard let state = claimState(record) else {
                return .unavailable("bootstrap claim 상태를 해석하지 못했습니다.")
            }
            return .available(state)
        }
    }

    func transition(
        _ request: VocabBootstrapClaimRequest,
        from expectedState: VocabBootstrapClaimState,
        to newState: VocabBootstrapClaimState
    ) async -> VocabBootstrapClaimResult {
        guard isLegalTransition(from: expectedState, to: newState) else {
            return .denied(.unknown)
        }
        let recordID = CKRecord.ID(recordName: Self.recordName)
        guard case .found(let record) = await fetchRecord(recordID) else {
            return .denied(.unknown)
        }
        guard recordMatches(record, request: request) else {
            return .denied(.foreign)
        }
        guard let currentState = claimState(record) else {
            return .denied(.unknown)
        }
        if currentState == newState {
            return approval(for: request, state: newState)
        }
        guard currentState == expectedState else {
            return .denied(.competing)
        }

        record[Field.state] = newState.rawValue as CKRecordValue
        record[Field.updatedAt] = Date.now as CKRecordValue
        return await save(
            record,
            request: request,
            successState: newState,
            competingDenial: .competing,
            wasCreated: false
        )
    }

    private func save(
        _ record: CKRecord,
        request: VocabBootstrapClaimRequest,
        successState: VocabBootstrapClaimState,
        competingDenial: VocabBootstrapClaimDenial,
        wasCreated: Bool
    ) async -> VocabBootstrapClaimResult {
        let operationResult = await withTaskGroup(of: ModifyResult.self) { group in
            group.addTask { [database] in
                await Self.modifyAtomically(record, in: database)
            }
            group.addTask { [timeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timeout
            }
            let first = await group.next() ?? .unknown
            group.cancelAll()
            return first
        }

        switch operationResult {
        case .saved:
            return approval(for: request, state: successState, wasCreated: wasCreated)
        case .competing:
            if case .found(let fetched) = await fetchRecord(record.recordID),
               recordMatches(fetched, request: request),
               claimState(fetched) == successState {
                return approval(for: request, state: successState, wasCreated: wasCreated)
            }
            return .denied(competingDenial)
        case .unknown:
            return .denied(.unknown)
        case .timeout:
            guard case .found(let fetched) = await fetchRecord(record.recordID),
                  recordMatches(fetched, request: request),
                  claimState(fetched) == successState else {
                return .denied(.timeout)
            }
            return approval(for: request, state: successState, wasCreated: wasCreated)
        }
    }

    private enum ModifyResult {
        case saved
        case competing
        case timeout
        case unknown
    }

    private static func modifyAtomically(_ record: CKRecord, in database: CKDatabase) async -> ModifyResult {
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                operation.isAtomic = true
                operation.savePolicy = .ifServerRecordUnchanged
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: .saved)
                    case .failure(let error):
                        guard let cloudError = error as? CKError else {
                            continuation.resume(returning: .unknown)
                            return
                        }
                        switch cloudError.code {
                        case .serverRecordChanged, .batchRequestFailed, .constraintViolation:
                            continuation.resume(returning: .competing)
                        default:
                            continuation.resume(returning: .unknown)
                        }
                    }
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private enum FetchResult {
        case found(CKRecord)
        case missing
        case unknown
    }

    private func fetchRecord(_ recordID: CKRecord.ID) async -> FetchResult {
        do {
            return .found(try await database.record(for: recordID))
        } catch let error as CKError where error.code == .unknownItem {
            return .missing
        } catch {
            return .unknown
        }
    }

    private func result(
        for record: CKRecord,
        matching request: VocabBootstrapClaimRequest
    ) -> VocabBootstrapClaimResult {
        guard recordMatches(record, request: request) else {
            return .denied(.foreign)
        }
        guard let state = claimState(record) else {
            return .denied(.unknown)
        }
        return approval(for: request, state: state)
    }

    private func apply(
        _ request: VocabBootstrapClaimRequest,
        state: VocabBootstrapClaimState,
        to record: CKRecord,
        now: Date
    ) {
        record[Field.claimID] = request.claimID.uuidString as CKRecordValue
        record[Field.requestID] = request.requestID.uuidString as CKRecordValue
        record[Field.ownerDeviceID] = request.ownerDeviceID as CKRecordValue
        record[Field.sourceFingerprint] = request.sourceFingerprint as CKRecordValue
        record[Field.schemaVersion] = NSNumber(value: request.schemaVersion)
        record[Field.state] = state.rawValue as CKRecordValue
        record[Field.createdAt] = request.createdAt as CKRecordValue
        record[Field.updatedAt] = now as CKRecordValue
    }

    private func recordMatches(_ record: CKRecord, request: VocabBootstrapClaimRequest) -> Bool {
        (record[Field.claimID] as? String) == request.claimID.uuidString
            && (record[Field.requestID] as? String) == request.requestID.uuidString
            && (record[Field.ownerDeviceID] as? String) == request.ownerDeviceID
            && (record[Field.sourceFingerprint] as? String) == request.sourceFingerprint
            && (record[Field.schemaVersion] as? NSNumber)?.intValue == request.schemaVersion
    }

    private func claimState(_ record: CKRecord) -> VocabBootstrapClaimState? {
        guard let rawValue = record[Field.state] as? String else { return nil }
        return VocabBootstrapClaimState(rawValue: rawValue)
    }

    private func isLegalTransition(
        from oldState: VocabBootstrapClaimState,
        to newState: VocabBootstrapClaimState
    ) -> Bool {
        (oldState == .claimed && newState == .seeding)
            || (oldState == .seeding && newState == .completed)
            || oldState == newState
    }

    private func approval(
        for request: VocabBootstrapClaimRequest,
        state: VocabBootstrapClaimState,
        wasCreated: Bool = false
    ) -> VocabBootstrapClaimResult {
        .resumed(VocabBootstrapClaimApproval(
            request: request,
            state: state,
            recordName: Self.recordName,
            wasCreated: wasCreated
        ))
    }
}

enum VocabCloudExportWaitError: LocalizedError, Equatable {
    case storeIdentifierUnavailable
    case exportFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .storeIdentifierUnavailable:
            "mirrored store 식별자를 확인하지 못해 CloudKit export 완료 판정을 중단했습니다."
        case .exportFailed(let message):
            "mirrored store의 CloudKit export가 실패했습니다: \(message)"
        case .timedOut:
            "mirrored store의 CloudKit export 성공을 제한 시간 안에 확인하지 못했습니다. claim은 seeding 상태로 유지됩니다."
        }
    }
}

struct VocabBootstrapExportBoundary: Equatable, Sendable {
    let requestID: UUID
    let fingerprint: String
    let storeUUID: String
    let transactionCommittedAt: Date
    let exportNotBefore: Date
    let probeGeneration: Int
    let nonce: UUID
}

struct VocabCloudExportEventEvidence: Equatable, Sendable {
    let storeIdentifier: String
    let startDate: Date
    let succeeded: Bool
    let errorDescription: String?
}

enum VocabCloudExportEventDecision: Equatable {
    case ignore
    case success
    case failure(String)
}

enum VocabCloudExportEventPolicy {
    static func evaluate(
        _ event: VocabCloudExportEventEvidence,
        boundary: VocabBootstrapExportBoundary,
        expectedRequestID: UUID,
        expectedFingerprint: String,
        expectedStoreIdentifier: String,
        receiptMatches: Bool
    ) -> VocabCloudExportEventDecision {
        guard boundary.requestID == expectedRequestID,
              boundary.fingerprint == expectedFingerprint,
              boundary.storeUUID == expectedStoreIdentifier,
              event.storeIdentifier == expectedStoreIdentifier,
              event.startDate >= boundary.exportNotBefore,
              receiptMatches else {
            return .ignore
        }
        guard event.succeeded, event.errorDescription == nil else {
            return .failure(event.errorDescription ?? "알 수 없는 export 오류")
        }
        return .success
    }
}

@MainActor
final class VocabCloudExportEventGate {
    private let requestID: UUID
    private let fingerprint: String
    private let storeIdentifier: String
    private let receiptMatches: @MainActor (VocabBootstrapExportBoundary) -> Bool
    private var boundary: VocabBootstrapExportBoundary?
    private var pendingEvents: [VocabCloudExportEventEvidence] = []

    init(
        requestID: UUID,
        fingerprint: String,
        storeIdentifier: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
    ) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.storeIdentifier = storeIdentifier
        self.receiptMatches = receiptMatches
    }

    func setCommittedBoundary(_ boundary: VocabBootstrapExportBoundary) -> VocabCloudExportEventDecision? {
        guard boundary.requestID == requestID,
              boundary.fingerprint == fingerprint,
              boundary.storeUUID == storeIdentifier else { return nil }
        self.boundary = boundary
        let events = pendingEvents
        pendingEvents.removeAll()
        for event in events {
            let decision = evaluate(event, boundary: boundary)
            if decision != .ignore { return decision }
        }
        return nil
    }

    func receive(_ event: VocabCloudExportEventEvidence) -> VocabCloudExportEventDecision? {
        guard let boundary else {
            pendingEvents.append(event)
            return nil
        }
        let decision = evaluate(event, boundary: boundary)
        return decision == .ignore ? nil : decision
    }

    private func evaluate(
        _ event: VocabCloudExportEventEvidence,
        boundary: VocabBootstrapExportBoundary
    ) -> VocabCloudExportEventDecision {
        VocabCloudExportEventPolicy.evaluate(
            event,
            boundary: boundary,
            expectedRequestID: requestID,
            expectedFingerprint: fingerprint,
            expectedStoreIdentifier: storeIdentifier,
            receiptMatches: receiptMatches(boundary)
        )
    }
}

@MainActor
protocol VocabCloudExportExpectation: AnyObject {
    var storeIdentifier: String { get }
    func setCommittedBoundary(_ boundary: VocabBootstrapExportBoundary)
    func waitForResult(timeout: TimeInterval) async throws
}

@MainActor
protocol VocabCloudExportObserving {
    func beginWaiting(
        storeURL: URL,
        requestID: UUID,
        fingerprint: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
    ) throws -> any VocabCloudExportExpectation
}

struct VocabPersistentCloudKitExportObserver: VocabCloudExportObserving {
    func beginWaiting(
        storeURL: URL,
        requestID: UUID,
        fingerprint: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
    ) throws -> any VocabCloudExportExpectation {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL,
            options: nil
        )
        guard let storeIdentifier = metadata[NSStoreUUIDKey] as? String, !storeIdentifier.isEmpty else {
            throw VocabCloudExportWaitError.storeIdentifierUnavailable
        }
        return VocabPersistentCloudKitExportExpectation(
            storeIdentifier: storeIdentifier,
            requestID: requestID,
            fingerprint: fingerprint,
            receiptMatches: receiptMatches
        )
    }
}

@MainActor
private final class VocabPersistentCloudKitExportExpectation: VocabCloudExportExpectation {
    let storeIdentifier: String
    private let requestID: UUID
    private let fingerprint: String
    private let receiptMatches: @MainActor (VocabBootstrapExportBoundary) -> Bool
    private let gate: VocabCloudExportEventGate
    private var observer: NSObjectProtocol?
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    init(
        storeIdentifier: String,
        requestID: UUID,
        fingerprint: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
    ) {
        self.storeIdentifier = storeIdentifier
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.receiptMatches = receiptMatches
        gate = VocabCloudExportEventGate(
            requestID: requestID,
            fingerprint: fingerprint,
            storeIdentifier: storeIdentifier,
            receiptMatches: receiptMatches
        )
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.type == .export,
                  event.storeIdentifier == storeIdentifier,
                  event.endDate != nil else {
                return
            }
            Task { @MainActor [weak self] in
                self?.receive(event)
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func setCommittedBoundary(_ boundary: VocabBootstrapExportBoundary) {
        guard boundary.requestID == requestID,
              boundary.fingerprint == fingerprint,
              boundary.storeUUID == storeIdentifier else {
            return
        }
        if let decision = gate.setCommittedBoundary(boundary) {
            resolve(decision)
        }
    }

    func waitForResult(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if let result {
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation

            Task { @MainActor [weak self] in
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                self?.resolve(.failure(VocabCloudExportWaitError.timedOut))
            }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let observer = observer
        self.observer = nil

        if let observer { NotificationCenter.default.removeObserver(observer) }
        continuation?.resume(with: result)
    }

    private func receive(_ event: NSPersistentCloudKitContainer.Event) {
        guard result == nil else { return }
        let evidence = VocabCloudExportEventEvidence(
            storeIdentifier: event.storeIdentifier,
            startDate: event.startDate,
            succeeded: event.succeeded,
            errorDescription: event.error?.localizedDescription
        )
        if let decision = gate.receive(evidence) {
            resolve(decision)
        }
    }

    private func resolve(_ decision: VocabCloudExportEventDecision) {
        switch decision {
        case .ignore:
            return
        case .success:
            resolve(.success(()))
        case .failure(let message):
            resolve(.failure(VocabCloudExportWaitError.exportFailed(message)))
        }
    }
}

struct VocabHydrationDiagnosis: Equatable {
    let state: VocabHydrationState
    let message: String?
    let completedMetadataMissingSince: Date?
}

enum VocabHydrationRefreshReason: Equatable {
    case manual
    case remoteStoreChange
    case successfulImport
    case pollingTick(sceneIsActive: Bool)
}

enum VocabHydrationDiagnosticPolicy {
    static let completedMetadataGracePeriod: TimeInterval = 60

    static func diagnose(
        localStatus: VocabHydrationStatus,
        claimStatus: VocabBootstrapServerClaimStatus,
        completedMetadataMissingSince: Date?,
        now: Date = .now,
        gracePeriod: TimeInterval = completedMetadataGracePeriod
    ) -> VocabHydrationDiagnosis {
        guard localStatus.state == .awaitingBootstrapMetadata else {
            return VocabHydrationDiagnosis(
                state: localStatus.state,
                message: localStatus.message,
                completedMetadataMissingSince: nil
            )
        }

        switch claimStatus {
        case .missing:
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac에서 최초 iCloud 전환을 완료해야 합니다. iPhone은 데이터를 seed하지 않습니다.",
                completedMetadataMissingSince: nil
            )
        case .available(.claimed), .available(.seeding):
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac이 기존 단어장을 iCloud로 업로드하는 중입니다. Mac 앱을 종료하지 말고 잠시 기다리세요.",
                completedMetadataMissingSince: nil
            )
        case .available(.completed):
            let startedAt = completedMetadataMissingSince ?? now
            if now.timeIntervalSince(startedAt) >= gracePeriod {
                return VocabHydrationDiagnosis(
                    state: .failed,
                    message: "Mac 업로드 완료는 확인됐지만 bootstrap metadata를 받지 못했습니다. 네트워크와 iCloud 상태를 확인한 뒤 '동기화 상태 다시 확인'을 실행하세요.",
                    completedMetadataMissingSince: startedAt
                )
            }
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac 업로드는 완료됐으며 iPhone이 bootstrap metadata를 가져오고 있습니다.",
                completedMetadataMissingSince: startedAt
            )
        case .unavailable(let message):
            return VocabHydrationDiagnosis(
                state: .failed,
                message: message,
                completedMetadataMissingSince: completedMetadataMissingSince
            )
        }
    }

    static func shouldPoll(sceneIsActive: Bool, state: VocabHydrationState) -> Bool {
        sceneIsActive && (state == .awaitingBootstrapMetadata || state == .hydrating)
    }

    static func shouldRefresh(reason: VocabHydrationRefreshReason, state: VocabHydrationState) -> Bool {
        switch reason {
        case .manual, .remoteStoreChange, .successfulImport:
            true
        case .pollingTick(let sceneIsActive):
            shouldPoll(sceneIsActive: sceneIsActive, state: state)
        }
    }

    static func isSuccessfulImportEvent(_ notification: Notification) -> Bool {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return false
        }
        return event.type == .import && event.endDate != nil && event.succeeded
    }
}
