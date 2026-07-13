import Foundation

enum VocabCloudSyncBlocker: Equatable, Identifiable {
    case accountUnavailable(VocabCloudKitAccountState)
    case runtimeDisabled
    case entitlementPending
    case schemaMigrationRequired
    case firstUploadConfirmationRequired

    var id: String {
        switch self {
        case .accountUnavailable:
            "accountUnavailable"
        case .runtimeDisabled:
            "runtimeDisabled"
        case .entitlementPending:
            "entitlementPending"
        case .schemaMigrationRequired:
            "schemaMigrationRequired"
        case .firstUploadConfirmationRequired:
            "firstUploadConfirmationRequired"
        }
    }

    var title: String {
        switch self {
        case .accountUnavailable:
            "iCloud 계정 확인 필요"
        case .runtimeDisabled:
            "앱 전환 스위치 잠김"
        case .entitlementPending:
            "iCloud 서명 권한 미확정"
        case .schemaMigrationRequired:
            "저장 모델 검증 필요"
        case .firstUploadConfirmationRequired:
            "최초 업로드 확인 필요"
        }
    }

    var message: String {
        switch self {
        case .accountUnavailable(let state):
            return state.message
        case .runtimeDisabled:
            return "현재 빌드는 기존 macOS 단어장을 보호하기 위해 iCloud 저장소 전환을 코드상 차단합니다."
        case .entitlementPending:
            return "CloudKit 컨테이너 권한과 서명 설정을 검증한 뒤에만 동기화를 켤 수 있습니다."
        case .schemaMigrationRequired:
            return "기존 로컬 SwiftData 모델을 CloudKit 호환 스키마로 검증 또는 마이그레이션해야 합니다."
        case .firstUploadConfirmationRequired:
            return "기존 단어장을 iCloud에 올리기 전에 백업 또는 사용자 확인 절차가 필요합니다."
        }
    }
}

struct VocabCloudSyncReadiness: Equatable {
    var accountState: VocabCloudKitAccountState
    var allowsCloudKitRuntime: Bool
    var hasCloudKitEntitlement: Bool
    var isSchemaCloudKitReady: Bool
    var hasConfirmedFirstUpload: Bool

    var blockers: [VocabCloudSyncBlocker] {
        var result: [VocabCloudSyncBlocker] = []

        if !accountState.isReadyForSync {
            result.append(.accountUnavailable(accountState))
        }
        if !allowsCloudKitRuntime {
            result.append(.runtimeDisabled)
        }
        if !hasCloudKitEntitlement {
            result.append(.entitlementPending)
        }
        if !isSchemaCloudKitReady {
            result.append(.schemaMigrationRequired)
        }
        if !hasConfirmedFirstUpload {
            result.append(.firstUploadConfirmationRequired)
        }

        return result
    }

    var isReadyToEnable: Bool {
        blockers.isEmpty
    }
}

enum VocabCloudSyncReadinessPolicy {
    static func current(accountState: VocabCloudKitAccountState) -> VocabCloudSyncReadiness {
        VocabCloudSyncReadiness(
            accountState: accountState,
            allowsCloudKitRuntime: false,
            hasCloudKitEntitlement: false,
            isSchemaCloudKitReady: false,
            hasConfirmedFirstUpload: false
        )
    }
}
