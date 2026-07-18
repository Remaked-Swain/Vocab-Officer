import Foundation
import Network

enum VocabCloudSyncNetworkMonitor {
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

    private static func currentPath() async -> NWPath? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "VocabCloudSyncNetworkMonitor")
            let gate = VocabCloudSyncContinuationGate()

            let resume: @Sendable (NWPath?) -> Void = { path in
                gate.resumeOnce {
                    monitor.cancel()
                    continuation.resume(returning: path)
                }
            }

            monitor.pathUpdateHandler = { path in
                resume(path)
            }
            monitor.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 1) {
                resume(nil)
            }
        }
    }
}

private final class VocabCloudSyncContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        action()
    }
}
