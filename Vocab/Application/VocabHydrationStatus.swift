import Foundation

enum VocabHydrationState: String, Equatable, Sendable {
    case localOnly
    case awaitingBootstrapMetadata
    case hydrating
    case reconciling
    case ready
    case failed

    var userFacingTitle: String {
        switch self {
        case .localOnly: "이 기기에 저장됨"
        case .awaitingBootstrapMetadata: "최초 동기화 정보 대기 중"
        case .hydrating: "iCloud 데이터 받는 중"
        case .reconciling: "데이터 검증 중"
        case .ready: "사용 가능"
        case .failed: "확인 필요"
        }
    }
}

enum VocabSyncHealth: Equatable, Sendable {
    case healthy
    case incompleteCanonicalState
    case integrityInvalid
}

struct VocabEntityCounts: Codable, Equatable, Sendable {
    var words: Int
    var meanings: Int
    var dailySets: Int
    var dailySetItems: Int
    var testSessions: Int
    var attempts: Int
    var anonymousAggregates: Int
    var memoryAidCaches: Int
    var tombstones: Int

    static let zero = VocabEntityCounts(
        words: 0,
        meanings: 0,
        dailySets: 0,
        dailySetItems: 0,
        testSessions: 0,
        attempts: 0,
        anonymousAggregates: 0,
        memoryAidCaches: 0,
        tombstones: 0
    )

    func satisfies(_ metadata: CloudBootstrapRecord) -> Bool {
        words >= metadata.expectedWordCount
            && meanings >= metadata.expectedMeaningCount
            && dailySets >= metadata.expectedDailySetCount
            && dailySetItems >= metadata.expectedDailySetItemCount
            && testSessions >= metadata.expectedTestSessionCount
            && attempts >= metadata.expectedAttemptCount
            && anonymousAggregates >= metadata.expectedAnonymousAggregateCount
            && memoryAidCaches >= metadata.expectedMemoryAidCacheCount
            && tombstones >= metadata.expectedTombstoneCount
    }
}

struct VocabHydrationStatus: Equatable, Sendable {
    let state: VocabHydrationState
    let counts: VocabEntityCounts
    let expectedBootstrapUUID: UUID?
    let message: String?

    var permitsUserDataMutation: Bool {
        health == .healthy
    }

    var health: VocabSyncHealth {
        switch state {
        case .localOnly, .ready:
            .healthy
        case .awaitingBootstrapMetadata, .hydrating, .reconciling:
            .incompleteCanonicalState
        case .failed:
            .integrityInvalid
        }
    }
}

enum VocabCloudReconciliationError: LocalizedError, Equatable {
    case hydrationNotReady(VocabHydrationState)
    case unsupportedSchemaVersion(Int)
    case bootstrapTokenRequired
    case attemptReplayConflicts([VocabAttemptReplayConflict])

    var errorDescription: String? {
        switch self {
        case .hydrationNotReady(let state):
            "iCloud 데이터 준비 상태가 \(state.userFacingTitle)이어서 변경 작업을 중단했습니다."
        case .unsupportedSchemaVersion(let version):
            "현재 앱에서 읽을 수 없는 iCloud 동기화 정보입니다(버전 \(version)). 앱을 업데이트한 뒤 다시 시도하세요."
        case .bootstrapTokenRequired:
            "Mac 최초 iCloud 전환에는 사용자 확인으로 발급된 일회성 인증 정보가 필요합니다."
        case .attemptReplayConflicts(let conflicts):
            "동일한 테스트 문항의 답안 기록이 \(conflicts.count)건 충돌하여 학습 상태 재계산을 중단했습니다."
        }
    }
}
