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
        word.appendMeaning(meaning)
        let state = ReviewStateRecord()
        state.activePriority = 2
        state.failureCheck = 1
        state.word = word
        word.reviewState = state
        let dailySet = DailySetRecord(seoulDay: "2026-07-13", createdAt: Date(timeIntervalSince1970: 100))
        let item = DailySetItemRecord(orderIndex: 0, entryKind: "newHeadword", wordID: word.id)
        item.set = dailySet
        dailySet.appendItem(item)
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
        let metadataDate = Date(timeIntervalSince1970: 195)
        word.updatedAt = metadataDate
        word.originDeviceID = "word-device"
        meaning.updatedAt = metadataDate
        meaning.originDeviceID = "meaning-device"
        state.updatedAt = metadataDate
        state.originDeviceID = "review-device"
        dailySet.updatedAt = metadataDate
        dailySet.originDeviceID = "set-device"
        item.updatedAt = metadataDate
        item.originDeviceID = "item-device"
        session.updatedAt = metadataDate
        session.originDeviceID = "session-device"
        attempt.updatedAt = metadataDate
        attempt.originDeviceID = "attempt-device"
        aggregate.updatedAt = metadataDate
        aggregate.originDeviceID = "aggregate-device"
        cache.updatedAt = metadataDate
        cache.originDeviceID = "cache-device"

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

        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: destinationContext, syncMode: .localOnly)

        let restoredWords = try destinationContext.fetch(FetchDescriptor<WordRecord>())
        let restoredSets = try destinationContext.fetch(FetchDescriptor<DailySetRecord>())
        let restoredSessions = try destinationContext.fetch(FetchDescriptor<TestSessionRecord>())
        let restoredAttempts = try destinationContext.fetch(FetchDescriptor<AttemptRecord>())
        let restoredAggregates = try destinationContext.fetch(FetchDescriptor<AnonymousAggregateRecord>())
        let restoredCaches = try destinationContext.fetch(FetchDescriptor<MemoryAidCacheRecord>())
        XCTAssertEqual(restoredWords.map(\.term), ["commute"])
        XCTAssertEqual(restoredWords.first?.allMeanings.map(\.text), ["통근하다"])
        XCTAssertEqual(restoredWords.first?.reviewState?.activePriority, 2)
        XCTAssertEqual(restoredSets.first?.allItems.first?.wordID, word.id)
        XCTAssertEqual(restoredSessions.first?.id, session.id)
        XCTAssertEqual(restoredSessions.first?.wordIDs, [word.id])
        XCTAssertEqual(restoredAttempts.first?.id, attempt.id)
        XCTAssertEqual(restoredAttempts.first?.word?.id, word.id)
        XCTAssertEqual(restoredAttempts.first?.matchedMeaningID, meaning.id)
        XCTAssertEqual(restoredAggregates.first?.correctCount, 1)
        XCTAssertEqual(restoredCaches.first?.wordID, word.id)
        XCTAssertEqual(restoredCaches.first?.markdown, "memory aid")
        XCTAssertEqual(snapshot.words.first?.originDeviceID, "word-device")
        XCTAssertEqual(snapshot.words.first?.meanings.first?.originDeviceID, "meaning-device")
        XCTAssertEqual(snapshot.words.first?.reviewState?.originDeviceID, "review-device")
        XCTAssertEqual(snapshot.dailySets.first?.originDeviceID, "set-device")
        XCTAssertEqual(snapshot.dailySets.first?.items.first?.originDeviceID, "item-device")
        XCTAssertEqual(snapshot.testSessions.first?.originDeviceID, "session-device")
        XCTAssertEqual(snapshot.attempts.first?.originDeviceID, "attempt-device")
        XCTAssertEqual(snapshot.anonymousAggregates.first?.originDeviceID, "aggregate-device")
        XCTAssertEqual(snapshot.memoryAidCaches.first?.originDeviceID, "cache-device")
        XCTAssertEqual(restoredWords.first?.originDeviceID, "word-device")
        XCTAssertEqual(restoredWords.first?.reviewState?.originDeviceID, "review-device")
        XCTAssertEqual(restoredAttempts.first?.originDeviceID, "attempt-device")
        XCTAssertEqual(restoredAggregates.first?.originDeviceID, "aggregate-device")
        XCTAssertEqual(restoredCaches.first?.originDeviceID, "cache-device")
    }

    func testCanonicalFingerprintIsStableAcrossReplayDerivedStateAndBookkeeping() throws {
        let context = try makeContext()
        let word = WordRecord(term: "metadata")
        let meaning = MeaningRecord(text: "메타데이터")
        meaning.word = word
        word.appendMeaning(meaning)
        context.insert(word)
        context.insert(meaning)
        try context.save()
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context)
        var bookkeepingChanged = snapshot
        bookkeepingChanged.exportedAt = snapshot.exportedAt.addingTimeInterval(100)
        bookkeepingChanged.syncMetadata?.createdAt = Date(timeIntervalSince1970: 999)
        bookkeepingChanged.syncMetadata?.updatedAt = Date(timeIntervalSince1970: 1_000)
        bookkeepingChanged.syncMetadata?.completedAt = Date(timeIntervalSince1970: 1_001)
        bookkeepingChanged.syncMetadata?.lastReconciledAt = Date(timeIntervalSince1970: 1_002)
        bookkeepingChanged.words[0].updatedAt = Date(timeIntervalSince1970: 2_000)
        bookkeepingChanged.words[0].originDeviceID = "other-device"
        bookkeepingChanged.words[0].statusRaw = "mastered"
        bookkeepingChanged.words[0].meanings[0].successDays = ["2026-07-13", "2026-07-14", "2026-07-15"]
        bookkeepingChanged.words[0].reviewState = VocabSyncSnapshot.ReviewStatePayload(
            failureCheck: 99, activePriority: 20, enToKoStreak: 3, koToEnStreak: 4,
            koToEnSuccessDays: ["2026-07-15"], latestWrongDirection: "enToKo",
            latestWrongAt: Date(timeIntervalSince1970: 3_000),
            lastTestedAt: Date(timeIntervalSince1970: 3_001),
            presentationCount: 10, lastPresentedAt: Date(timeIntervalSince1970: 3_002)
        )
        var domainChanged = bookkeepingChanged
        domainChanged.words[0].term = "changed-domain-term"

        XCTAssertEqual(try snapshot.contentFingerprint(), try bookkeepingChanged.contentFingerprint())
        XCTAssertNotEqual(try snapshot.contentFingerprint(), try domainChanged.contentFingerprint())
    }

    func testCanonicalFingerprintDetectsSOTAttemptSetAndTombstoneChanges() throws {
        let wordID = UUID()
        let meaningID = UUID()
        let setID = UUID()
        let itemID = UUID()
        let sessionID = UUID()
        let attemptID = UUID()
        let date = Date(timeIntervalSince1970: 100)
        let baseline = VocabSyncSnapshot(
            formatVersion: 2,
            exportedAt: date,
            words: [VocabSyncSnapshot.WordPayload(
                id: wordID, term: "source", englishAliases: [], createdAt: date,
                statusRaw: "active", meanings: [VocabSyncSnapshot.MeaningPayload(
                    id: meaningID, text: "원본", isCore: true, aliases: [], successDays: []
                )], reviewState: nil
            )],
            dailySets: [VocabSyncSnapshot.DailySetPayload(
                id: setID, seoulDay: "2026-07-15", createdAt: date, completedAt: nil,
                items: [VocabSyncSnapshot.DailySetItemPayload(
                    id: itemID, orderIndex: 0, entryKind: "new", wordID: wordID, deletedAt: nil
                )]
            )],
            attempts: [VocabSyncSnapshot.AttemptPayload(
                id: attemptID, directionRaw: "enToKo", modeRaw: "review",
                sessionID: sessionID, questionIndex: 0, seoulDay: "2026-07-15",
                prompt: "source", submittedAnswer: "원본",
                automaticJudgementRaw: "correct", finalJudgementRaw: "correct",
                correctionRaw: nil, matchedMeaningID: meaningID, answeredAt: date,
                wordID: wordID
            )]
        )
        let fingerprint = try baseline.contentFingerprint()

        var sotChanged = baseline
        sotChanged.words[0].meanings[0].text = "변경된 원본"
        var attemptChanged = baseline
        attemptChanged.attempts[0].finalJudgementRaw = "incorrect"
        var setChanged = baseline
        setChanged.dailySets[0].items[0].orderIndex = 1
        var tombstoneChanged = baseline
        tombstoneChanged.tombstones = [VocabSyncSnapshot.TombstonePayload(
            id: wordID, recordID: wordID, recordType: "WordRecord",
            deletedAt: date, originDeviceID: "mac"
        )]

        XCTAssertNotEqual(fingerprint, try sotChanged.contentFingerprint())
        XCTAssertNotEqual(fingerprint, try attemptChanged.contentFingerprint())
        XCTAssertNotEqual(fingerprint, try setChanged.contentFingerprint())
        XCTAssertNotEqual(fingerprint, try tombstoneChanged.contentFingerprint())
    }

    func testCanonicalFingerprintIsStableBeforeAndAfterTombstoneReconciliation() throws {
        let context = try makeContext()
        let word = WordRecord(term: "deleted-domain")
        context.insert(word)
        try context.save()
        var beforeReconciliation = try VocabSyncSnapshotService.exportSnapshot(context: context)
        beforeReconciliation.tombstones = [VocabSyncSnapshot.TombstonePayload(
            id: word.id,
            recordID: word.id,
            recordType: "WordRecord",
            deletedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            originDeviceID: "mac"
        )]
        var afterReconciliation = beforeReconciliation
        afterReconciliation.words[0].deletedAt = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(
            try beforeReconciliation.contentFingerprint(),
            try afterReconciliation.contentFingerprint()
        )
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

        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: context, syncMode: .localOnly)

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
        XCTAssertNil(snapshot.syncMetadata)
        XCTAssertTrue(snapshot.tombstones.isEmpty)
    }

    func testSnapshotV2RoundTripPreservesMetadataTombstonesAndDeletedMeaning() throws {
        let source = try makeContext()
        let word = WordRecord(term: "archive")
        word.deletedAt = Date(timeIntervalSince1970: 21)
        let meaning = MeaningRecord(text: "보관")
        meaning.deletedAt = Date(timeIntervalSince1970: 20)
        meaning.word = word
        word.appendMeaning(meaning)
        source.insert(word)
        source.insert(meaning)
        let set = DailySetRecord(seoulDay: "2026-07-14")
        set.deletedAt = Date(timeIntervalSince1970: 22)
        let item = DailySetItemRecord(orderIndex: 0, entryKind: "newHeadword", wordID: word.id)
        item.deletedAt = Date(timeIntervalSince1970: 23)
        item.set = set
        set.appendItem(item)
        source.insert(set)
        source.insert(item)
        source.insert(RecordTombstone(recordID: meaning.id, recordType: "MeaningRecord", deletedAt: meaning.deletedAt!))
        try source.save()

        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: source, exportedAt: Date(timeIntervalSince1970: 30))
        let destination = try makeContext()
        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: destination, syncMode: .localOnly)

        XCTAssertEqual(snapshot.formatVersion, 2)
        XCTAssertNotNil(snapshot.syncMetadata)
        XCTAssertFalse(try snapshot.contentFingerprint().isEmpty)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<CloudBootstrapRecord>()).count, 1)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<WordRecord>()).first?.deletedAt, word.deletedAt)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<MeaningRecord>()).first?.deletedAt, meaning.deletedAt)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<DailySetRecord>()).first?.deletedAt, set.deletedAt)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<DailySetItemRecord>()).first?.deletedAt, item.deletedAt)
        XCTAssertEqual(try destination.fetch(FetchDescriptor<RecordTombstone>()).first?.recordID, meaning.id)
    }

    func testV1SnapshotIsRejectedForMirroredWholeReplace() throws {
        let context = try makeContext()
        let legacy = VocabSyncSnapshot(
            formatVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 1),
            words: [],
            dailySets: []
        )

        XCTAssertThrowsError(
            try VocabSyncSnapshotService.replaceLocalStore(
                with: legacy,
                context: context,
                syncMode: .cloudKitPrivate
            )
        ) { error in
            XCTAssertEqual(
                error as? VocabSyncSnapshotService.SnapshotValidationError,
                .mirroredWholeReplaceForbidden
            )
        }
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

        XCTAssertThrowsError(try VocabSyncSnapshotService.replaceLocalStore(with: invalidSnapshot, context: context, syncMode: .localOnly)) { error in
            XCTAssertEqual(
                error as? VocabSyncSnapshotService.SnapshotValidationError,
                .missingWordForDailySetItem(missingWordID)
            )
        }
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["keep"])
    }

    func testMigrationServiceCopiesFullFidelitySnapshotIntoMirroredContext() async throws {
        let localContext = try makeContext()
        let mirroredContext = try makeContext()
        let word = WordRecord(term: "mirror")
        let meaning = MeaningRecord(text: "거울")
        meaning.word = word
        word.appendMeaning(meaning)
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

        let report = try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
            localContext: localContext,
            mirroredContext: mirroredContext,
            bootstrapToken: VocabBootstrapToken(),
            claimService: ApprovingClaimService(),
            mirroredStoreURL: URL(fileURLWithPath: "/tmp/fake-mirrored.store"),
            exportObserver: ImmediateExportObserver(),
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
        XCTAssertEqual(try mirroredContext.fetch(FetchDescriptor<CloudBootstrapRecord>()).count, 1)
    }

    func testMigrationServiceDoesNotSeedAgainAfterBootstrapMarker() async throws {
        let localContext = try makeContext()
        let mirroredContext = try makeContext()
        localContext.insert(WordRecord(term: "local-source"))
        mirroredContext.insert(CloudBootstrapRecord())
        try localContext.save()
        try mirroredContext.save()

        do {
            _ = try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
                localContext: localContext,
                mirroredContext: mirroredContext,
                bootstrapToken: VocabBootstrapToken(),
                claimService: DenyingClaimService(reason: .unknown),
                mirroredStoreURL: URL(fileURLWithPath: "/tmp/fake-mirrored.store"),
                exportObserver: ImmediateExportObserver(),
                createCheckpoint: {
                    return VocabLocalStoreCheckpoint(directory: URL(fileURLWithPath: "/tmp/unused"), copiedFiles: [])
                }
            )
            XCTFail("Expected an unknown server claim to block seed.")
        } catch {
            XCTAssertEqual(error as? VocabStoreMigrationError, .bootstrapClaimDenied(.unknown))
        }
        XCTAssertTrue(try mirroredContext.fetch(FetchDescriptor<WordRecord>()).isEmpty)
    }

    func testMigrationServiceBlocksWhenMirroredStoreAlreadyContainsData() async throws {
        let localContext = try makeContext()
        let mirroredContext = try makeContext()
        localContext.insert(WordRecord(term: "source"))
        mirroredContext.insert(WordRecord(term: "existing-cloud"))
        try localContext.save()
        try mirroredContext.save()

        do {
            _ = try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
                localContext: localContext,
                mirroredContext: mirroredContext,
                bootstrapToken: VocabBootstrapToken(),
                claimService: ApprovingClaimService(),
                mirroredStoreURL: URL(fileURLWithPath: "/tmp/fake-mirrored.store"),
                exportObserver: ImmediateExportObserver(),
                createCheckpoint: {
                    VocabLocalStoreCheckpoint(
                        directory: URL(fileURLWithPath: "/tmp/VocabStoreCheckpoint-test", isDirectory: true),
                        copiedFiles: ["Vocab.store"]
                    )
                }
            )
            XCTFail("Expected non-empty mirrored store to block seed.")
        } catch {
            guard case .mirroredStoreAlreadyContainsData(let counts) = error as? VocabStoreMigrationError else {
                return XCTFail("Expected mirroredStoreAlreadyContainsData, got \(error)")
            }
            XCTAssertEqual(counts.words, 1)
        }
        XCTAssertEqual(try mirroredContext.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["existing-cloud"])
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private struct ApprovingClaimService: VocabBootstrapClaiming {
        func claim(_ request: VocabBootstrapClaimRequest) async -> VocabBootstrapClaimResult {
            .resumed(VocabBootstrapClaimApproval(
                request: request,
                state: .claimed,
                recordName: VocabCloudKitBootstrapClaimService.recordName,
                wasCreated: true
            ))
        }

        func transition(
            _ request: VocabBootstrapClaimRequest,
            from expectedState: VocabBootstrapClaimState,
            to newState: VocabBootstrapClaimState
        ) async -> VocabBootstrapClaimResult {
            .resumed(VocabBootstrapClaimApproval(
                request: request,
                state: newState,
                recordName: VocabCloudKitBootstrapClaimService.recordName,
                wasCreated: false
            ))
        }
    }

    private struct DenyingClaimService: VocabBootstrapClaiming {
        let reason: VocabBootstrapClaimDenial

        func claim(_ request: VocabBootstrapClaimRequest) async -> VocabBootstrapClaimResult {
            .denied(reason)
        }

        func transition(
            _ request: VocabBootstrapClaimRequest,
            from expectedState: VocabBootstrapClaimState,
            to newState: VocabBootstrapClaimState
        ) async -> VocabBootstrapClaimResult {
            .denied(reason)
        }
    }

    private struct ImmediateExportObserver: VocabCloudExportObserving {
        func beginWaiting(
            storeURL: URL,
            requestID: UUID,
            fingerprint: String,
            receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
        ) throws -> any VocabCloudExportExpectation {
            ImmediateExportExpectation(
                requestID: requestID,
                fingerprint: fingerprint,
                receiptMatches: receiptMatches
            )
        }
    }

    @MainActor
    private final class ImmediateExportExpectation: VocabCloudExportExpectation {
        let storeIdentifier = "immediate-store-uuid"
        let requestID: UUID
        let fingerprint: String
        let receiptMatches: @MainActor (VocabBootstrapExportBoundary) -> Bool
        var boundary: VocabBootstrapExportBoundary?

        init(
            requestID: UUID,
            fingerprint: String,
            receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
        ) {
            self.requestID = requestID
            self.fingerprint = fingerprint
            self.receiptMatches = receiptMatches
        }

        func setCommittedBoundary(_ boundary: VocabBootstrapExportBoundary) {
            guard boundary.requestID == requestID,
                  boundary.fingerprint == fingerprint,
                  boundary.storeUUID == storeIdentifier else { return }
            self.boundary = boundary
        }

        func waitForResult(timeout: TimeInterval) async throws {
            let boundary = try XCTUnwrap(boundary)
            XCTAssertTrue(receiptMatches(boundary))
        }
    }
}
