import CloudKit
import Foundation

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
    private let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier)) {
        self.container = container
    }

    func accountStatus() async -> VocabCloudKitAccountState {
        do {
            let status = try await container.accountStatus()
            return Self.map(status)
        } catch {
            return .temporarilyUnavailable("iCloud 상태 확인 중 문제가 발생했습니다. 잠시 후 다시 시도하세요.")
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
}
