import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabLocalStoreCheckpointTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        try super.tearDownWithError()
    }

    func testCreateCheckpointCopiesExistingStoreFilesOnly() throws {
        let root = try makeTemporaryRoot()
        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let storeURL = storeDirectory.appendingPathComponent("Vocab.store")
        let walURL = storeDirectory.appendingPathComponent("Vocab.store-wal")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: walURL)

        let checkpoint = try VocabLocalStoreCheckpointStore.createCheckpoint(
            storeURL: storeURL,
            destinationRoot: checkpointRoot,
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )

        XCTAssertEqual(checkpoint.copiedFiles, ["Vocab.store", "Vocab.store-wal"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.directory.appendingPathComponent("Vocab.store").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.directory.appendingPathComponent("Vocab.store-wal").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.directory.appendingPathComponent("Vocab.store-shm").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.directory.appendingPathComponent("manifest.json").path))
    }

    func testCreateCheckpointFailsWhenPrimaryStoreIsMissing() throws {
        let root = try makeTemporaryRoot()
        let storeURL = root.appendingPathComponent("Missing.store")

        XCTAssertThrowsError(
            try VocabLocalStoreCheckpointStore.createCheckpoint(storeURL: storeURL, destinationRoot: root)
        ) { error in
            XCTAssertEqual(error as? VocabLocalStoreCheckpointError, .missingPrimaryStore(storeURL))
        }
    }

    func testStoreCompanionURLsPreserveSwiftDataSidecarNames() {
        let storeURL = URL(fileURLWithPath: "/tmp/Vocab.store")

        let names = VocabLocalStoreCheckpointStore.storeCompanionURLs(for: storeURL).map(\.lastPathComponent)

        XCTAssertEqual(names, ["Vocab.store", "Vocab.store-wal", "Vocab.store-shm"])
    }

    func testCheckpointRehearsalOpensCopiedSwiftDataStore() throws {
        let root = try makeTemporaryRoot()
        let storeDirectory = root.appendingPathComponent("Store", isDirectory: true)
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let storeURL = storeDirectory.appendingPathComponent("Vocab.store")
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(
            "VocabCheckpointSource",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.insert(WordRecord(term: "checkpoint"))
        try context.save()

        let checkpoint = try VocabLocalStoreCheckpointStore.createCheckpoint(
            storeURL: storeURL,
            destinationRoot: checkpointRoot
        )
        let rehearsal = try VocabLocalStoreCheckpointStore.rehearseCheckpoint(checkpoint)

        XCTAssertEqual(rehearsal.wordCount, 1)
        XCTAssertEqual(rehearsal.dailySetCount, 0)
        XCTAssertEqual(rehearsal.attemptCount, 0)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }
}
