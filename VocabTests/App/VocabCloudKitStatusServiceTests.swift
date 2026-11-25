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
        let service = VocabCloudKitStatusService(timeout: .milliseconds(10)) {
            try await Task.sleep(for: .seconds(60))
            return .available
        }

        let state = await service.accountStatus()

        XCTAssertFalse(state.isReadyForSync)
        XCTAssertTrue(state.message.contains("시간이 초과"))
    }

    func testAsyncDeadlineReturnsFallbackForStalledCloudOperation() async {
        let result = await VocabAsyncDeadline.value(
            timeout: .milliseconds(10),
            timeoutValue: "timeout"
        ) {
            try? await Task.sleep(for: .seconds(60))
            return "late result"
        }

        XCTAssertEqual(result, "timeout")
    }

    /// The deadline must not wait for an operation that ignores
    /// cancellation, which is why it cannot be a task group.
    func testAsyncDeadlineReturnsOnTimeWhileUncooperativeOperationKeepsRunning() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await VocabAsyncDeadline.value(timeout: .milliseconds(20), timeoutValue: -1) {
            // Blocks without checking cancellation, like a stuck callback API.
            let end = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < end {}
            return 1
        }

        XCTAssertEqual(result, -1)
        XCTAssertLessThan(clock.now - started, .seconds(1))
    }

    func testAsyncDeadlineReturnsOperationValueWithoutWaitingForTheDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now

        let result = await VocabAsyncDeadline.value(timeout: .seconds(60), timeoutValue: "timeout") {
            "answer"
        }

        XCTAssertEqual(result, "answer")
        XCTAssertLessThan(clock.now - started, .seconds(5))
    }

    func testAsyncDeadlineEndsWithFallbackWhenCallerIsCancelled() async {
        let waiter = Task {
            await VocabAsyncDeadline.value(timeout: .seconds(60), timeoutValue: "fallback") {
                try? await Task.sleep(for: .seconds(60))
                return "late"
            }
        }
        waiter.cancel()

        let result = await waiter.value

        XCTAssertEqual(result, "fallback")
    }

    func testCurrentRuntimeConditionsAnswersWithinThePathDeadline() async {
        let clock = ContinuousClock()
        let started = clock.now

        _ = await VocabCloudSyncNetworkMonitor.currentRuntimeConditions(hasSyncBaseline: false)

        XCTAssertLessThan(clock.now - started, VocabCloudSyncNetworkMonitor.pathTimeout + .seconds(1))
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
