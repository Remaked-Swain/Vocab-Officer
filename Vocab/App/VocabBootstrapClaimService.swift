import CloudKit
import Foundation

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

    var userFacingReason: String {
        switch self {
        case .existing:
            "이미 완료된 최초 동기화가 있습니다."
        case .competing:
            "다른 Mac에서 최초 동기화를 진행하고 있습니다."
        case .foreign:
            "현재 Mac의 단어장과 iCloud의 최초 동기화 정보가 일치하지 않습니다."
        case .timeout:
            "iCloud 응답을 제한 시간 안에 받지 못했습니다."
        case .unknown:
            "iCloud 상태를 확인하지 못했습니다."
        }
    }
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
                : .blocked("iCloud에는 진행 중인 작업이 없지만 Mac에 이전 작업 정보가 남아 있어 새 업로드를 시작하지 않았습니다.")
        case .unavailable(let message):
            return .blocked(message)
        case .available(let serverClaim):
            if serverClaim.state == .completed {
                return .hydrateCompleted(serverClaim)
            }
            if let storedRequest {
                return storedRequest == serverClaim.request
                    ? .resume(storedRequest)
                    : .blocked("iCloud의 최초 동기화 정보와 이 Mac의 보안 정보가 달라 작업을 중단했습니다.")
            }
            guard serverClaim.request.schemaVersion == expectedSchemaVersion else {
                return .blocked("iCloud의 최초 동기화 정보가 현재 앱과 호환되지 않아 복구를 중단했습니다.")
            }
            let currentMatches = serverClaim.request.sourceFingerprint == currentCanonicalFingerprint
            let checkpointMatches = checkpointManifest.map {
                $0.canonicalFingerprint == serverClaim.request.sourceFingerprint
                    && $0.claimRequest == serverClaim.request
            } ?? false
            guard (currentMatches || checkpointMatches), receiptIsValid else {
                return .blocked("이전 최초 동기화 작업이 현재 단어장과 같은지 확인하지 못해 안전을 위해 중단했습니다.")
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
    private let timeout: Duration
    private let recordFetcher: @Sendable (CKRecord.ID) async throws -> CKRecord

    init(
        container: CKContainer = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier),
        timeout: Duration = .seconds(15)
    ) {
        database = container.privateCloudDatabase
        self.timeout = max(timeout, .milliseconds(100))
        recordFetcher = { try await container.privateCloudDatabase.record(for: $0) }
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
            return .unavailable("Mac 최초 동기화 상태를 확인하지 못했습니다. 네트워크와 iCloud 상태를 확인하세요.")
        case .found(let record):
            guard let claim = serverClaim(record) else {
                return .unavailable("Mac 최초 동기화 상태를 확인하지 못했습니다.")
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
            group.addTask { [timeout] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the save answered first or the caller
                    // was cancelled; never report a cancelled wait as a timeout.
                    return .unknown
                }
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
        await VocabAsyncDeadline.value(
            timeout: timeout,
            timeoutValue: .unknown
        ) {
            do {
                return .found(try await self.recordFetcher(recordID))
            } catch let error as CKError where error.code == .unknownItem {
                return .missing
            } catch {
                return .unknown
            }
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
