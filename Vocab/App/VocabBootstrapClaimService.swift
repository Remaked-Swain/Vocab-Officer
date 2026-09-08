import CloudKit
import CoreData
import Foundation
import SwiftData

enum VocabBootstrapClaimState: String, Equatable {
    case claimed
    case seeding
    case completed
}

struct VocabBootstrapClaimRequest: Codable, Equatable {
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
    case available(VocabBootstrapServerClaim)
    case unavailable(String)
}

struct VocabBootstrapServerClaim: Equatable {
    let request: VocabBootstrapClaimRequest
    let state: VocabBootstrapClaimState
    let createdAt: Date
    let updatedAt: Date
}

protocol VocabBootstrapClaimStatusReading {
    func fixedClaimStatus() async -> VocabBootstrapServerClaimStatus
}

enum VocabBootstrapResumeDecision: Equatable {
    case createNew
    case hydrateCompleted(VocabBootstrapServerClaim)
    case resume(VocabBootstrapClaimRequest)
    case recoverExisting(VocabBootstrapClaimRequest)
    case blocked(String)
}

enum VocabBootstrapResumePolicy {
    static func decide(
        serverStatus: VocabBootstrapServerClaimStatus,
        storedRequest: VocabBootstrapClaimRequest?,
        currentCanonicalFingerprint: String,
        checkpointManifest: VocabBootstrapRecoveryManifest?,
        expectedSchemaVersion: Int,
        receiptIsValid: Bool
    ) -> VocabBootstrapResumeDecision {
        switch serverStatus {
        case .missing:
            return storedRequest == nil
                ? .createNew
                : .blocked("서버 claim은 없지만 로컬에 이전 claim tuple이 남아 있어 새 claim 생성을 중단했습니다.")
        case .unavailable(let message):
            return .blocked(message)
        case .available(let serverClaim):
            if serverClaim.state == .completed {
                return .hydrateCompleted(serverClaim)
            }
            if let storedRequest {
                return storedRequest == serverClaim.request
                    ? .resume(storedRequest)
                    : .blocked("서버 claim과 Keychain tuple이 달라 takeover를 중단했습니다.")
            }
            guard serverClaim.request.schemaVersion == expectedSchemaVersion else {
                return .blocked("서버 claim schema가 현재 앱과 달라 기존 claim 복구를 중단했습니다.")
            }
            let currentMatches = serverClaim.request.sourceFingerprint == currentCanonicalFingerprint
            let checkpointMatches = checkpointManifest.map {
                $0.canonicalFingerprint == serverClaim.request.sourceFingerprint
                    && $0.claimRequest == serverClaim.request
            } ?? false
            guard (currentMatches || checkpointMatches), receiptIsValid else {
                return .blocked("기존 claim의 fingerprint/checkpoint/receipt를 모두 검증하지 못해 takeover 없이 중단했습니다.")
            }
            return .recoverExisting(serverClaim.request)
        }
    }
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
            guard let claim = serverClaim(record) else {
                return .unavailable("bootstrap claim 상태를 해석하지 못했습니다.")
            }
            return .available(claim)
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

    private func serverClaim(_ record: CKRecord) -> VocabBootstrapServerClaim? {
        guard let claimIDRaw = record[Field.claimID] as? String,
              let requestIDRaw = record[Field.requestID] as? String,
              let claimID = UUID(uuidString: claimIDRaw),
              let requestID = UUID(uuidString: requestIDRaw),
              let ownerDeviceID = record[Field.ownerDeviceID] as? String,
              let sourceFingerprint = record[Field.sourceFingerprint] as? String,
              let schemaVersion = (record[Field.schemaVersion] as? NSNumber)?.intValue,
              let state = claimState(record),
              let createdAt = record[Field.createdAt] as? Date,
              let updatedAt = record[Field.updatedAt] as? Date else {
            return nil
        }
        return VocabBootstrapServerClaim(
            request: VocabBootstrapClaimRequest(
                claimID: claimID,
                requestID: requestID,
                ownerDeviceID: ownerDeviceID,
                sourceFingerprint: sourceFingerprint,
                schemaVersion: schemaVersion,
                createdAt: createdAt
            ),
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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

enum VocabHydrationRefreshReason: Equatable, Sendable {
    case initial
    case foreground
    case manual
    case remoteStoreChange
    case successfulImport
    case pollingTick(sceneIsActive: Bool)
}

actor VocabHydrationRefreshQueue {
    private var pendingReason: VocabHydrationRefreshReason?
    private var isDraining = false

    func enqueue(_ reason: VocabHydrationRefreshReason) -> Bool {
        pendingReason = Self.merge(pendingReason, reason)
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    func dequeue() -> VocabHydrationRefreshReason? {
        guard let pendingReason else {
            isDraining = false
            return nil
        }
        self.pendingReason = nil
        return pendingReason
    }

    private static func merge(
        _ existing: VocabHydrationRefreshReason?,
        _ incoming: VocabHydrationRefreshReason
    ) -> VocabHydrationRefreshReason {
        guard let existing else { return incoming }
        if existing == .successfulImport || incoming == .successfulImport {
            return .successfulImport
        }
        if existing == .manual || incoming == .manual {
            return .manual
        }
        if existing == .initial || incoming == .initial {
            return .initial
        }
        if existing == .remoteStoreChange || incoming == .remoteStoreChange {
            return .remoteStoreChange
        }
        return incoming
    }
}

actor VocabSyncRuntimeStateStore {
    static let shared = VocabSyncRuntimeStateStore()

    private enum Key {
        static let lastDiagnosticAt = "vocabSyncRuntime.lastDiagnosticAt"
        static let lastFullAuditAt = "vocabSyncRuntime.lastFullAuditAt"
        static let fullAuditRequested = "vocabSyncRuntime.fullAuditRequested"
        static let reachedReady = "vocabSyncRuntime.reachedReady"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shouldRunDiagnostic(
        reason: VocabHydrationRefreshReason,
        now: Date = .now
    ) -> Bool {
        VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: reason,
            lastDiagnosticAt: defaults.object(forKey: Key.lastDiagnosticAt) as? Date,
            now: now
        )
    }

    func markDiagnosticCompleted(at date: Date = .now, state: VocabHydrationState) {
        defaults.set(date, forKey: Key.lastDiagnosticAt)
        if state == .ready || state == .localOnly {
            defaults.set(true, forKey: Key.reachedReady)
        }
    }

    func shouldRunFullAudit(now: Date = .now) -> Bool {
        defaults.bool(forKey: Key.fullAuditRequested) || VocabHydrationDiagnosticPolicy.fullAuditIsDue(
            lastAuditAt: defaults.object(forKey: Key.lastFullAuditAt) as? Date,
            now: now
        )
    }

    func requestFullAudit() {
        defaults.set(true, forKey: Key.fullAuditRequested)
    }

    func hasCompletedFullAudit() -> Bool {
        defaults.object(forKey: Key.lastFullAuditAt) as? Date != nil
    }

    func markFullAuditCompleted(at date: Date = .now) {
        defaults.set(date, forKey: Key.lastFullAuditAt)
        defaults.set(false, forKey: Key.fullAuditRequested)
    }

    static func persistedLocalContentIsUsable(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.reachedReady)
    }
}

struct VocabMaintenanceTaskSlot: Equatable {
    private(set) var generation: UUID?

    mutating func begin(generation newGeneration: UUID = UUID()) -> UUID? {
        guard generation == nil else { return nil }
        generation = newGeneration
        return newGeneration
    }

    mutating func cancel() {
        generation = nil
    }

    mutating func complete(generation completedGeneration: UUID) -> Bool {
        guard generation == completedGeneration else { return false }
        generation = nil
        return true
    }
}

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
        case .hydrateCompleted(let claim):
            enableMirroredMode()
            return VocabBootstrapActivationOutcome(
                disposition: .restartRequired,
                message: "서버 bootstrap 완료를 확인했습니다. Vocab을 다시 열면 iCloud 단어장을 사용합니다. claim \(claim.request.requestID.uuidString)"
            )
        case .createNew where !allowsNewClaim:
            return VocabBootstrapActivationOutcome(
                disposition: .noAction,
                message: "기존 bootstrap 작업이 없어 자동 전환하지 않았습니다. 최초 전환은 설정에서 직접 승인해야 합니다."
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
            message: "\(report.wordCount)개 단어와 \(report.dailySetCount)개 세트의 CloudKit export를 확인했습니다. Vocab을 다시 열면 레코드 단위 자동 동기화가 시작됩니다."
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
                throw VocabBootstrapActivationError.blocked("legacy bootstrap의 seeding 전환을 확인하지 못했습니다.")
            }
        }

        let expectation = try VocabPersistentCloudKitExportObserver().beginWaiting(
            storeURL: try VocabModelContainerFactory.mirroredStoreURL(),
            requestID: claim.request.requestID,
            fingerprint: claim.request.sourceFingerprint,
            receiptMatches: { boundary in
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
            throw VocabBootstrapActivationError.blocked("legacy bootstrap export 후 서버 완료 전환을 확인하지 못했습니다.")
        }
        _ = try VocabCloudReconciler.reconcile(context: mirroredContext, syncMode: .cloudKitPrivate)
        enableMirroredMode()
        return VocabBootstrapActivationOutcome(
            disposition: .restartRequired,
            message: "기존 fingerprint 규칙으로 중단된 bootstrap을 실제 local/mirrored 데이터 일치 검증 후 완료했습니다. Vocab을 다시 열면 레코드 단위 자동 동기화가 시작됩니다."
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
        guard let credential else { return "Keychain claim 자격 증명이 없습니다." }
        if credential.request != nil { return "Keychain에 완전한 claim tuple이 있습니다." }
        guard case .available(let serverClaim) = serverStatus else { return "서버 claim을 읽지 못했습니다." }
        guard credential.token.claimID == serverClaim.request.claimID,
              credential.token.requestID == serverClaim.request.requestID else {
            return "Keychain token과 서버 claim 식별자가 다릅니다."
        }
        guard credential.originDeviceID == serverClaim.request.ownerDeviceID else {
            return "claim 원본 기기가 현재 Keychain 자격 증명과 다릅니다."
        }
        guard serverClaim.request.schemaVersion == VocabCloudReconciler.metadataSchemaVersion else {
            return "claim schema version이 현재 앱과 다릅니다."
        }
        guard currentCanonicalFingerprint == serverClaim.request.sourceFingerprint else {
            return "현재 로컬 단어장의 canonical fingerprint가 서버 claim과 다릅니다."
        }
        return "legacy claim의 안전 조건이 모두 일치합니다."
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

enum VocabHydrationDiagnosticPolicy {
    static let foregroundDiagnosticTTL: TimeInterval = 15 * 60
    static let fullAuditTTL: TimeInterval = 7 * 24 * 60 * 60
    static let completedMetadataGracePeriod: TimeInterval = 60
    static let bootstrapPollingDelays: [TimeInterval] = [5, 10, 20, 40, 60]

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
        case .available(let claim) where claim.state == .claimed || claim.state == .seeding:
            return VocabHydrationDiagnosis(
                state: .awaitingBootstrapMetadata,
                message: "Mac이 기존 단어장을 iCloud로 업로드하는 중입니다. Mac 앱을 종료하지 말고 잠시 기다리세요.",
                completedMetadataMissingSince: nil
            )
        case .available(let claim) where claim.state == .completed:
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
        case .available:
            return VocabHydrationDiagnosis(
                state: .failed,
                message: "bootstrap claim 상태를 해석하지 못했습니다.",
                completedMetadataMissingSince: completedMetadataMissingSince
            )
        }
    }

    static func shouldPoll(sceneIsActive: Bool, state: VocabHydrationState) -> Bool {
        sceneIsActive && (state == .awaitingBootstrapMetadata || state == .hydrating)
    }

    static func pollingDelay(attempt: Int) -> TimeInterval? {
        guard bootstrapPollingDelays.indices.contains(attempt) else { return nil }
        return bootstrapPollingDelays[attempt]
    }

    static func shouldRefresh(reason: VocabHydrationRefreshReason, state: VocabHydrationState) -> Bool {
        switch reason {
        case .initial, .manual, .successfulImport:
            true
        case .foreground, .remoteStoreChange:
            false
        case .pollingTick(let sceneIsActive):
            shouldPoll(sceneIsActive: sceneIsActive, state: state)
        }
    }

    static func shouldReconcile(reason: VocabHydrationRefreshReason, state: VocabHydrationState) -> Bool {
        state == .reconciling || (reason == .successfulImport && state == .ready)
    }

    static func diagnosticIsDue(
        reason: VocabHydrationRefreshReason,
        lastDiagnosticAt: Date?,
        now: Date = .now,
        ttl: TimeInterval = foregroundDiagnosticTTL
    ) -> Bool {
        switch reason {
        case .initial, .manual, .successfulImport:
            return true
        case .foreground, .remoteStoreChange:
            return false
        case .pollingTick:
            return true
        }
    }

    static func fullAuditIsDue(
        lastAuditAt: Date?,
        now: Date = .now,
        ttl: TimeInterval = fullAuditTTL
    ) -> Bool {
        guard let lastAuditAt else { return true }
        return now.timeIntervalSince(lastAuditAt) >= ttl
    }

    static func isSuccessfulImportEvent(_ notification: Notification) -> Bool {
        guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
            return false
        }
        return event.type == .import && event.endDate != nil && event.succeeded
    }
}
