import SwiftData
import XCTest
@testable import Vocab

final class VocabModelContainerFactoryTests: XCTestCase {
    func testDefaultSyncModeKeepsExistingMacStoreLocalOnly() throws {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)

        let configuration = try VocabModelContainerFactory.makeConfiguration(syncMode: .localOnly)

        XCTAssertNil(configuration.cloudKitContainerIdentifier)
        XCTAssertTrue(configuration.url.lastPathComponent == "Vocab.store")
        XCTAssertTrue(configuration.url.deletingLastPathComponent().lastPathComponent == "Vocab")
    }

    func testCloudKitModeUsesPrivateVocabContainer() throws {
        let configuration = try VocabModelContainerFactory.makeConfiguration(syncMode: .cloudKitPrivate)

        XCTAssertEqual(configuration.cloudKitContainerIdentifier, VocabSyncMode.cloudKitContainerIdentifier)
        XCTAssertTrue(configuration.url.lastPathComponent == "Vocab.store")
    }

    func testSyncModeReadsUserDefaultsWhenExplicitlySet() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults, allowsCloudKit: true), .cloudKitPrivate)
    }

    func testCloudKitModeFallsBackToLocalUntilRuntimeAllowsIt() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)
    }

    func testInvalidPersistedSyncModeFallsBackToLocalOnly() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set("invalid", forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)
    }
}
