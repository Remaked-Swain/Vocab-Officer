import Foundation

enum VocabCloudSyncBlocker: Equatable, Identifiable {
    case accountUnavailable(VocabCloudKitAccountState)
    case runtimeDisabled
    case entitlementPending
    case schemaMigrationRequired
    case firstUploadConfirmationRequired
    case syncBaselineRequired
    case networkUnavailable
    case constrainedNetwork
    case lowPowerMode

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
        case .syncBaselineRequired:
            "syncBaselineRequired"
        case .networkUnavailable:
            "networkUnavailable"
        case .constrainedNetwork:
            "constrainedNetwork"
        case .lowPowerMode:
            "lowPowerMode"
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
        case .syncBaselineRequired:
            "자동 동기화 기준점 필요"
        case .networkUnavailable:
            "네트워크 연결 필요"
        case .constrainedNetwork:
            "데이터 절약 네트워크"
        case .lowPowerMode:
            "저전력 모드"
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
        case .syncBaselineRequired:
            return "먼저 수동 업로드 또는 가져오기로 Mac과 iPhone이 같은 기준 스냅샷을 공유해야 자동 동기화를 시작할 수 있습니다."
        case .networkUnavailable:
            return "네트워크 연결이 없으므로 자동 iCloud 동기화를 보류합니다."
        case .constrainedNetwork:
            return "데이터 절약 모드 네트워크에서는 사용자 요청이 아닌 자동 업로드를 보류합니다."
        case .lowPowerMode:
            return "저전력 모드에서는 배터리 보호를 위해 자동 업로드를 보류합니다."
        }
    }
}

struct VocabCloudSyncRuntimeConditions: Equatable {
    var hasSyncBaseline: Bool
    var isNetworkAvailable: Bool
    var isNetworkConstrained: Bool
    var isLowPowerModeEnabled: Bool
    var isUserInitiated: Bool

    static var automaticDefault: VocabCloudSyncRuntimeConditions {
        VocabCloudSyncRuntimeConditions(
            hasSyncBaseline: VocabCloudBatchSyncUserDefaultsStore().loadCursor() != nil,
            isNetworkAvailable: true,
            isNetworkConstrained: false,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isUserInitiated: false
        )
    }

    static var userInitiatedDefault: VocabCloudSyncRuntimeConditions {
        var conditions = automaticDefault
        conditions.isUserInitiated = true
        return conditions
    }
}

struct VocabCloudSyncReadiness: Equatable {
    var accountState: VocabCloudKitAccountState
    var allowsCloudKitRuntime: Bool
    var hasCloudKitEntitlement: Bool
    var isSchemaCloudKitReady: Bool
    var hasConfirmedFirstUpload: Bool
    var runtimeConditions: VocabCloudSyncRuntimeConditions = .automaticDefault

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
        if !runtimeConditions.hasSyncBaseline {
            result.append(.syncBaselineRequired)
        }
        if !runtimeConditions.isNetworkAvailable {
            result.append(.networkUnavailable)
        }
        if runtimeConditions.isNetworkConstrained && !runtimeConditions.isUserInitiated {
            result.append(.constrainedNetwork)
        }
        if runtimeConditions.isLowPowerModeEnabled && !runtimeConditions.isUserInitiated {
            result.append(.lowPowerMode)
        }

        return result
    }

    var isReadyToEnable: Bool {
        blockers.isEmpty
    }

    var isReadyForBatchSync: Bool {
        isReadyToEnable
    }
}

enum VocabCloudSyncReadinessPolicy {
    static func current(
        accountState: VocabCloudKitAccountState,
        runtimeConditions: VocabCloudSyncRuntimeConditions = .automaticDefault
    ) -> VocabCloudSyncReadiness {
        VocabCloudSyncReadiness(
            accountState: accountState,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: VocabCloudEntitlementStatus.hasRequiredCloudKitContainer(),
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: runtimeConditions.hasSyncBaseline,
            runtimeConditions: runtimeConditions
        )
    }
}
