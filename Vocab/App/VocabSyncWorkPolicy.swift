import Foundation

/// App-scheduled sync work. CloudKit mirroring itself (push-driven import,
/// export of saves) is scheduled by the system and is not gated here.
enum VocabSyncWork: Sendable {
    /// Re-derives state for records changed by an import. Local and cheap.
    case incrementalReconciliation
    /// Scans the whole library. Local but CPU- and disk-heavy.
    case fullAudit
    /// Copies the store into a recovery generation. Local, disk-heavy.
    case recoveryReplicaRefresh
    /// Uploads the Mac library to iCloud for the first time. Network-heavy.
    case firstUpload
}

/// Why a piece of work waits; each has a readable Korean reason.
enum VocabSyncDeferral: Equatable, Sendable {
    case accountUnavailable
    case networkUnavailable
    case constrainedNetwork
    case expensiveNetwork
    case quotaExceeded
    case thermalPressure
    case lowPowerMode
    case lowBattery

    var userFacingReason: String {
        switch self {
        case .accountUnavailable: "iCloud 계정을 사용할 수 없어 기다리는 중입니다."
        case .networkUnavailable: "네트워크에 연결되면 진행합니다."
        case .constrainedNetwork: "저데이터 모드가 꺼지거나 Wi-Fi에 연결되면 진행합니다."
        case .expensiveNetwork: "Wi-Fi 등 데이터 요금이 들지 않는 네트워크에서 진행합니다."
        case .quotaExceeded: "iCloud 저장 공간이 확보되면 진행합니다."
        case .thermalPressure: "기기 온도가 내려가면 진행합니다."
        case .lowPowerMode: "저전력 모드가 꺼지면 진행합니다."
        case .lowBattery: "충전 중이거나 배터리가 충분할 때 진행합니다."
        }
    }
}

/// The device and account conditions one decision is made under.
struct VocabSyncEnvironment: Equatable, Sendable {
    var isAccountAvailable = true
    var isNetworkAvailable = true
    var isNetworkConstrained = false
    var isNetworkExpensive = false
    var isQuotaExceeded = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var isLowPowerModeEnabled = false
    /// 0...1, or `nil` where the device reports none (desktop Macs).
    var batteryLevel: Float?
    var isCharging = false
    /// A user's explicit request overrides cost and battery deferrals,
    /// never missing prerequisites or thermal pressure.
    var isUserInitiated = false
}

enum VocabSyncWorkPolicy {
    static let lowBatteryThreshold: Float = 0.2

    /// `nil` means run now. Checks run in order of how hard the blocker
    /// is, so the first reason is the one worth showing.
    static func deferral(for work: VocabSyncWork, in environment: VocabSyncEnvironment) -> VocabSyncDeferral? {
        switch work {
        case .incrementalReconciliation:
            // Keeps imported data consistent; deferring would show stale
            // review state, and it only touches changed records.
            return nil
        case .fullAudit, .recoveryReplicaRefresh:
            return heavyLocalDeferral(in: environment)
        case .firstUpload:
            return firstUploadDeferral(in: environment)
        }
    }

    private static func heavyLocalDeferral(in environment: VocabSyncEnvironment) -> VocabSyncDeferral? {
        if environment.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .thermalPressure }
        guard !environment.isUserInitiated else { return nil }
        return powerDeferral(in: environment)
    }

    private static func firstUploadDeferral(in environment: VocabSyncEnvironment) -> VocabSyncDeferral? {
        if !environment.isAccountAvailable { return .accountUnavailable }
        if !environment.isNetworkAvailable { return .networkUnavailable }
        if environment.isQuotaExceeded { return .quotaExceeded }
        if environment.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .thermalPressure }
        guard !environment.isUserInitiated else { return nil }
        if environment.isNetworkConstrained { return .constrainedNetwork }
        if environment.isNetworkExpensive { return .expensiveNetwork }
        return powerDeferral(in: environment)
    }

    private static func powerDeferral(in environment: VocabSyncEnvironment) -> VocabSyncDeferral? {
        if environment.isLowPowerModeEnabled { return .lowPowerMode }
        if let level = environment.batteryLevel, level < lowBatteryThreshold, !environment.isCharging {
            return .lowBattery
        }
        return nil
    }
}
