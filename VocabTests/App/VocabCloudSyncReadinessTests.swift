import XCTest
@testable import Vocab

final class VocabCloudSyncReadinessTests: XCTestCase {
    func testReadinessRequiresEverySafetyCondition() {
        let readiness = VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true
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
            hasConfirmedFirstUpload: true
        )

        XCTAssertFalse(readiness.isReadyToEnable)
        XCTAssertEqual(readiness.blockers, [.accountUnavailable(.noAccount)])
    }

    func testCurrentPolicyKeepsCloudKitActivationBlockedForDataSafety() {
        let readiness = VocabCloudSyncReadinessPolicy.current(accountState: .available)

        XCTAssertFalse(readiness.isReadyToEnable)
        XCTAssertTrue(readiness.blockers.contains(.runtimeDisabled))
        XCTAssertTrue(readiness.blockers.contains(.entitlementPending))
        XCTAssertTrue(readiness.blockers.contains(.schemaMigrationRequired))
        XCTAssertTrue(readiness.blockers.contains(.firstUploadConfirmationRequired))
    }

    func testUnknownAccountStateRemainsBlockedUntilUserChecksICloud() {
        let readiness = VocabCloudSyncReadinessPolicy.current(accountState: .unknown)

        XCTAssertFalse(readiness.isReadyToEnable)
        XCTAssertTrue(readiness.blockers.contains(.accountUnavailable(.unknown)))
    }
}
