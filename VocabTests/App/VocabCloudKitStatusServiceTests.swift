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
}
