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
        XCTAssertTrue(configuration.url.lastPathComponent == "VocabMirrored.store")
    }

    func testLocalAndMirroredStoresUseSeparateFiles() throws {
        let local = try VocabModelContainerFactory.makeConfiguration(syncMode: .localOnly)
        let mirrored = try VocabModelContainerFactory.makeConfiguration(syncMode: .cloudKitPrivate)

        XCTAssertNotEqual(local.url, mirrored.url)
        XCTAssertEqual(local.url.deletingLastPathComponent(), mirrored.url.deletingLastPathComponent())
        XCTAssertEqual(local.url.lastPathComponent, "Vocab.store")
        XCTAssertEqual(mirrored.url.lastPathComponent, "VocabMirrored.store")
    }

    func testCloudKitCompatibilityProbeUsesTemporaryMirroredStore() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabCloudProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probeURL = temporaryDirectory.appendingPathComponent("ProbeMirrored.store")
        let configuration = ModelConfiguration(
            "VocabCloudProbe",
            schema: Schema(VocabModelContainerFactory.schemaModels),
            url: probeURL,
            cloudKitDatabase: .private(VocabSyncMode.cloudKitContainerIdentifier)
        )

        XCTAssertEqual(configuration.url, probeURL)
        XCTAssertEqual(configuration.cloudKitContainerIdentifier, VocabSyncMode.cloudKitContainerIdentifier)
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
