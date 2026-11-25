import CloudKit
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudQuotaTests: XCTestCase {
    func testClassifierFindsQuotaDirectlyInPartialFailuresAndUnderlyingErrors() {
        let quota = CKError(.quotaExceeded)
        let partial = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "a"): CKError(.networkFailure),
                                         CKRecord.ID(recordName: "b"): quota]
        ])
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSUnderlyingErrorKey: partial])

        XCTAssertTrue(VocabCloudQuotaClassifier.isQuotaExceeded(quota))
        XCTAssertTrue(VocabCloudQuotaClassifier.isQuotaExceeded(partial))
        XCTAssertTrue(VocabCloudQuotaClassifier.isQuotaExceeded(wrapped))
        XCTAssertFalse(VocabCloudQuotaClassifier.isQuotaExceeded(CKError(.networkFailure)))
    }

    func testSyncEventsMapToQuotaOrSuccessfulExport() {
        XCTAssertEqual(VocabCloudSyncEventOutcome.classify(isExport: true, succeeded: false, error: CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(VocabCloudSyncEventOutcome.classify(isExport: false, succeeded: false, error: CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(VocabCloudSyncEventOutcome.classify(isExport: true, succeeded: true, error: nil), .exportSucceeded)
        XCTAssertEqual(VocabCloudSyncEventOutcome.classify(isExport: false, succeeded: true, error: nil), .other)
    }

    func testQuotaOutranksAccountStateUntilCleared() {
        let detectedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            VocabCloudSyncAvailability.resolve(account: .available, quotaExceededSince: detectedAt, isChecking: true),
            .quotaExceeded(detectedAt: detectedAt)
        )
        XCTAssertEqual(VocabCloudSyncAvailability.resolve(account: .available, quotaExceededSince: nil, isChecking: false), .available)
        XCTAssertEqual(VocabCloudSyncAvailability.resolve(account: .noAccount, quotaExceededSince: nil, isChecking: false), .accountUnavailable)
    }

    func testWarningPersistsAlertsOnceAndClearsOnlyOnExport() async {
        let defaults = isolatedDefaults()
        let store = VocabCloudQuotaStateStore(defaults: defaults)
        let status = VocabCloudQuotaStatus(store: store, probe: VocabCloudHealthProbe(save: { _ in }, delete: { _ in }))

        status.noteQuotaExceeded()
        XCTAssertTrue(status.isShowingQuotaAlert)
        status.isShowingQuotaAlert = false
        status.noteQuotaExceeded()
        XCTAssertFalse(status.isShowingQuotaAlert, "the alert shows only on the first transition")

        // A relaunch reads the persisted warning.
        let relaunched = VocabCloudQuotaStatus(store: store, probe: VocabCloudHealthProbe(save: { _ in }, delete: { _ in }))
        XCTAssertNotNil(relaunched.quotaExceededSince)

        // A writable probe alone keeps the warning; a real export clears it.
        await relaunched.recheck()
        XCTAssertNotNil(relaunched.quotaExceededSince)
        relaunched.noteExportSucceeded()
        XCTAssertNil(relaunched.quotaExceededSince)
        XCTAssertNil(store.quotaExceededSince)
    }

    func testDirectRequestErrorsReachTheUIStatusAndAlertOnce() async {
        let store = VocabCloudQuotaStateStore(defaults: isolatedDefaults())
        let status = VocabCloudQuotaStatus(store: store, probe: VocabCloudHealthProbe(save: { _ in }, delete: { _ in }))

        XCTAssertNil(VocabCloudQuotaStatus.report(CKError(.networkFailure), to: { status }))
        await VocabCloudQuotaStatus.report(CKError(.quotaExceeded), to: { status })?.value
        XCTAssertNotNil(status.quotaExceededSince)
        XCTAssertTrue(status.isShowingQuotaAlert)

        status.isShowingQuotaAlert = false
        // A later export-event detection of the same full quota stays quiet.
        status.noteQuotaExceeded()
        XCTAssertFalse(status.isShowingQuotaAlert)
    }

    func testSuccessfulExportWhileHealthyChangesNothing() {
        let store = VocabCloudQuotaStateStore(defaults: isolatedDefaults())
        let status = VocabCloudQuotaStatus(store: store, probe: VocabCloudHealthProbe(save: { _ in }, delete: { _ in }))

        status.noteExportSucceeded()

        XCTAssertNil(status.quotaExceededSince)
        XCTAssertFalse(status.isShowingQuotaAlert)
    }

    func testProbeReportsQuotaAndCleansUpAfterAWrite() async {
        let full = VocabCloudHealthProbe(save: { _ in throw CKError(.quotaExceeded) }, delete: { _ in })
        let result = await full.check()
        XCTAssertEqual(result, .quotaExceeded)

        let deleted = DeletedRecordIDs()
        let writable = VocabCloudHealthProbe(save: { _ in }, delete: { await deleted.append($0.recordName) })
        let writableResult = await writable.check()
        XCTAssertEqual(writableResult, .writable)
        let names = await deleted.names
        XCTAssertEqual(names, [VocabCloudHealthProbe.recordName])
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "VocabCloudQuotaTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

private actor DeletedRecordIDs {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}
