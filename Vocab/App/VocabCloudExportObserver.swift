import CoreData
import Foundation

enum VocabCloudExportWaitError: LocalizedError, Equatable {
    case storeIdentifierUnavailable
    case exportFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .storeIdentifierUnavailable:
            "iCloud 저장 공간을 확인하지 못해 업로드 완료 확인을 중단했습니다."
        case .exportFailed(let message):
            "iCloud 업로드에 실패했습니다: \(message)"
        case .timedOut:
            "iCloud 업로드 완료를 제한 시간 안에 확인하지 못했습니다. 진행 상태는 보존되므로 다시 확인할 수 있습니다."
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
            return .failure(event.errorDescription ?? "알 수 없는 iCloud 업로드 오류")
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
                // Never cancelled; a result that arrives first makes this a no-op.
                try? await Task.sleep(for: .seconds(max(timeout, 0.1)))
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
