import SwiftData
import XCTest
@testable import Vocab

final class VocabImportHistoryTests: XCTestCase {
    func testWithoutCursorRequiresFullAuditAndReportsTheLatestToken() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "existing"))
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: nil, context: context)

        XCTAssertTrue(changes.requiresFullAudit)
        XCTAssertEqual(changes.latestToken, try VocabImportHistoryReader.latestToken(context: context))
    }

    func testReportsTrackedRecordsChangedAfterTheCursor() throws {
        let context = try makeContext()
        let before = WordRecord(term: "before")
        context.insert(before)
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        let after = WordRecord(term: "after")
        context.insert(after)
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertFalse(changes.requiresFullAudit)
        XCTAssertEqual(changes.records, [VocabChangedRecordID(kind: .word, id: after.id)])
        XCTAssertEqual(changes.latestToken, try VocabImportHistoryReader.latestToken(context: context))
    }

    func testReportsDerivedRecordsByTheirOwnKind() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "baseline"))
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        let state = ReviewStateRecord()
        let aid = MemoryAidCacheRecord(
            wordID: UUID(),
            modelRaw: "model",
            promptVersion: 1,
            contentSignature: "signature",
            markdown: "aid"
        )
        context.insert(state)
        context.insert(aid)
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertFalse(changes.requiresFullAudit)
        XCTAssertEqual(changes.records, [
            VocabChangedRecordID(kind: .reviewState, id: state.id),
            VocabChangedRecordID(kind: .memoryAid, id: aid.id)
        ])
    }

    func testIgnoresSyncBookkeeping() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "baseline"))
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        context.insert(CloudBootstrapRecord())
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertFalse(changes.requiresFullAudit)
        XCTAssertTrue(changes.records.isEmpty)
        XCTAssertEqual(changes.latestToken, try VocabImportHistoryReader.latestToken(context: context))
    }

    func testCursorAtTheLatestTransactionReportsNoChange() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "settled"))
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertEqual(changes, VocabImportHistoryChanges(records: [], requiresFullAudit: false, latestToken: cursor))
    }

    func testCursorFromAnotherStoreRequiresFullAudit() throws {
        let otherContext = try makeContext()
        otherContext.insert(WordRecord(term: "other-store"))
        try otherContext.save()
        let foreignCursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: otherContext))
        let context = try makeContext()
        context.insert(WordRecord(term: "this-store"))
        try context.save()

        // Querying with a foreign token matches nothing rather than failing,
        // so without the store check this would report "no change".
        let changes = try VocabImportHistoryReader.changes(since: foreignCursor, context: context)

        XCTAssertTrue(changes.requiresFullAudit)
        XCTAssertEqual(changes.latestToken, try VocabImportHistoryReader.latestToken(context: context))
    }

    func testHardDeleteAfterTheCursorRequiresFullAudit() throws {
        let context = try makeContext()
        let word = WordRecord(term: "hard-deleted")
        context.insert(word)
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        context.delete(word)
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertTrue(changes.requiresFullAudit)
    }

    func testRecordChangedThenHardDeletedRequiresFullAudit() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "baseline"))
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        let meaning = MeaningRecord(text: "사라진 뜻")
        context.insert(meaning)
        try context.save()
        context.delete(meaning)
        try context.save()

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertTrue(changes.requiresFullAudit)
    }

    func testChangesSpanningSeveralPagesAreAllReported() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "baseline"))
        try context.save()
        let cursor = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        var expected = Set<VocabChangedRecordID>()
        for index in 0...VocabImportHistoryReader.pageSize {
            let word = WordRecord(term: "paged-\(index)")
            context.insert(word)
            try context.save()
            expected.insert(VocabChangedRecordID(kind: .word, id: word.id))
        }

        let changes = try VocabImportHistoryReader.changes(since: cursor, context: context)

        XCTAssertFalse(changes.requiresFullAudit)
        XCTAssertEqual(changes.records, expected)
        XCTAssertEqual(changes.latestToken, try VocabImportHistoryReader.latestToken(context: context))
    }

    func testCursorSurvivesAReloadAndAnUnreadableFileLoadsAsNoCursor() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "persisted"))
        try context.save()
        let token = try XCTUnwrap(VocabImportHistoryReader.latestToken(context: context))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabHistoryCursor-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cursor.json")

        XCTAssertNil(VocabImportHistoryCursorStore.load(from: url))
        try VocabImportHistoryCursorStore.save(token, to: url)
        XCTAssertEqual(VocabImportHistoryCursorStore.load(from: url), token)
        try Data("not a token".utf8).write(to: url)
        XCTAssertNil(VocabImportHistoryCursorStore.load(from: url))
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ))
    }
}
