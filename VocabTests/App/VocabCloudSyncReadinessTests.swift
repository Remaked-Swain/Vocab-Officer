import XCTest
@testable import Vocab

final class VocabCloudSyncReadinessTests: XCTestCase {
    func testReadinessRequiresEverySafetyCondition() {
        let readiness = VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: readyRuntimeConditions()
        )

        XCTAssertTrue(readiness.isReadyToEnable)
        XCTAssertTrue(readiness.blockers.isEmpty)
    }

    func testUnavailableAccountBlocksSyncEvenWhenOtherConditionsPass() {
        let readiness = VocabCloudSyncReadiness(
            accountState: .noAccount,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: readyRuntimeConditions()
        )

        XCTAssertFalse(readiness.isReadyToEnable)
        XCTAssertEqual(readiness.blockers, [.accountUnavailable(.noAccount)])
    }

    func testCurrentPolicyAllowsBatchSyncWhenRuntimeConditionsAreSafe() {
        let readiness = VocabCloudSyncReadinessPolicy.current(
            accountState: .available,
            runtimeConditions: readyRuntimeConditions()
        )

        XCTAssertTrue(readiness.isReadyForBatchSync)
        XCTAssertFalse(readiness.blockers.contains(.syncBaselineRequired))
    }

    func testUnknownAccountStateRemainsBlockedUntilUserChecksICloud() {
        let readiness = VocabCloudSyncReadinessPolicy.current(
            accountState: .unknown,
            runtimeConditions: readyRuntimeConditions()
        )

        XCTAssertFalse(readiness.isReadyToEnable)
        XCTAssertTrue(readiness.blockers.contains(.accountUnavailable(.unknown)))
    }

    func testBatchSyncRequiresBaselineBeforeAutomaticRun() {
        let readiness = VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: VocabCloudSyncRuntimeConditions(
                hasSyncBaseline: false,
                isNetworkAvailable: true,
                isNetworkConstrained: false,
                isLowPowerModeEnabled: false,
                isUserInitiated: false
            )
        )

        XCTAssertFalse(readiness.isReadyForBatchSync)
        XCTAssertTrue(readiness.blockers.contains(.syncBaselineRequired))
    }

    func testAutomaticBatchSyncIsDeferredOnConstrainedNetworkAndLowPowerMode() {
        let readiness = VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: VocabCloudSyncRuntimeConditions(
                hasSyncBaseline: true,
                isNetworkAvailable: true,
                isNetworkConstrained: true,
                isLowPowerModeEnabled: true,
                isUserInitiated: false
            )
        )

        XCTAssertFalse(readiness.isReadyForBatchSync)
        XCTAssertTrue(readiness.blockers.contains(.constrainedNetwork))
        XCTAssertTrue(readiness.blockers.contains(.lowPowerMode))
    }

    private func readyRuntimeConditions() -> VocabCloudSyncRuntimeConditions {
        VocabCloudSyncRuntimeConditions(
            hasSyncBaseline: true,
            isNetworkAvailable: true,
            isNetworkConstrained: false,
            isLowPowerModeEnabled: false,
            isUserInitiated: false
        )
    }
}
