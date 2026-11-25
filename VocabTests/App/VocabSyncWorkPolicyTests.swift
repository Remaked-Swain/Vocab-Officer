import XCTest
@testable import Vocab

final class VocabSyncWorkPolicyTests: XCTestCase {
    private func deferral(_ work: VocabSyncWork, _ configure: (inout VocabSyncEnvironment) -> Void = { _ in }) -> VocabSyncDeferral? {
        var environment = VocabSyncEnvironment()
        configure(&environment)
        return VocabSyncWorkPolicy.deferral(for: work, in: environment)
    }

    func testEverythingRunsUnderGoodConditions() {
        for work in [VocabSyncWork.incrementalReconciliation, .fullAudit, .recoveryReplicaRefresh, .firstUpload] {
            XCTAssertNil(deferral(work))
        }
    }

    func testIncrementalReconciliationNeverWaits() {
        XCTAssertNil(deferral(.incrementalReconciliation) {
            $0.isNetworkAvailable = false
            $0.isLowPowerModeEnabled = true
            $0.thermalState = .critical
        })
    }

    func testFirstUploadWaitsForPrerequisitesInOrder() {
        XCTAssertEqual(deferral(.firstUpload) { $0.isAccountAvailable = false; $0.isNetworkAvailable = false }, .accountUnavailable)
        XCTAssertEqual(deferral(.firstUpload) { $0.isNetworkAvailable = false }, .networkUnavailable)
        XCTAssertEqual(deferral(.firstUpload) { $0.isQuotaExceeded = true }, .quotaExceeded)
        XCTAssertEqual(deferral(.firstUpload) { $0.isNetworkConstrained = true }, .constrainedNetwork)
        XCTAssertEqual(deferral(.firstUpload) { $0.isNetworkExpensive = true }, .expensiveNetwork)
    }

    func testHeavyLocalWorkIgnoresNetworkButWaitsForPowerAndHeat() {
        XCTAssertNil(deferral(.fullAudit) { $0.isNetworkAvailable = false; $0.isNetworkExpensive = true })
        XCTAssertEqual(deferral(.fullAudit) { $0.isLowPowerModeEnabled = true }, .lowPowerMode)
        XCTAssertEqual(deferral(.recoveryReplicaRefresh) { $0.batteryLevel = 0.1 }, .lowBattery)
        XCTAssertNil(deferral(.recoveryReplicaRefresh) { $0.batteryLevel = 0.1; $0.isCharging = true })
        XCTAssertNil(deferral(.fullAudit) { $0.batteryLevel = nil })
        XCTAssertEqual(deferral(.fullAudit) { $0.thermalState = .serious }, .thermalPressure)
    }

    func testUserRequestOverridesCostAndPowerButNotPrerequisitesOrHeat() {
        XCTAssertNil(deferral(.firstUpload) {
            $0.isUserInitiated = true
            $0.isNetworkConstrained = true
            $0.isNetworkExpensive = true
            $0.isLowPowerModeEnabled = true
            $0.batteryLevel = 0.05
        })
        XCTAssertEqual(deferral(.firstUpload) { $0.isUserInitiated = true; $0.isNetworkAvailable = false }, .networkUnavailable)
        XCTAssertEqual(deferral(.fullAudit) { $0.isUserInitiated = true; $0.thermalState = .critical }, .thermalPressure)
    }

    func testEveryDeferralHasAReadableReason() {
        let all: [VocabSyncDeferral] = [
            .accountUnavailable, .networkUnavailable, .constrainedNetwork, .expensiveNetwork,
            .quotaExceeded, .thermalPressure, .lowPowerMode, .lowBattery
        ]
        for deferral in all {
            XCTAssertFalse(deferral.userFacingReason.isEmpty)
        }
    }
}
