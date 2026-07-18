import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudReconciliationTests: XCTestCase {
    func testForegroundDiagnosticsAreThrottledWhileManualAndImportBypassTTL() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: .foreground,
            lastDiagnosticAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: .foreground,
            lastDiagnosticAt: now.addingTimeInterval(-901),
            now: now
        ))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: .manual,
            lastDiagnosticAt: now,
            now: now
        ))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: .successfulImport,
            lastDiagnosticAt: now,
            now: now
        ))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.diagnosticIsDue(
            reason: .remoteStoreChange,
            lastDiagnosticAt: nil,
            now: now
        ))
    }

    func testImportedChangeDiscoveryFindsLateAttemptWithoutTimestampCursor() throws {
        let context = try makeContext()
        let first = WordRecord(term: "first")
        let second = WordRecord(term: "second")
        context.insert(first)
        context.insert(second)
        try context.save()
        let baseline = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex

        let late = makeAttempt(
            word: second,
            result: .incorrect,
            answeredAt: Date(timeIntervalSince1970: 1),
            sessionID: UUID()
        )
        second.appendAttempt(late)
        context.insert(late)
        try context.save()

        let changes = try VocabImportedChangeDiscovery.discover(
            context: context,
            previous: baseline,
            changedRecords: [try XCTUnwrap(VocabChangedRecordID(late))]
        )
        XCTAssertFalse(changes.requiresFullAudit)
        XCTAssertEqual(changes.affectedWordIDs, Set([second.id]))
        XCTAssertTrue(changes.changedTombstoneIDs.isEmpty)
    }

    func testIncrementalAttemptSignatureCoversEveryCanonicalEqualityField() throws {
        enum Field: CaseIterable {
            case direction, mode, sessionID, questionIndex, seoulDay, prompt, submittedAnswer
            case automaticJudgement, finalJudgement, correction, matchedMeaning, answeredAt, word
        }

        for field in Field.allCases {
            let context = try makeContext()
            let first = WordRecord(term: "first")
            let second = WordRecord(term: "second")
            let firstMeaning = MeaningRecord(text: "첫째")
            firstMeaning.word = first
            first.appendMeaning(firstMeaning)
            let secondMeaning = MeaningRecord(text: "둘째")
            secondMeaning.word = second
            second.appendMeaning(secondMeaning)
            context.insert(first)
            context.insert(second)
            context.insert(firstMeaning)
            context.insert(secondMeaning)
            let attempt = makeAttempt(
                word: first,
                result: .incorrect,
                answeredAt: Date(timeIntervalSince1970: 100),
                sessionID: UUID()
            )
            first.appendAttempt(attempt)
            context.insert(attempt)
            try context.save()
            let baseline = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex

            switch field {
            case .direction: attempt.directionRaw = PracticeDirection.koToEn.rawValue
            case .mode: attempt.modeRaw = SessionMode.mixed.rawValue
            case .sessionID: attempt.sessionID = UUID()
            case .questionIndex: attempt.questionIndex += 1
            case .seoulDay: attempt.seoulDay = "2026-07-18"
            case .prompt: attempt.prompt = "changed prompt"
            case .submittedAnswer: attempt.submittedAnswer = "changed answer"
            case .automaticJudgement: attempt.automaticJudgementRaw = FinalResult.correct.rawValue
            case .finalJudgement: attempt.finalJudgementRaw = FinalResult.correct.rawValue
            case .correction: attempt.correctionRaw = "acceptedAlias"
            case .matchedMeaning: attempt.matchedMeaningID = firstMeaning.id
            case .answeredAt: attempt.answeredAt = Date(timeIntervalSince1970: 200)
            case .word:
                attempt.word = second
                first.replaceAttempts(with: [])
                second.appendAttempt(attempt)
            }
            try context.save()

            let changes = try VocabImportedChangeDiscovery.discover(
                context: context,
                previous: baseline,
                changedRecords: [try XCTUnwrap(VocabChangedRecordID(attempt))]
            )
            XCTAssertTrue(changes.affectedWordIDs.contains(first.id), "Missing canonical field: \(field)")
            if field == .word {
                XCTAssertTrue(changes.affectedWordIDs.contains(second.id))
            }
        }
    }

    func testImportIndexVersionMismatchForcesFullAudit() throws {
        let context = try makeContext()
        let word = WordRecord(term: "versioned")
        context.insert(word)
        try context.save()
        var stale = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex
        stale.canonicalAttemptSignatureVersion -= 1

        let changes = try VocabImportedChangeDiscovery.discover(
            context: context,
            previous: stale,
            changedRecords: []
        )

        XCTAssertTrue(changes.requiresFullAudit)
    }

    func testDurableIdentifierBufferCoalescesRepeatedImportNotifications() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabIdentifierBuffer-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try makeContext()
        let first = WordRecord(term: "first")
        let second = WordRecord(term: "second")
        context.insert(first)
        context.insert(second)
        try context.save()
        let buffer = VocabImportedIdentifierBuffer(url: url)

        let firstID = try XCTUnwrap(VocabChangedRecordID(first))
        let secondID = try XCTUnwrap(VocabChangedRecordID(second))
        await buffer.capture([firstID])
        await buffer.capture([firstID, secondID])
        await buffer.capture([secondID])

        let reloadedBuffer = VocabImportedIdentifierBuffer(url: url)
        let pending = await reloadedBuffer.snapshot()
        XCTAssertEqual(pending, VocabImportedIdentifierBatch(records: [firstID, secondID], requiresFullAudit: false))
        await reloadedBuffer.acknowledge(pending)
        let remaining = await reloadedBuffer.snapshot()
        XCTAssertEqual(remaining, .empty)
    }

    func testUnresolvedDeletedIdentifierForcesFullAudit() throws {
        let context = try makeContext()
        let word = WordRecord(term: "deleted-before-resolution")
        context.insert(word)
        try context.save()
        let baseline = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex
        let missingRecord = VocabChangedRecordID(kind: .word, id: UUID())

        let changes = try VocabImportedChangeDiscovery.discover(
            context: context,
            previous: baseline,
            changedRecords: [missingRecord]
        )
        XCTAssertTrue(changes.requiresFullAudit)
    }

    func testCloudImportWithoutIdentifiersRunsFullAuditInsteadOfTreatingItAsNoChange() async throws {
        let context = try makeContext()
        let word = WordRecord(term: "cloud-import")
        let meaning = MeaningRecord(text: "클라우드")
        meaning.word = word
        word.appendMeaning(meaning)
        let state = ReviewStateRecord()
        state.word = word
        word.reviewState = state
        let attempt = makeAttempt(word: word, result: .incorrect, answeredAt: .now)
        word.appendAttempt(attempt)
        context.insert(word)
        context.insert(meaning)
        context.insert(state)
        context.insert(attempt)
        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        metadata.expectedMeaningCount = 1
        metadata.expectedAttemptCount = 1
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabUnknownImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("index.json")
        let receiptURL = root.appendingPathComponent("receipt.json")
        let buffer = VocabImportedIdentifierBuffer(url: root.appendingPathComponent("ids.json"))
        let baseline = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex
        try VocabImportedChangeIndexStore.save(baseline, to: indexURL)

        attempt.finalJudgementRaw = FinalResult.correct.rawValue
        attempt.automaticJudgementRaw = FinalResult.correct.rawValue
        attempt.updatedAt = .now
        try context.save()
        let pendingIdentifiers = await buffer.snapshot()
        XCTAssertEqual(pendingIdentifiers, .empty)

        let worker = await VocabCloudReconciliationWorkerFactory.make(modelContainer: context.container)
        _ = try await worker.reconcileImportedChanges(
            syncMode: .cloudKitPrivate,
            indexURL: indexURL,
            auditReceiptURL: receiptURL,
            identifierBuffer: buffer
        )

        let refreshed = ModelContext(context.container)
        let refreshedState = try XCTUnwrap(refreshed.fetch(FetchDescriptor<ReviewStateRecord>()).first)
        XCTAssertEqual(refreshedState.enToKoStreak, 1)
        XCTAssertNotNil(try VocabFullAuditReceiptStore.load(from: receiptURL))
    }

    func testCooperativeAuditIgnoresSoftDeletedConflictingAttemptAcrossBatches() async throws {
        let context = try makeContext()
        let word = WordRecord(term: "active-only-replay")
        let meaning = MeaningRecord(text: "활성")
        meaning.word = word
        word.appendMeaning(meaning)
        let state = ReviewStateRecord()
        state.word = word
        word.reviewState = state
        context.insert(word)
        context.insert(meaning)
        context.insert(state)
        for index in 0..<501 {
            let filler = makeAttempt(
                word: word,
                result: .correct,
                answeredAt: Date(timeIntervalSince1970: Double(index)),
                sessionID: UUID()
            )
            word.appendAttempt(filler)
            context.insert(filler)
        }
        let sharedSessionID = UUID()
        let active = makeAttempt(
            word: word,
            result: .incorrect,
            answeredAt: Date(timeIntervalSince1970: 1_000),
            sessionID: sharedSessionID
        )
        let deletedConflict = makeAttempt(
            word: word,
            result: .correct,
            answeredAt: active.answeredAt,
            sessionID: sharedSessionID
        )
        deletedConflict.deletedAt = Date(timeIntervalSince1970: 1_001)
        word.appendAttempt(active)
        word.appendAttempt(deletedConflict)
        context.insert(active)
        context.insert(deletedConflict)
        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        metadata.expectedMeaningCount = 1
        metadata.expectedAttemptCount = 503
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()

        let worker = await VocabCloudReconciliationWorkerFactory.make(modelContainer: context.container)
        let result = try await worker.reconcileFullCooperatively(syncMode: .cloudKitPrivate)

        XCTAssertEqual(result.state, .ready)
        let refreshed = ModelContext(context.container)
        let refreshedState = try XCTUnwrap(refreshed.fetch(FetchDescriptor<ReviewStateRecord>()).first)
        XCTAssertEqual(refreshedState.failureCheck, 1)
        XCTAssertEqual(refreshedState.lastTestedAt, active.answeredAt)
    }

    func testDeterministicBatchPaginationProcessesEveryRecordAcrossBoundaries() async throws {
        let context = try makeContext()
        let count = 1_201
        for index in 0..<count {
            let word = WordRecord(term: "boundary-\(index)")
            let state = ReviewStateRecord()
            state.word = word
            word.reviewState = state
            context.insert(word)
            context.insert(state)
            context.insert(RecordTombstone(
                recordID: word.id,
                recordType: "WordRecord",
                deletedAt: Date(timeIntervalSince1970: Double(index + 1))
            ))
        }
        let metadata = readyMetadata()
        metadata.expectedWordCount = count
        metadata.expectedTombstoneCount = count
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()

        let worker = await VocabCloudReconciliationWorkerFactory.make(modelContainer: context.container)
        _ = try await worker.reconcileFullCooperatively(syncMode: .cloudKitPrivate)

        let refreshed = ModelContext(context.container)
        let words = try refreshed.fetch(FetchDescriptor<WordRecord>())
        XCTAssertEqual(words.count, count)
        XCTAssertEqual(words.filter { $0.deletedAt != nil }.count, count)
        XCTAssertEqual(Set(words.map(\.id)).count, count)
    }

    func testConflictingIncrementalAttemptsDoNotAdvanceSidecarIndex() throws {
        let context = try makeContext()
        let word = WordRecord(term: "conflict")
        context.insert(word)
        try context.save()
        let baseline = try VocabImportedChangeDiscovery.discover(context: context, previous: nil).nextIndex
        let indexURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabConflictIndex-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        try VocabImportedChangeIndexStore.save(baseline, to: indexURL)
        let sessionID = UUID()
        let first = makeAttempt(word: word, result: .correct, answeredAt: .now, sessionID: sessionID)
        let second = makeAttempt(word: word, result: .incorrect, answeredAt: first.answeredAt, sessionID: sessionID)
        word.appendAttempt(first)
        word.appendAttempt(second)
        context.insert(first)
        context.insert(second)
        try context.save()

        let changes = try VocabImportedChangeDiscovery.discover(
            context: context,
            previous: baseline,
            changedRecords: [
                try XCTUnwrap(VocabChangedRecordID(first)),
                try XCTUnwrap(VocabChangedRecordID(second))
            ]
        )
        XCTAssertThrowsError(try VocabCloudReconciler.reconcileAffected(
            context: context,
            syncMode: .cloudKitPrivate,
            wordIDs: changes.affectedWordIDs,
            tombstoneIDs: changes.changedTombstoneIDs
        ))
        XCTAssertEqual(try VocabImportedChangeIndexStore.load(from: indexURL), baseline)
    }

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
            claimStatus: .available(serverClaim(state: .seeding)),
            completedMetadataMissingSince: nil,
            now: now
        )
        XCTAssertEqual(seeding.state, .awaitingBootstrapMetadata)
        XCTAssertTrue(seeding.message?.contains("업로드하는 중") == true)

        let completed = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .available(serverClaim(state: .completed)),
            completedMetadataMissingSince: nil,
            now: now,
            gracePeriod: 30
        )
        XCTAssertEqual(completed.state, .awaitingBootstrapMetadata)
        XCTAssertEqual(completed.completedMetadataMissingSince, now)

        let timedOut = VocabHydrationDiagnosticPolicy.diagnose(
            localStatus: local,
            claimStatus: .available(serverClaim(state: .completed)),
            completedMetadataMissingSince: now,
            now: now.addingTimeInterval(31),
            gracePeriod: 30
        )
        XCTAssertEqual(timedOut.state, .failed)
        XCTAssertTrue(timedOut.message?.contains("동기화 상태 다시 확인") == true)
    }

    private func serverClaim(state: VocabBootstrapClaimState) -> VocabBootstrapServerClaim {
        let date = Date(timeIntervalSince1970: 900)
        return VocabBootstrapServerClaim(
            request: VocabBootstrapClaimRequest(
                claimID: UUID(),
                requestID: UUID(),
                ownerDeviceID: "mac",
                sourceFingerprint: "fingerprint",
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                createdAt: date
            ),
            state: state,
            createdAt: date,
            updatedAt: date
        )
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
        XCTAssertEqual(
            (0..<VocabHydrationDiagnosticPolicy.bootstrapPollingDelays.count)
                .compactMap(VocabHydrationDiagnosticPolicy.pollingDelay(attempt:)),
            [5, 10, 20, 40, 60]
        )
        XCTAssertNil(VocabHydrationDiagnosticPolicy.pollingDelay(attempt: 5))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.shouldReconcile(reason: .manual, state: .ready))
        XCTAssertFalse(VocabHydrationDiagnosticPolicy.shouldReconcile(reason: .remoteStoreChange, state: .ready))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldReconcile(reason: .successfulImport, state: .ready))
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldReconcile(reason: .manual, state: .reconciling))
    }

    func testRefreshQueueCoalescesConcurrentImportArrivalsWithoutDroppingReconciliation() async {
        let queue = VocabHydrationRefreshQueue()
        let started = await queue.enqueue(.manual)
        let activeReason = await queue.dequeue()
        XCTAssertTrue(started)
        XCTAssertEqual(activeReason, .manual)

        let starts = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<20 {
                group.addTask {
                    await queue.enqueue(index.isMultiple(of: 2) ? .successfulImport : .remoteStoreChange)
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }

        XCTAssertTrue(starts.allSatisfy { !$0 }, "The active drain must own all competing requests")
        let pending = await queue.dequeue()
        XCTAssertEqual(pending, .successfulImport)
        XCTAssertTrue(VocabHydrationDiagnosticPolicy.shouldReconcile(reason: pending!, state: .ready))
        let remaining = await queue.dequeue()
        XCTAssertNil(remaining, "Concurrent import events must collapse into one follow-up pass")
    }

    func testWorkerIsCreatedOffMainAndRoutineHydrationPollingKeepsMainActorHeartbeatBelow100Milliseconds() async throws {
        let fixtureCount = 1_000
        let container = try makeHeartbeatFixtureContainer(count: fixtureCount)

        let worker = await VocabCloudReconciliationWorkerFactory.make(
            modelContainer: container
        )
        let wasCreatedOnMainThread = await worker.wasCreatedOnMainThread()
        XCTAssertFalse(wasCreatedOnMainThread)

        let heartbeat = Task { @MainActor in
            var previous = Date.now
            var maximumGap: TimeInterval = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    break
                }
                let now = Date.now
                maximumGap = max(maximumGap, now.timeIntervalSince(previous))
                previous = now
            }
            return maximumGap
        }
        try await Task.sleep(for: .milliseconds(25))
        for _ in 0..<20 {
            _ = try await worker.hydrationStatus(syncMode: .cloudKitPrivate)
        }
        heartbeat.cancel()
        let maximumGap = await heartbeat.value

        XCTAssertGreaterThan(maximumGap, 0, "Fixture must run long enough to sample the main actor")
        XCTAssertLessThan(maximumGap, 0.100, "Hydration polling blocked the main actor for \(maximumGap)s")
    }

    func testSingleImportedAttemptChangesOnlyItsWordAndLeavesReadyMetadataStable() throws {
        let context = try makeContext()
        let affected = WordRecord(term: "affected")
        let unaffected = WordRecord(term: "unaffected")
        let affectedMeaning = MeaningRecord(text: "영향")
        let unaffectedMeaning = MeaningRecord(text: "무관")
        affectedMeaning.word = affected
        unaffectedMeaning.word = unaffected
        affected.appendMeaning(affectedMeaning)
        unaffected.appendMeaning(unaffectedMeaning)
        let affectedState = ReviewStateRecord()
        let unaffectedState = ReviewStateRecord()
        affectedState.updatedAt = affected.updatedAt
        unaffectedState.updatedAt = unaffected.updatedAt
        affected.reviewState = affectedState
        unaffected.reviewState = unaffectedState
        [affected, unaffected].forEach(context.insert)
        [affectedMeaning, unaffectedMeaning].forEach(context.insert)
        [affectedState, unaffectedState].forEach(context.insert)
        let reconciledAt = Date(timeIntervalSince1970: 500)
        let metadata = readyMetadata()
        metadata.expectedWordCount = 2
        metadata.expectedMeaningCount = 2
        metadata.lastReconciledAt = reconciledAt
        metadata.updatedAt = reconciledAt
        context.insert(metadata)
        try context.save()

        let unaffectedBefore = (
            unaffectedState.failureCheck,
            unaffectedState.activePriority,
            unaffectedState.lastTestedAt,
            unaffectedState.updatedAt,
            unaffectedMeaning.successDays
        )
        let answeredAt = Date(timeIntervalSince1970: 700)
        let attempt = makeAttempt(word: affected, result: .incorrect, answeredAt: answeredAt)
        affected.appendAttempt(attempt)
        context.insert(attempt)
        try context.save()

        _ = try VocabCloudReconciler.reconcile(context: context, syncMode: .cloudKitPrivate)

        XCTAssertEqual(affectedState.failureCheck, 1)
        XCTAssertEqual(affectedState.lastTestedAt, answeredAt)
        XCTAssertEqual(unaffectedState.failureCheck, unaffectedBefore.0)
        XCTAssertEqual(unaffectedState.activePriority, unaffectedBefore.1)
        XCTAssertEqual(unaffectedState.lastTestedAt, unaffectedBefore.2)
        XCTAssertEqual(unaffectedState.updatedAt, unaffectedBefore.3)
        XCTAssertEqual(unaffectedMeaning.successDays, unaffectedBefore.4)
        XCTAssertEqual(metadata.lastReconciledAt, reconciledAt)
        XCTAssertEqual(metadata.updatedAt, reconciledAt)
        XCTAssertFalse(context.hasChanges)
    }

    func testReadyReconciliationDoesNotAdvanceMetadataOrLeaveUnsavedChanges() throws {
        let context = try makeContext()
        let reconciledAt = Date(timeIntervalSince1970: 1_000)
        let metadata = readyMetadata()
        metadata.lastReconciledAt = reconciledAt
        metadata.updatedAt = reconciledAt
        context.insert(metadata)
        try context.save()

        let result = try VocabCloudReconciler.reconcile(
            context: context,
            syncMode: .cloudKitPrivate,
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(result.state, .ready)
        XCTAssertEqual(metadata.lastReconciledAt, reconciledAt)
        XCTAssertEqual(metadata.updatedAt, reconciledAt)
        XCTAssertFalse(context.hasChanges)
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
        let metadata = readyMetadata()
        metadata.expectedWordCount = 1
        metadata.expectedAttemptCount = 45
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let validationEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: VocabFullAuditReceipt(
                formatVersion: VocabFullAuditReceipt.currentFormatVersion,
                storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
                bootstrapUUID: metadata.bootstrapUUID,
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
                importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
                canonicalFingerprint: "compaction-audit",
                auditedAt: .now
            ),
            validationEpoch: validationEpoch
        )

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

    private func makeHeartbeatFixtureContainer(count: Int) throws -> ModelContainer {
        let persistent = try makePersistentContainer()
        let context = ModelContext(persistent.container)
        for index in 0..<count {
            let word = WordRecord(term: "heartbeat-\(index)")
            let meaning = MeaningRecord(text: "뜻-\(index)")
            meaning.word = word
            word.appendMeaning(meaning)
            let state = ReviewStateRecord()
            let answeredAt = Date(timeIntervalSince1970: Double(10_000 + index))
            let successDay = SeoulCalendar.day(for: answeredAt)
            state.enToKoStreak = 1
            state.lastTestedAt = answeredAt
            state.updatedAt = answeredAt
            meaning.successDays = [successDay]
            word.reviewState = state
            context.insert(word)
            context.insert(meaning)
            context.insert(state)
            let attempt = makeAttempt(
                word: word,
                result: .correct,
                answeredAt: answeredAt,
                sessionID: UUID()
            )
            word.appendAttempt(attempt)
            context.insert(attempt)
        }
        let metadata = readyMetadata()
        metadata.expectedWordCount = count
        metadata.expectedMeaningCount = count
        metadata.expectedAttemptCount = count
        metadata.lastReconciledAt = Date(timeIntervalSince1970: 1)
        context.insert(metadata)
        try context.save()
        return persistent.container
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
