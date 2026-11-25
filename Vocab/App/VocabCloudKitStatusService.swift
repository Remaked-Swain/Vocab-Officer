import CloudKit
import Foundation

/// Returns an operation's value, or a fallback once a deadline passes.
///
/// CloudKit and `NWPathMonitor` calls do not always honour cancellation, so
/// the deadline must return while the operation may still be running. A task
/// group cannot: it waits for every child before returning. The operation and
/// the timer instead race to yield into a one-element stream; the first value
/// wins and both tasks are cancelled. Cancelling the caller ends the wait
/// with the fallback.
enum VocabAsyncDeadline {
    /// Shortest deadline honoured, so a zero timeout still lets a ready
    /// operation answer.
    static let minimumTimeout: Duration = .milliseconds(1)

    static func value<Value: Sendable>(
        timeout: Duration,
        timeoutValue: Value,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let (results, sink) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingOldest(1))
        let operationTask = Task {
            sink.yield(await operation())
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: max(timeout, minimumTimeout))
            } catch {
                return
            }
            sink.yield(timeoutValue)
        }
        defer {
            operationTask.cancel()
            timeoutTask.cancel()
            sink.finish()
        }
        for await first in results {
            return first
        }
        return timeoutValue
    }
}

enum VocabCloudKitAccountState: Equatable {
    case unknown
    case available
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable(String)

    var title: String {
        switch self {
        case .unknown:
            "확인 전"
        case .available:
            "iCloud 사용 가능"
        case .noAccount:
            "iCloud 계정 없음"
        case .restricted:
            "iCloud 사용 제한됨"
        case .couldNotDetermine:
            "iCloud 상태 확인 불가"
        case .temporarilyUnavailable:
            "일시적으로 확인 실패"
        }
    }

    var message: String {
        switch self {
        case .unknown:
            return "아직 이 기기의 iCloud 계정 상태를 확인하지 않았습니다."
        case .available:
            return "이 Apple ID는 CloudKit 개인 데이터베이스를 사용할 수 있습니다."
        case .noAccount:
            return "시스템 설정에서 iCloud에 로그인해야 단어장 동기화를 사용할 수 있습니다."
        case .restricted:
            return "이 기기 또는 계정 정책 때문에 iCloud 동기화가 제한되어 있습니다."
        case .couldNotDetermine:
            return "현재 iCloud 계정 상태를 판단하지 못했습니다. 네트워크와 iCloud 설정을 확인하세요."
        case .temporarilyUnavailable(let reason):
            return reason
        }
    }

    var isReadyForSync: Bool {
        if case .available = self {
            return true
        }
        return false
    }
}

protocol VocabCloudKitAccountStatusChecking {
    func accountStatus() async -> VocabCloudKitAccountState
}

struct VocabCloudKitStatusService: VocabCloudKitAccountStatusChecking {
    private let timeout: Duration
    private let accountStatusLoader: @Sendable () async throws -> CKAccountStatus

    init(
        container: CKContainer = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier),
        timeout: Duration = .seconds(15)
    ) {
        self.timeout = timeout
        accountStatusLoader = { try await container.accountStatus() }
    }

    init(
        timeout: Duration,
        accountStatusLoader: @escaping @Sendable () async throws -> CKAccountStatus
    ) {
        self.timeout = timeout
        self.accountStatusLoader = accountStatusLoader
    }

    func accountStatus() async -> VocabCloudKitAccountState {
        await VocabAsyncDeadline.value(
            timeout: timeout,
            timeoutValue: .temporarilyUnavailable(
                "iCloud 상태 확인 시간이 초과되었습니다. 네트워크와 iCloud 상태를 확인한 뒤 다시 시도하세요."
            )
        ) {
            do {
                return Self.map(try await accountStatusLoader())
            } catch {
                return .temporarilyUnavailable("iCloud 상태 확인 중 문제가 발생했습니다. 잠시 후 다시 시도하세요.")
            }
        }
    }

    static func map(_ status: CKAccountStatus) -> VocabCloudKitAccountState {
        switch status {
        case .available:
            return .available
        case .noAccount:
            return .noAccount
        case .restricted:
            return .restricted
        case .couldNotDetermine:
            return .couldNotDetermine
        case .temporarilyUnavailable:
            return .temporarilyUnavailable("Apple iCloud 서비스 또는 네트워크 상태가 일시적으로 불안정합니다.")
        @unknown default:
            return .couldNotDetermine
        }
    }

    static func resolve(
        accountState: VocabCloudKitAccountState,
        claimStatus: VocabBootstrapServerClaimStatus
    ) -> VocabCloudKitAccountState {
        guard !accountState.isReadyForSync else { return accountState }
        switch claimStatus {
        case .missing, .available:
            return .available
        case .unavailable:
            return accountState
        }
    }
}
