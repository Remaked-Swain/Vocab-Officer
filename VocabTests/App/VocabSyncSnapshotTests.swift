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
        let session = TestSessionRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.mixed.rawValue,
            seoulDay: "2026-07-13",
            wordIDs: [word.id],
            wasReduced: false,
            startedAt: Date(timeIntervalSince1970: 120)
        )
        session.completedAt = Date(timeIntervalSince1970: 180)
        let attempt = AttemptRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.mixed.rawValue,
            sessionID: session.id,
            questionIndex: 0,
            seoulDay: "2026-07-13",
            prompt: "commute",
            submittedAnswer: "통근하다",
            automaticJudgementRaw: FinalResult.correct.rawValue,
            finalJudgementRaw: FinalResult.correct.rawValue,
            matchedMeaningID: meaning.id,
            answeredAt: Date(timeIntervalSince1970: 160)
        )
        attempt.word = word
        let aggregate = AnonymousAggregateRecord(seoulDay: "2026-07-13", modeRaw: SessionMode.mixed.rawValue)
        aggregate.correctCount = 1
        let cache = MemoryAidCacheRecord(
            wordID: word.id,
            modelRaw: "gemini-test",
            promptVersion: 1,
            contentSignature: "signature",
            markdown: "memory aid",
            generatedAt: Date(timeIntervalSince1970: 190)
        )

        sourceContext.insert(word)
        sourceContext.insert(meaning)
        sourceContext.insert(state)
        sourceContext.insert(dailySet)
        sourceContext.insert(item)
        sourceContext.insert(session)
        sourceContext.insert(attempt)
        sourceContext.insert(aggregate)
        sourceContext.insert(cache)
        try sourceContext.save()

        let snapshot = try VocabSyncSnapshotService.exportSnapshot(
            context: sourceContext,
            exportedAt: Date(timeIntervalSince1970: 200)
        )
        let destinationContext = try makeContext()

        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: destinationContext)

        let restoredWords = try destinationContext.fetch(FetchDescriptor<WordRecord>())
        let restoredSets = try destinationContext.fetch(FetchDescriptor<DailySetRecord>())
        let restoredSessions = try destinationContext.fetch(FetchDescriptor<TestSessionRecord>())
        let restoredAttempts = try destinationContext.fetch(FetchDescriptor<AttemptRecord>())
        let restoredAggregates = try destinationContext.fetch(FetchDescriptor<AnonymousAggregateRecord>())
        let restoredCaches = try destinationContext.fetch(FetchDescriptor<MemoryAidCacheRecord>())
        XCTAssertEqual(restoredWords.map(\.term), ["commute"])
        XCTAssertEqual(restoredWords.first?.meanings.map(\.text), ["통근하다"])
        XCTAssertEqual(restoredWords.first?.reviewState?.activePriority, 2)
        XCTAssertEqual(restoredSets.first?.items.first?.wordID, word.id)
        XCTAssertEqual(restoredSessions.first?.id, session.id)
        XCTAssertEqual(restoredSessions.first?.wordIDs, [word.id])
        XCTAssertEqual(restoredAttempts.first?.id, attempt.id)
        XCTAssertEqual(restoredAttempts.first?.word?.id, word.id)
        XCTAssertEqual(restoredAttempts.first?.matchedMeaningID, meaning.id)
        XCTAssertEqual(restoredAggregates.first?.correctCount, 1)
        XCTAssertEqual(restoredCaches.first?.wordID, word.id)
        XCTAssertEqual(restoredCaches.first?.markdown, "memory aid")
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

    func testLegacySnapshotWithoutFullFidelityCollectionsDecodesWithEmptyCollections() throws {
        let json = """
        {
          "formatVersion": 1,
          "exportedAt": "2026-07-14T00:00:00Z",
          "words": [],
          "dailySets": []
        }
        """
        let snapshot = try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabSyncSnapshot.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(snapshot.formatVersion, 1)
        XCTAssertTrue(snapshot.testSessions.isEmpty)
        XCTAssertTrue(snapshot.attempts.isEmpty)
        XCTAssertTrue(snapshot.anonymousAggregates.isEmpty)
        XCTAssertTrue(snapshot.memoryAidCaches.isEmpty)
    }

    func testInvalidSnapshotDoesNotDeleteExistingPhoneLocalData() throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "keep"))
        try context.save()
        let missingWordID = UUID()
        let invalidSnapshot = VocabSyncSnapshot(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 200),
            words: [],
            dailySets: [
                VocabSyncSnapshot.DailySetPayload(
                    id: UUID(),
                    seoulDay: "2026-07-13",
                    createdAt: Date(timeIntervalSince1970: 100),
                    completedAt: nil,
                    items: [
                        VocabSyncSnapshot.DailySetItemPayload(
                            id: UUID(),
                            orderIndex: 0,
                            entryKind: "newHeadword",
                            wordID: missingWordID
                        )
                    ]
                )
            ]
        )

        XCTAssertThrowsError(try VocabSyncSnapshotService.replaceLocalStore(with: invalidSnapshot, context: context)) { error in
            XCTAssertEqual(
                error as? VocabSyncSnapshotService.SnapshotValidationError,
                .missingWordForDailySetItem(missingWordID)
            )
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["keep"])
    }

    func testMigrationServiceCopiesFullFidelitySnapshotIntoMirroredContext() throws {
        let localContext = try makeContext()
        let mirroredContext = try makeContext()
        let word = WordRecord(term: "mirror")
        let meaning = MeaningRecord(text: "거울")
        meaning.word = word
        word.meanings.append(meaning)
        let session = TestSessionRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.mixed.rawValue,
            seoulDay: "2026-07-14",
            wordIDs: [word.id],
            wasReduced: true
        )
        let attempt = AttemptRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.mixed.rawValue,
            sessionID: session.id,
            questionIndex: 0,
            seoulDay: "2026-07-14",
            prompt: "mirror",
            submittedAnswer: "거울",
            automaticJudgementRaw: FinalResult.correct.rawValue,
            finalJudgementRaw: FinalResult.correct.rawValue,
            matchedMeaningID: meaning.id
        )
        attempt.word = word
        localContext.insert(word)
        localContext.insert(meaning)
        localContext.insert(session)
        localContext.insert(attempt)
        try localContext.save()

        let report = try VocabStoreMigrationService.migrateLocalSnapshotToMirroredStore(
            localContext: localContext,
            mirroredContext: mirroredContext,
            createCheckpoint: {
                VocabLocalStoreCheckpoint(
                    directory: URL(fileURLWithPath: "/tmp/VocabStoreCheckpoint-test", isDirectory: true),
                    copiedFiles: ["Vocab.store"]
                )
            }
        )

        XCTAssertEqual(report.checkpointDirectoryName, "VocabStoreCheckpoint-test")
        XCTAssertEqual(report.wordCount, 1)
        XCTAssertEqual(report.testSessionCount, 1)
        XCTAssertEqual(report.attemptCount, 1)
        XCTAssertFalse(report.contentFingerprint.isEmpty)
        XCTAssertEqual(try mirroredContext.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["mirror"])
        XCTAssertEqual(try mirroredContext.fetch(FetchDescriptor<AttemptRecord>()).first?.word?.id, word.id)
    }

    func testMigrationServiceBlocksWhenMirroredStoreAlreadyContainsData() throws {
        let localContext = try makeContext()
        let mirroredContext = try makeContext()
        localContext.insert(WordRecord(term: "source"))
        mirroredContext.insert(WordRecord(term: "existing-cloud"))
        try localContext.save()
        try mirroredContext.save()

        XCTAssertThrowsError(
            try VocabStoreMigrationService.migrateLocalSnapshotToMirroredStore(
                localContext: localContext,
                mirroredContext: mirroredContext,
                createCheckpoint: {
                    VocabLocalStoreCheckpoint(
                        directory: URL(fileURLWithPath: "/tmp/VocabStoreCheckpoint-test", isDirectory: true),
                        copiedFiles: ["Vocab.store"]
                    )
                }
            )
        ) { error in
            guard case .mirroredStoreAlreadyContainsData(let counts) = error as? VocabStoreMigrationError else {
                return XCTFail("Expected mirroredStoreAlreadyContainsData, got \(error)")
            }
            XCTAssertEqual(counts.words, 1)
        }
        XCTAssertEqual(try mirroredContext.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["existing-cloud"])
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }
}
