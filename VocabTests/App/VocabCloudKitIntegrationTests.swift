import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudKitIntegrationTests: XCTestCase {
    func testSignedCloudKitContainerOpensAndReopensWhenOptedIn() throws {
        guard ProcessInfo.processInfo.environment["VOCAB_RUN_CLOUDKIT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set VOCAB_RUN_CLOUDKIT_INTEGRATION=1 in a signed iCloud-capable environment.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabCloudIntegration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("CloudIntegration.store")
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(
            "CloudIntegration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .private(VocabSyncMode.cloudKitContainerIdentifier)
        )

        do {
            _ = try ModelContainer(for: schema, configurations: configuration)
        }
        _ = try ModelContainer(for: schema, configurations: configuration)
    }
}
