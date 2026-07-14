import CloudKit
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

final class VocabCloudKitBootstrapClaimService: VocabBootstrapClaiming {
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
