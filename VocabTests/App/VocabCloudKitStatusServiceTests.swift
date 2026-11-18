import CloudKit
import XCTest
@testable import Vocab

final class VocabCloudKitStatusServiceTests: XCTestCase {
    func testAccountStatusMappingKeepsAvailableAsSyncReady() {
        let state = VocabCloudKitStatusService.map(.available)

        XCTAssertEqual(state, .available)
        XCTAssertTrue(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("CloudKit"))
    }

    func testAccountStatusMappingExplainsNoAccount() {
        let state = VocabCloudKitStatusService.map(.noAccount)

        XCTAssertEqual(state, .noAccount)
        XCTAssertFalse(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("iCloud에 로그인"))
    }

    func testAccountStatusMappingExplainsRestrictions() {
        let state = VocabCloudKitStatusService.map(.restricted)

        XCTAssertEqual(state, .restricted)
        XCTAssertFalse(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("제한"))
    }

    func testAccountStatusMappingHandlesTemporaryUnavailableNaturally() {
        let state = VocabCloudKitStatusService.map(.temporarilyUnavailable)

        XCTAssertFalse(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("일시적으로"))
    }

    func testAccountStatusTimeoutReturnsActionableFailure() async {
        let service = VocabCloudKitStatusService(timeout: 0.01) {
            try await Task.sleep(for: .seconds(60))
            return .available
        }

        let state = await service.accountStatus()

        XCTAssertFalse(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("시간이 초과"))
    }

    func testAsyncDeadlineReturnsFallbackForStalledCloudOperation() async {
        let result = await VocabAsyncDeadline.value(
            timeoutNanoseconds: 10_000_000,
            timeoutValue: "timeout"
        ) {
            try? await Task.sleep(for: .seconds(60))
            return "late result"
        }

        XCTAssertEqual(result, "timeout")
    }

    func testSuccessfulPrivateDatabaseClaimProvesCloudKitAvailability() {
        let completedClaim = VocabBootstrapServerClaim(
            request: VocabBootstrapClaimRequest(
                claimID: UUID(),
                requestID: UUID(),
                ownerDeviceID: "device",
                sourceFingerprint: "fingerprint",
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                createdAt: .now
            ),
            state: .completed,
            createdAt: .now,
            updatedAt: .now
        )

        let resolved = VocabCloudKitStatusService.resolve(
            accountState: .temporarilyUnavailable("timeout"),
            claimStatus: .available(completedClaim)
        )

        XCTAssertEqual(resolved, .available)
    }

    func testUnavailableClaimDoesNotMaskAccountFailure() {
        let accountState = VocabCloudKitAccountState.temporarilyUnavailable("timeout")

        let resolved = VocabCloudKitStatusService.resolve(
            accountState: accountState,
            claimStatus: .unavailable("claim failed")
        )

        XCTAssertEqual(resolved, accountState)
    }
}
