import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudSnapshotSyncServiceTests: XCTestCase {
    func testUploadLocalSnapshotSavesExportedWordsToStore() async throws {
        let context = try makeContext()
        let word = WordRecord(term: "train")
        let meaning = MeaningRecord(text: "기차")
        meaning.word = word
        word.meanings.append(meaning)
        context.insert(word)
        context.insert(meaning)
        try context.save()
        let store = MemorySnapshotStore()
        let service = VocabCloudSnapshotSyncService(store: store)

        let result = try await service.uploadLocalSnapshot(
            context: context,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(result.wordCount, 1)
        XCTAssertEqual(store.snapshot?.words.first?.term, "train")
    }

    func testDownloadSnapshotReplacesPhoneLocalStore() async throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "old"))
        try context.save()
        let snapshot = VocabSyncSnapshot(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 300),
            words: [
                VocabSyncSnapshot.WordPayload(
                    id: UUID(),
                    term: "subway",
                    englishAliases: [],
                    createdAt: Date(timeIntervalSince1970: 100),
                    statusRaw: "active",
                    deletedAt: nil,
                    meanings: [
                        VocabSyncSnapshot.MeaningPayload(
                            id: UUID(),
                            text: "지하철",
                            isCore: true,
                            aliases: [],
                            successDays: []
                        )
                    ],
                    reviewState: nil
                )
            ],
            dailySets: []
        )
        let service = VocabCloudSnapshotSyncService(store: MemorySnapshotStore(snapshot: snapshot))

        let result = try await service.replaceLocalStoreFromCloud(context: context)

        XCTAssertEqual(result?.wordCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["subway"])
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(VocabModelContainerFactory.schemaModels),
            configurations: configuration
        )
        return ModelContext(container)
    }
}

private final class MemorySnapshotStore: VocabCloudSnapshotStoring {
    var snapshot: VocabSyncSnapshot?

    init(snapshot: VocabSyncSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func save(_ snapshot: VocabSyncSnapshot) async throws {
        self.snapshot = snapshot
    }

    func load() async throws -> VocabSyncSnapshot? {
        snapshot
    }
}
