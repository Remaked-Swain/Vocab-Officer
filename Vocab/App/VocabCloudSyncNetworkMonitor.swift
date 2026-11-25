import Foundation
import Network
#if os(iOS)
import UIKit
#endif

enum VocabCloudSyncNetworkMonitor {
    /// How long to wait for the first network path before treating the
    /// network as unknown (reported as unavailable).
    static let pathTimeout: Duration = .seconds(1)

    static func currentRuntimeConditions(
        hasSyncBaseline: Bool = VocabCloudBatchSyncUserDefaultsStore().loadCursor() != nil,
        isUserInitiated: Bool = false
    ) async -> VocabCloudSyncRuntimeConditions {
        let path = await currentPath()
        return VocabCloudSyncRuntimeConditions(
            hasSyncBaseline: hasSyncBaseline,
            isNetworkAvailable: path?.status == .satisfied,
            isNetworkConstrained: path?.isConstrained ?? false,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isUserInitiated: isUserInitiated
        )
    }

    /// Live conditions for `VocabSyncWorkPolicy`. macOS reports no battery
    /// level (desktops have none); its Low Power Mode is still honoured.
    static func currentSyncEnvironment(
        isAccountAvailable: Bool,
        isUserInitiated: Bool = false
    ) async -> VocabSyncEnvironment {
        let path = await currentPath()
        let battery = await currentBattery()
        return VocabSyncEnvironment(
            isAccountAvailable: isAccountAvailable,
            isNetworkAvailable: path?.status == .satisfied,
            isNetworkConstrained: path?.isConstrained ?? false,
            isNetworkExpensive: path?.isExpensive ?? false,
            isQuotaExceeded: VocabCloudQuotaStateStore.shared.quotaExceededSince != nil,
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            batteryLevel: battery.level,
            isCharging: battery.isCharging,
            isUserInitiated: isUserInitiated
        )
    }

    /// Decides whether local maintenance work may run now. A deferred job
    /// stays due and is retried on the next lifecycle trigger.
    /// Local work never reads network fields, so this skips starting an
    /// `NWPathMonitor` on every lifecycle trigger.
    static func deferral(
        forLocalWork work: VocabSyncWork,
        isUserInitiated: Bool = false
    ) async -> VocabSyncDeferral? {
        let battery = await currentBattery()
        return VocabSyncWorkPolicy.deferral(
            for: work,
            in: VocabSyncEnvironment(
                thermalState: ProcessInfo.processInfo.thermalState,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                batteryLevel: battery.level,
                isCharging: battery.isCharging,
                isUserInitiated: isUserInitiated
            )
        )
    }

    @MainActor
    private static func currentBattery() -> (level: Float?, isCharging: Bool) {
#if os(iOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let isCharging = device.batteryState == .charging || device.batteryState == .full
        return (level >= 0 ? level : nil, isCharging)
#else
        return (nil, false)
#endif
    }

    /// The monitor's first path. Iterating `NWPathMonitor` starts it and
    /// ending the iteration (or cancelling it at the deadline) stops it.
    private static func currentPath() async -> NWPath? {
        await VocabAsyncDeadline.value(timeout: pathTimeout, timeoutValue: nil) {
            for await path in NWPathMonitor() {
                return path
            }
            return nil
        }
    }
}
