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
        let snapshot = makeSnapshot(term: "subway", meaning: "지하철")
        let service = VocabCloudSnapshotSyncService(store: MemorySnapshotStore(snapshot: snapshot))

        let result = try await service.replaceLocalStoreFromCloud(context: context)

        XCTAssertEqual(result?.wordCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["subway"])
    }

    func testInspectCloudSnapshotReturnsSummaryWithoutReplacingLocalStore() async throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "local"))
        try context.save()
        let snapshot = makeSnapshot(term: "cloud", meaning: "구름")
        let service = VocabCloudSnapshotSyncService(store: MemorySnapshotStore(snapshot: snapshot))

        let result = try await service.inspectCloudSnapshot()

        XCTAssertEqual(result?.wordCount, 1)
        XCTAssertEqual(result?.dailySetCount, 0)
        XCTAssertEqual(result?.exportedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["local"])
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeSnapshot(term: String, meaning: String) -> VocabSyncSnapshot {
        VocabSyncSnapshot(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 300),
            words: [
                VocabSyncSnapshot.WordPayload(
                    id: UUID(),
                    term: term,
                    englishAliases: [],
                    createdAt: Date(timeIntervalSince1970: 100),
                    statusRaw: "active",
                    deletedAt: nil,
                    meanings: [
                        VocabSyncSnapshot.MeaningPayload(
                            id: UUID(),
                            text: meaning,
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
