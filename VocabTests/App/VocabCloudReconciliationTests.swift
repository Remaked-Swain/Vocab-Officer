import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudReconciliationTests: XCTestCase {
    func testBootstrapClaimDiagnosticsDistinguishMissingUploadingAndCompletedDelay() {
        let local = awaitingMetadataStatus()
        let now = Date(timeIntervalSince1970: 1_000)

        let missing = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .missing,
            completedMetadataMissingSince: nil,
            now: now
        )
        XCTAssertEqual(missing.state, .awaitingBootstrapMetadata)
        XCTAssertTrue(missing.message?.contains("Mac에서 최초") == true)

        let seeding = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .available(.seeding),
            completedMetadataMissingSince: nil,
            now: now
        )
        XCTAssertEqual(seeding.state, .awaitingBootstrapMetadata)
        XCTAssertTrue(seeding.message?.contains("업로드하는 중") == true)

        let completed = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .available(.completed),
            completedMetadataMissingSince: nil,
            now: now,
            gracePeriod: 30
        )
        XCTAssertEqual(completed.state, .awaitingBootstrapMetadata)
        XCTAssertEqual(completed.completedMetadataMissingSince, now)

        let timedOut = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .available(.completed),
            completedMetadataMissingSince: now,
            now: now.addingTimeInterval(31),
            gracePeriod: 30
        )
        XCTAssertEqual(timedOut.state, .failed)
        XCTAssertTrue(timedOut.message?.contains("동기화 상태 다시 확인") == true)
    }

    func testIOSManualRefreshImportEventAndPollingLifecyclePolicy() {
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldRefresh(reason: .manual, state: .failed))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldRefresh(reason: .successfulImport, state: .awaitingBootstrapMetadata))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldRefresh(
            reason: .pollingTick(sceneIsActive: true),
            state: .awaitingBootstrapMetadata
        ))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldRefresh(
            reason: .pollingTick(sceneIsActive: true),
            state: .hydrating
        ))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.shouldRefresh(
            reason: .pollingTick(sceneIsActive: false),
            state: .hydrating
        ))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.shouldRefresh(
            reason: .pollingTick(sceneIsActive: true),
            state: .ready
        ))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.shouldRefresh(
            reason: .pollingTick(sceneIsActive: true),
            state: .failed
        ))
    }

    func testHydrationGateBlocksMissingMetadataAndIncompleteCounts() throws {
        let context = try makeContext()

        XCTAssertEqual(
            try VocabCloudReconciler.hydrationStatus(context: context, syncMode: .cloudKitPrivate).state,
            .awaitingBootstrapMetadata
        )
        XCTAssertThrowsError(try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate))

        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        context.insert(metadata)
        try context.save()

        XCTAssertEqual(
            try VocabCloudReconciler.hydrationStatus(context: context, syncMode: .cloudKitPrivate).state,
            .hydrating
        )
        XCTAssertThrowsError(try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate))
    }

    func testTombstoneReconciliationIsIdempotentAndDeletionAlwaysWins() throws {
        let context = try makeContext()
        let word = WordRecord(term: "deleted")
        let meaning = MeaningRecord(text: "삭제 뜻")
        meaning.word = word
        word.appendMeaning(meaning)
        let deletionDate = Date(timeIntervalSince1970: 500)
        context.insert(word)
        context.insert(meaning)
        context.insert(RecordTombstone(recordID: word.id, recordType: "WordRecord", deletedAt: deletionDate))
        context.insert(RecordTombstone(recordID: meaning.id, recordType: "MeaningRecord", deletedAt: deletionDate))
        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        metadata.expectedMeaningCount = 1
        metadata.expectedTombstoneCount = 2
        context.insert(metadata)
        try context.save()

        XCTAssertEqual(try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate).state, .ready)
        XCTAssertEqual(word.deletedAt, deletionDate)
        XCTAssertEqual(meaning.deletedAt, deletionDate)

        word.deletedAt = nil
        meaning.deletedAt = nil
        try context.save()
        XCTAssertEqual(try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate).state, .ready)
        XCTAssertEqual(word.deletedAt, deletionDate)
        XCTAssertEqual(meaning.deletedAt, deletionDate)
    }

    func testDeletedMeaningIsExcludedFromPromptJudgementCorrectionAndMastery() throws {
        let context = try makeContext()
        let word = WordRecord(term: "bank")
        let active = MeaningRecord(text: "은행")
        let deleted = MeaningRecord(text: "둑")
        deleted.deletedAt = Date(timeIntervalSince1970: 10)
        active.word = word
        deleted.word = word
        word.replaceMeanings(with: [active, deleted])
        context.insert(word)
        context.insert(active)
        context.insert(deleted)
        try context.save()
        let coordinator = LearningCoordinator(context: context, syncMode: .localOnly)
        let question = SessionQuestion(word: word, direction: .enToKo, index: 0)
        let reverseQuestion = SessionQuestion(word: word, direction: .koToEn, index: 1)

        XCTAssertEqual(word.activeMeanings.map(\.text), ["은행"])
        XCTAssertEqual(word.correctionCandidateMeanings.map(\.text), ["은행"])
        XCTAssertEqual(coordinator.judge(answer: "둑", for: question).automaticResult, .incorrect)
        XCTAssertEqual(reverseQuestion.prompt, "은행")
    }

    func testOutOfOrderAttemptsRebuildDeterministicallyAcrossContexts() throws {
        let persistent = try makePersistentContainer()
        let firstContext = ModelContext(persistent.container)
        let word = WordRecord(term: "replay")
        let meaning = MeaningRecord(text: "재생")
        meaning.word = word
        word.appendMeaning(meaning)
        firstContext.insert(word)
        firstContext.insert(meaning)
        let later = makeAttempt(word: word, result: .correct, answeredAt: Date(timeIntervalSince1970: 300))
        let earlier = makeAttempt(word: word, result: .incorrect, answeredAt: Date(timeIntervalSince1970: 100))
        firstContext.insert(later)
        firstContext.insert(earlier)
        word.replaceAttempts(with: [later, earlier])
        try firstContext.save()

        let secondContext = ModelContext(persistent.container)
        let reloaded = try XCTUnwrap(secondContext.fetch(FetchDescriptor<WordRecord>()).first)
        LearningCoordinator(context: secondContext, syncMode: .localOnly).recomputeReviewState(for: reloaded)
        try secondContext.save()

        XCTAssertEqual(reloaded.reviewState?.lastTestedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(reloaded.reviewState?.failureCheck, 1)
        XCTAssertEqual(reloaded.reviewState?.enToKoStreak, 1)
    }

    func testLogicalDuplicateAttemptsUseLowestUUIDCanonicalFact() throws {
        let context = try makeContext()
        let word = WordRecord(term: "duplicate")
        context.insert(word)
        let sessionID = UUID()
        let answeredAt = Date(timeIntervalSince1970: 200)
        let high = makeAttempt(word: word, result: .incorrect, answeredAt: answeredAt, sessionID: sessionID)
        high.id = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let low = makeAttempt(word: word, result: .incorrect, answeredAt: answeredAt, sessionID: sessionID)
        low.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        word.replaceAttempts(with: [high, low])
        context.insert(high)
        context.insert(low)
        try context.save()

        let conflicts = LearningCoordinator(context: context, syncMode: .cloudKitPrivate)
            .recomputeReviewState(for: word)

        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertEqual(word.reviewState?.failureCheck, 1)
        XCTAssertEqual(LearningCoordinator.attemptReplayPlan([high, low]).canonicalAttempts.first?.id, low.id)
    }

    func testConflictingLogicalAttemptPayloadStopsReconciliationWithoutApplyingEither() throws {
        let context = try makeContext()
        let word = WordRecord(term: "conflict")
        let state = ReviewStateRecord()
        state.failureCheck = 2
        state.word = word
        word.reviewState = state
        context.insert(word)
        context.insert(state)
        let sessionID = UUID()
        let first = makeAttempt(
            word: word,
            result: .correct,
            answeredAt: Date(timeIntervalSince1970: 200),
            sessionID: sessionID
        )
        let second = makeAttempt(
            word: word,
            result: .incorrect,
            answeredAt: Date(timeIntervalSince1970: 200),
            sessionID: sessionID
        )
        word.replaceAttempts(with: [first, second])
        context.insert(first)
        context.insert(second)
        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        metadata.expectedAttemptCount = 2
        context.insert(metadata)
        try context.save()

        XCTAssertThrowsError(
            try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate)
        ) { error in
            guard case .attemptReplayConflicts(let conflicts) = error as? VocabCloudReconciliationError else {
                return XCTFail("Expected attempt replay conflict, got \(error)")
            }
            XCTAssertEqual(conflicts.first?.key.sessionID, sessionID)
            XCTAssertEqual(conflicts.first?.key.questionIndex, 0)
        }
        XCTAssertEqual(word.reviewState?.failureCheck, 2)
        XCTAssertNil(metadata.lastReconciledAt)
    }

    func testPersistentContainerReopensWithHydrationMetadataAndTombstone() throws {
        let directory = try makePersistentDirectory()
        let storeURL = directory.appendingPathComponent("Reopen.store")
        let wordID: UUID
        do {
            let container = try openPersistentContainer(at: storeURL)
            let context = ModelContext(container)
            let word = WordRecord(term: "persistent")
            wordID = word.id
            let deletionDate = Date(timeIntervalSince1970: 700)
            context.insert(word)
            context.insert(RecordTombstone(recordID: word.id, recordType: "WordRecord", deletedAt: deletionDate))
            let metadata = readyMetadata()
            metadata.expectedWordCount = 1
            metadata.expectedTombstoneCount = 1
            context.insert(metadata)
            try context.save()
        }

        let reopened = try openPersistentContainer(at: storeURL)
        let reopenedContext = ModelContext(reopened)
        XCTAssertEqual(
            try VocabCloudReconciler.hydrationStatus(context: reopenedContext, syncMode: .cloudKitPrivate).state,
            .reconciling
        )
        XCTAssertEqual(
            try VocabCloudReconciler.reconcile(context: reopenedContext, syncMode: .cloudKitPrivate).state,
            .ready
        )
        XCTAssertNotNil(try reopenedContext.fetch(FetchDescriptor<WordRecord>()).first { $0.id == wordID }?.deletedAt)
    }

    func testMirroredCompactionNeverHardDeletesAttempts() throws {
        let context = try makeContext()
        let word = WordRecord(term: "history")
        context.insert(word)
        for index in 0..<45 {
            let attempt = makeAttempt(
                word: word,
                result: .correct,
                answeredAt: Date(timeIntervalSince1970: Double(index))
            )
            word.appendAttempt(attempt)
            context.insert(attempt)
        }
        try context.save()

        try LearningCoordinator(context: context, syncMode: .cloudKitPrivate).compactLearningHistory(
            now: Date(timeIntervalSince1970: 100_000_000)
        )

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 45)
    }

    private func readyMetadata() -> CloudBootstrapRecord {
        let metadata = CloudBootstrapRecord(contentFingerprint: "fingerprint")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        return metadata
    }

    private func awaitingMetadataStatus() -> VocabHydrationStatus {
        VocabHydrationStatus(
            state: .awaitingBootstrapMetadata,
            counts: VocabEntityCounts(
                words: 0,
                meanings: 0,
                dailySets: 0,
                dailySetItems: 0,
                testSessions: 0,
                attempts: 0,
                anonymousAggregates: 0,
                memoryAidCaches: 0,
                tombstones: 0
            ),
            expectedBootstrapUUID: nil,
            message: "bootstrap metadata가 아직 관찰되지 않았습니다."
        )
    }

    private func makeAttempt(
        word: WordRecord,
        result: FinalResult,
        answeredAt: Date,
        sessionID: UUID = UUID()
    ) -> AttemptRecord {
        let attempt = AttemptRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.review.rawValue,
            sessionID: sessionID,
            questionIndex: 0,
            seoulDay: "2026-07-14",
            prompt: word.term,
            submittedAnswer: "답",
            automaticJudgementRaw: result.rawValue,
            finalJudgementRaw: result.rawValue,
            matchedMeaningID: result == .correct ? word.activeMeanings.first?.id : nil,
            answeredAt: answeredAt
        )
        attempt.word = word
        return attempt
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ))
    }

    private func makePersistentContainer() throws -> (container: ModelContainer, directory: URL) {
        let directory = try makePersistentDirectory()
        return (try openPersistentContainer(at: directory.appendingPathComponent("Reconciliation.store")), directory)
    }

    private func makePersistentDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabReconciliation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func openPersistentContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                "Reconciliation",
                schema: schema,
                url: storeURL,
                cloudKitDatabase: .none
            )
        )
    }
}
