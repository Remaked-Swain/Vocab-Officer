import Foundation
import Network

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
