import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabSyncSnapshotTests: XCTestCase {
    func testSnapshotRoundTripPreservesWordsMeaningsSetsAndReviewState() throws {
        let sourceContext = try makeContext()
        let word = WordRecord(term: "commute", createdAt: Date(timeIntervalSince1970: 100))
        let meaning = MeaningRecord(text: "통근하다")
        meaning.successDays = ["2026-07-13"]
        meaning.word = word
        word.meanings.append(meaning)
        let state = ReviewStateRecord()
        state.activePriority = 2
        state.failureCheck = 1
        state.word = word
        word.reviewState = state
        let dailySet = DailySetRecord(seoulDay: "2026-07-13", createdAt: Date(timeIntervalSince1970: 100))
        let item = DailySetItemRecord(orderIndex: 0, entryKind: "newHeadword", wordID: word.id)
        item.set = dailySet
        dailySet.items.append(item)

        sourceContext.insert(word)
        sourceContext.insert(meaning)
        sourceContext.insert(state)
        sourceContext.insert(dailySet)
        sourceContext.insert(item)
        try sourceContext.save()

        let snapshot = try VocabSyncSnapshotService.exportSnapshot(
            context: sourceContext,
            exportedAt: Date(timeIntervalSince1970: 200)
        )
        let destinationContext = try makeContext()

        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: destinationContext)

        let restoredWords = try destinationContext.fetch(FetchDescriptor<WordRecord>())
        let restoredSets = try destinationContext.fetch(FetchDescriptor<DailySetRecord>())
        XCTAssertEqual(restoredWords.map(\.term), ["commute"])
        XCTAssertEqual(restoredWords.first?.meanings.map(\.text), ["통근하다"])
        XCTAssertEqual(restoredWords.first?.reviewState?.activePriority, 2)
        XCTAssertEqual(restoredSets.first?.items.first?.wordID, word.id)
    }

    func testSnapshotRestoreReplacesExistingPhoneLocalData() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "old"))
        try context.save()

        let snapshot = VocabSyncSnapshot(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 200),
            words: [
                VocabSyncSnapshot.WordPayload(
                    id: UUID(),
                    term: "fresh",
                    englishAliases: [],
                    createdAt: Date(timeIntervalSince1970: 100),
                    statusRaw: "active",
                    deletedAt: nil,
                    meanings: [
                        VocabSyncSnapshot.MeaningPayload(
                            id: UUID(),
                            text: "새로운",
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

        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["fresh"])
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
