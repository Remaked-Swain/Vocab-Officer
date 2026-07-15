import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabBootstrapClaimTests: XCTestCase {
    func testObserverRegistersBeforeImportAndInitialReceiptBoundaryIsNotOverwritten() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let token = VocabBootstrapToken()
        let service = FakeClaimService()
        let firstTrace = FakeExportTrace()

        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: token,
                service: service,
                exportResult: .failure(VocabCloudExportWaitError.timedOut),
                trace: firstTrace,
                beforeImport: { XCTAssertTrue(firstTrace.didBeginWaiting) }
            )
            XCTFail("The first export wait must time out.")
        } catch VocabCloudExportWaitError.timedOut {}

        let firstReceipt = try XCTUnwrap(mirrored.fetch(FetchDescriptor<BootstrapExportReceipt>()).first)
        let firstBoundary = try XCTUnwrap(firstTrace.boundaries.first)
        XCTAssertEqual(firstTrace.boundaries.count, 1)
        XCTAssertEqual(firstReceipt.probeGeneration, 0)
        XCTAssertEqual(firstReceipt.transactionCommittedAt, firstBoundary.transactionCommittedAt)
        XCTAssertEqual(firstReceipt.nonce, firstBoundary.nonce)
        XCTAssertEqual(firstReceipt.state, "awaitingExport")

        let secondTrace = FakeExportTrace()
        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: token,
                service: service,
                exportResult: .failure(VocabCloudExportWaitError.timedOut),
                trace: secondTrace
            )
            XCTFail("The resume export wait must time out.")
        } catch VocabCloudExportWaitError.timedOut {}

        let resumedReceipt = try XCTUnwrap(mirrored.fetch(FetchDescriptor<BootstrapExportReceipt>()).first)
        XCTAssertEqual(resumedReceipt.probeGeneration, 1)
        XCTAssertNotEqual(resumedReceipt.nonce, firstBoundary.nonce)
        XCTAssertGreaterThanOrEqual(resumedReceipt.transactionCommittedAt, firstBoundary.transactionCommittedAt)
        XCTAssertEqual(try mirrored.fetchCount(FetchDescriptor<BootstrapExportReceipt>()), 1)
    }

    func testExportEventPolicyRequiresMatchingBoundaryStoreReceiptAndCleanSuccess() {
        let requestID = UUID()
        let boundary = VocabBootstrapExportBoundary(
            requestID: requestID,
            fingerprint: "fingerprint",
            storeUUID: "store",
            transactionCommittedAt: Date(timeIntervalSince1970: 100),
            exportNotBefore: Date(timeIntervalSince1970: 100),
            probeGeneration: 3,
            nonce: UUID()
        )
        let success = VocabCloudExportEventEvidence(
            storeIdentifier: "store",
            startDate: Date(timeIntervalSince1970: 101),
            succeeded: true,
            errorDescription: nil
        )
        func decision(
            _ event: VocabCloudExportEventEvidence = success,
            request: UUID = requestID,
            fingerprint: String = "fingerprint",
            receiptMatches: Bool = true
        ) -> VocabCloudExportEventDecision {
            VocabCloudExportEventPolicy.evaluate(
                event,
                boundary: boundary,
                expectedRequestID: request,
                expectedFingerprint: fingerprint,
                expectedStoreIdentifier: "store",
                receiptMatches: receiptMatches
            )
        }

        XCTAssertEqual(decision(), .success)
        XCTAssertEqual(decision(request: UUID()), .ignore)
        XCTAssertEqual(decision(fingerprint: "other"), .ignore)
        XCTAssertEqual(decision(receiptMatches: false), .ignore)
        XCTAssertEqual(decision(VocabCloudExportEventEvidence(
            storeIdentifier: "other",
            startDate: success.startDate,
            succeeded: true,
            errorDescription: nil
        )), .ignore)
        XCTAssertEqual(decision(VocabCloudExportEventEvidence(
            storeIdentifier: "store",
            startDate: Date(timeIntervalSince1970: 99),
            succeeded: true,
            errorDescription: nil
        )), .ignore)
        XCTAssertEqual(decision(VocabCloudExportEventEvidence(
            storeIdentifier: "store",
            startDate: success.startDate,
            succeeded: true,
            errorDescription: "injected"
        )), .failure("injected"))
    }

    func testExportEventGateDeterministicallyQueuesEventUntilBoundaryIsCommitted() {
        let requestID = UUID()
        let boundary = VocabBootstrapExportBoundary(
            requestID: requestID,
            fingerprint: "fingerprint",
            storeUUID: "store",
            transactionCommittedAt: Date(timeIntervalSince1970: 100),
            exportNotBefore: Date(timeIntervalSince1970: 100),
            probeGeneration: 0,
            nonce: UUID()
        )
        let gate = VocabCloudExportEventGate(
            requestID: requestID,
            fingerprint: "fingerprint",
            storeIdentifier: "store",
            receiptMatches: { $0 == boundary }
        )
        let event = VocabCloudExportEventEvidence(
            storeIdentifier: "store",
            startDate: Date(timeIntervalSince1970: 101),
            succeeded: true,
            errorDescription: nil
        )

        XCTAssertNil(gate.receive(event))
        XCTAssertEqual(gate.setCommittedBoundary(boundary), .success)

        let wrongBoundary = VocabBootstrapExportBoundary(
            requestID: UUID(),
            fingerprint: boundary.fingerprint,
            storeUUID: boundary.storeUUID,
            transactionCommittedAt: boundary.transactionCommittedAt,
            exportNotBefore: boundary.exportNotBefore,
            probeGeneration: boundary.probeGeneration,
            nonce: boundary.nonce
        )
        XCTAssertNil(gate.setCommittedBoundary(wrongBoundary))
    }

    func testLocalSaveLeavesClaimSeedingUntilExportSucceeds() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let service = FakeClaimService()

        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: VocabBootstrapToken(),
                service: service,
                exportResult: .failure(VocabCloudExportWaitError.timedOut)
            )
            XCTFail("Export timeout must stop completion.")
        } catch VocabCloudExportWaitError.timedOut {}

        let state = await service.currentState()
        XCTAssertEqual(state, .seeding)
        try assertSingleGraph(mirrored)
    }

    func testSuccessfulExportCompletesClaim() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let service = FakeClaimService()

        _ = try await migrate(local: local, mirrored: mirrored, token: VocabBootstrapToken(), service: service)

        let state = await service.currentState()
        XCTAssertEqual(state, .completed)
    }

    func testExportErrorDoesNotCompleteClaim() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let service = FakeClaimService()
        let exportError = VocabCloudExportWaitError.exportFailed("injected")

        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: VocabBootstrapToken(),
                service: service,
                exportResult: .failure(exportError)
            )
            XCTFail("Export error must stop completion.")
        } catch {
            XCTAssertEqual(error as? VocabCloudExportWaitError, exportError)
        }
        let state = await service.currentState()
        XCTAssertEqual(state, .seeding)
    }

    func testDeniedClaimsNeverSeed() async throws {
        for reason in [
            VocabBootstrapClaimDenial.competing,
            .foreign,
            .unknown,
            .timeout,
            .existing
        ] {
            let local = try makeContext()
            let mirrored = try makeContext()
            seedLocalGraph(local)
            let service = FakeClaimService(claimDenial: reason)

            do {
                _ = try await migrate(local: local, mirrored: mirrored, token: VocabBootstrapToken(), service: service)
                XCTFail("A denied server claim must not seed.")
            } catch {
                XCTAssertEqual(error as? VocabStoreMigrationError, .bootstrapClaimDenied(reason))
            }
            XCTAssertTrue(try mirrored.fetch(FetchDescriptor<WordRecord>()).isEmpty)
            XCTAssertTrue(try mirrored.fetch(FetchDescriptor<CloudBootstrapRecord>()).isEmpty)
        }
    }

    func testClaimedImportFailureRetriesSameTupleWithoutDuplicates() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let token = VocabBootstrapToken()
        let service = FakeClaimService()
        var shouldFail = true

        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: token,
                service: service,
                beforeImport: {
                    if shouldFail {
                        shouldFail = false
                        throw InjectedFailure.importFailed
                    }
                }
            )
            XCTFail("The injected import failure must escape.")
        } catch InjectedFailure.importFailed {}

        let claimedState = await service.currentState()
        XCTAssertEqual(claimedState, .claimed)
        _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
        let completedState = await service.currentState()
        XCTAssertEqual(completedState, .completed)
        try assertSingleGraph(mirrored)
    }

    func testPartialSaveIsCompletedByUUIDWithoutDuplicateContent() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        let source = seedLocalGraph(local)
        let token = VocabBootstrapToken()
        let service = FakeClaimService()
        var injected = false

        do {
            _ = try await migrate(
                local: local,
                mirrored: mirrored,
                token: token,
                service: service,
                beforeImport: {
                    guard !injected else { return }
                    injected = true
                    let partialWord = WordRecord(term: source.word.term, createdAt: source.word.createdAt)
                    partialWord.id = source.word.id
                    let partialMeaning = MeaningRecord(text: source.meaning.text)
                    partialMeaning.id = source.meaning.id
                    partialMeaning.word = partialWord
                    partialWord.appendMeaning(partialMeaning)
                    mirrored.insert(partialWord)
                    mirrored.insert(partialMeaning)
                    try mirrored.save()
                    throw InjectedFailure.partialSave
                }
            )
            XCTFail("The partial-save injection must escape.")
        } catch InjectedFailure.partialSave {}

        _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
        try assertSingleGraph(mirrored)
        XCTAssertEqual(try mirrored.fetch(FetchDescriptor<WordRecord>()).first?.id, source.word.id)
        XCTAssertEqual(try mirrored.fetch(FetchDescriptor<MeaningRecord>()).first?.id, source.meaning.id)
    }

    func testCompletionTimeoutWithoutServerUpdateRetriesFromSeeding() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let token = VocabBootstrapToken()
        let service = FakeClaimService(completionBehavior: .timeoutBeforeSave)

        do {
            _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
            XCTFail("The first completion update must time out.")
        } catch {
            XCTAssertEqual(error as? VocabStoreMigrationError, .bootstrapClaimDenied(.timeout))
        }
        let seedingState = await service.currentState()
        XCTAssertEqual(seedingState, .seeding)

        _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
        let completedState = await service.currentState()
        XCTAssertEqual(completedState, .completed)
        try assertSingleGraph(mirrored)
    }

    func testLostCompletionResponseAndSameTupleRetryAreExactlyOnce() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let token = VocabBootstrapToken()
        let service = FakeClaimService(completionBehavior: .saveThenLoseResponse)

        do {
            _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
            XCTFail("The simulated response loss must be surfaced.")
        } catch {
            XCTAssertEqual(error as? VocabStoreMigrationError, .bootstrapClaimDenied(.timeout))
        }
        let completedState = await service.currentState()
        XCTAssertEqual(completedState, .completed)

        _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
        _ = try await migrate(local: local, mirrored: mirrored, token: token, service: service)
        try assertSingleGraph(mirrored)
        let createdClaimCount = await service.createdClaimCount()
        XCTAssertEqual(createdClaimCount, 1)
    }

    func testForeignTupleIsBlockedWithoutChangingCompletedContent() async throws {
        let local = try makeContext()
        let mirrored = try makeContext()
        seedLocalGraph(local)
        let service = FakeClaimService()
        _ = try await migrate(local: local, mirrored: mirrored, token: VocabBootstrapToken(), service: service)

        do {
            _ = try await migrate(local: local, mirrored: mirrored, token: VocabBootstrapToken(), service: service)
            XCTFail("A foreign tuple must fail closed.")
        } catch {
            XCTAssertEqual(error as? VocabStoreMigrationError, .bootstrapClaimDenied(.foreign))
        }
        try assertSingleGraph(mirrored)
    }

    func testResumePolicyUsesCompletedClaimForHydrationWithoutReseed() {
        let claim = makeServerClaim(state: .completed, fingerprint: "server")

        let decision = VocabBootstrapResumePolicy.decide(
            serverStatus: .available(claim),
            storedRequest: nil,
            currentCanonicalFingerprint: "different-local",
            checkpointManifest: nil,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            receiptIsValid: false
        )

        XCTAssertEqual(decision, .hydrateCompleted(claim))
    }

    func testSettingsPresentationUsesNaturalStateAndExposesFullClaimTuple() throws {
        let claim = makeServerClaim(state: .seeding, fingerprint: "domain")
        let presentation = VocabBootstrapClaimSettingsPresentation(status: .available(claim))
        let details = try XCTUnwrap(presentation.details)

        XCTAssertTrue(presentation.summary.contains("업로드하는 중"))
        XCTAssertTrue(details.contains(claim.request.claimID.uuidString))
        XCTAssertTrue(details.contains(claim.request.requestID.uuidString))
        XCTAssertTrue(details.contains(claim.request.ownerDeviceID))
        XCTAssertTrue(details.contains(claim.request.sourceFingerprint))
        XCTAssertTrue(details.contains("schema: \(claim.request.schemaVersion)"))
    }

    func testResumePolicyResumesOnlyMatchingStoredTupleAndBlocksForeignTuple() {
        let claim = makeServerClaim(state: .seeding, fingerprint: "domain")
        let matching = VocabBootstrapResumePolicy.decide(
            serverStatus: .available(claim),
            storedRequest: claim.request,
            currentCanonicalFingerprint: "other",
            checkpointManifest: nil,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            receiptIsValid: true
        )
        var foreign = claim.request
        foreign = VocabBootstrapClaimRequest(
            claimID: foreign.claimID,
            requestID: UUID(),
            ownerDeviceID: foreign.ownerDeviceID,
            sourceFingerprint: foreign.sourceFingerprint,
            schemaVersion: foreign.schemaVersion,
            createdAt: foreign.createdAt
        )
        let blocked = VocabBootstrapResumePolicy.decide(
            serverStatus: .available(claim),
            storedRequest: foreign,
            currentCanonicalFingerprint: "domain",
            checkpointManifest: nil,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            receiptIsValid: true
        )

        XCTAssertEqual(matching, .resume(claim.request))
        guard case .blocked = blocked else { return XCTFail("Foreign tuple must fail closed") }
    }

    func testLostTupleRecoveryRequiresCanonicalOrCheckpointFingerprintAndReceipt() {
        let claim = makeServerClaim(state: .claimed, fingerprint: "domain")
        let manifest = VocabBootstrapRecoveryManifest(
            checkpointPath: "/tmp/checkpoint",
            canonicalFingerprint: "domain",
            claimRequest: claim.request,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            VocabBootstrapResumePolicy.decide(
                serverStatus: .available(claim), storedRequest: nil,
                currentCanonicalFingerprint: "domain", checkpointManifest: nil,
                expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion, receiptIsValid: true
            ),
            .recoverExisting(claim.request)
        )
        XCTAssertEqual(
            VocabBootstrapResumePolicy.decide(
                serverStatus: .available(claim), storedRequest: nil,
                currentCanonicalFingerprint: "other", checkpointManifest: manifest,
                expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion, receiptIsValid: true
            ),
            .recoverExisting(claim.request)
        )
        guard case .blocked = VocabBootstrapResumePolicy.decide(
            serverStatus: .available(claim), storedRequest: nil,
            currentCanonicalFingerprint: "domain", checkpointManifest: manifest,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion, receiptIsValid: false
        ) else { return XCTFail("Receipt mismatch must fail closed") }
    }

    func testLostTupleRecoveryRemainsValidAfterReplayDerivedStateChanges() throws {
        let context = try makeContext()
        seedLocalGraph(context)
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context)
        let serverFingerprint = try snapshot.contentFingerprint()
        var replayed = snapshot
        replayed.words[0].statusRaw = "mastered"
        replayed.words[0].meanings[0].successDays = ["2026-07-13", "2026-07-14", "2026-07-15"]
        replayed.words[0].reviewState = VocabSyncSnapshot.ReviewStatePayload(
            failureCheck: 0, activePriority: 0, enToKoStreak: 3, koToEnStreak: 3,
            koToEnSuccessDays: ["2026-07-13", "2026-07-14", "2026-07-15"],
            latestWrongDirection: nil, latestWrongAt: nil,
            lastTestedAt: Date(timeIntervalSince1970: 500),
            presentationCount: 4, lastPresentedAt: Date(timeIntervalSince1970: 501)
        )
        let claim = makeServerClaim(state: .seeding, fingerprint: serverFingerprint)

        let decision = VocabBootstrapResumePolicy.decide(
            serverStatus: .available(claim),
            storedRequest: nil,
            currentCanonicalFingerprint: try replayed.contentFingerprint(),
            checkpointManifest: nil,
            expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            receiptIsValid: true
        )

        XCTAssertEqual(decision, .recoverExisting(claim.request))
    }

    func testLegacyDefaultsMigrateOnceToCredentialDataWithOriginDeviceID() throws {
        let suite = "VocabBootstrapClaimTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let token = VocabBootstrapToken()
        defaults.set(token.claimID.uuidString, forKey: "vocabPendingBootstrapClaimID")
        defaults.set(token.requestID.uuidString, forKey: "vocabPendingBootstrapRequestID")
        let dataStore = MemoryCredentialDataStore()

        let migrated = try VocabBootstrapTokenStore.load(defaults: defaults, dataStore: dataStore)
        let reloaded = try VocabBootstrapTokenStore.load(defaults: defaults, dataStore: dataStore)

        XCTAssertEqual(migrated?.token, token)
        XCTAssertEqual(migrated?.originDeviceID, VocabDeviceIdentity.current)
        XCTAssertEqual(reloaded, migrated)
        XCTAssertNil(defaults.string(forKey: "vocabPendingBootstrapClaimID"))
        XCTAssertNil(defaults.string(forKey: "vocabPendingBootstrapRequestID"))
        XCTAssertEqual(dataStore.saveCount, 1)
    }

    func testFailedKeychainMigrationLeavesLegacyTupleRetryable() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VocabBootstrapClaimTests.\(UUID().uuidString)"))
        let token = VocabBootstrapToken()
        defaults.set(token.claimID.uuidString, forKey: "vocabPendingBootstrapClaimID")
        defaults.set(token.requestID.uuidString, forKey: "vocabPendingBootstrapRequestID")

        XCTAssertThrowsError(try VocabBootstrapTokenStore.load(
            defaults: defaults,
            dataStore: FailingCredentialDataStore()
        ))
        let retryStore = MemoryCredentialDataStore()
        let retried = try VocabBootstrapTokenStore.load(defaults: defaults, dataStore: retryStore)

        XCTAssertEqual(retried?.token, token)
        XCTAssertEqual(retryStore.saveCount, 1)
    }

    private func makeServerClaim(
        state: VocabBootstrapClaimState,
        fingerprint: String
    ) -> VocabBootstrapServerClaim {
        let date = Date(timeIntervalSince1970: 10)
        let request = VocabBootstrapClaimRequest(
            claimID: UUID(), requestID: UUID(), ownerDeviceID: "mac",
            sourceFingerprint: fingerprint,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            createdAt: date
        )
        return VocabBootstrapServerClaim(request: request, state: state, createdAt: date, updatedAt: date)
    }

    private struct SourceGraph {
        let word: WordRecord
        let meaning: MeaningRecord
    }

    @discardableResult
    private func seedLocalGraph(_ context: ModelContext) -> SourceGraph {
        let word = WordRecord(term: "claim-word", createdAt: Date(timeIntervalSince1970: 100))
        let meaning = MeaningRecord(text: "뜻")
        meaning.word = word
        word.appendMeaning(meaning)
        let set = DailySetRecord(seoulDay: "2026-07-14", createdAt: Date(timeIntervalSince1970: 110))
        let item = DailySetItemRecord(orderIndex: 0, entryKind: "new", wordID: word.id)
        item.set = set
        set.appendItem(item)
        let sessionID = UUID()
        let session = TestSessionRecord(
            id: sessionID,
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.review.rawValue,
            seoulDay: "2026-07-14",
            wordIDs: [word.id],
            wasReduced: false,
            startedAt: Date(timeIntervalSince1970: 115)
        )
        let attempt = AttemptRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.review.rawValue,
            sessionID: sessionID,
            questionIndex: 0,
            seoulDay: "2026-07-14",
            prompt: word.term,
            submittedAnswer: meaning.text,
            automaticJudgementRaw: FinalResult.correct.rawValue,
            finalJudgementRaw: FinalResult.correct.rawValue,
            matchedMeaningID: meaning.id,
            answeredAt: Date(timeIntervalSince1970: 120)
        )
        attempt.word = word
        word.appendAttempt(attempt)
        context.insert(word)
        context.insert(meaning)
        context.insert(set)
        context.insert(item)
        context.insert(session)
        context.insert(attempt)
        try? context.save()
        return SourceGraph(word: word, meaning: meaning)
    }

    private func migrate(
        local: ModelContext,
        mirrored: ModelContext,
        token: VocabBootstrapToken,
        service: FakeClaimService,
        exportResult: Result<Void, Error> = .success(()),
        trace: FakeExportTrace? = nil,
        beforeImport: () throws -> Void = {}
    ) async throws -> VocabStoreMigrationReport {
        try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
            localContext: local,
            mirroredContext: mirrored,
            bootstrapToken: token,
            claimService: service,
            mirroredStoreURL: URL(fileURLWithPath: "/tmp/fake-mirrored.store"),
            exportObserver: FakeExportObserver(result: exportResult, trace: trace),
            createCheckpoint: {
                VocabLocalStoreCheckpoint(
                    directory: URL(fileURLWithPath: "/tmp/fake-bootstrap-checkpoint"),
                    copiedFiles: ["Vocab.store"]
                )
            },
            beforeImport: beforeImport
        )
    }

    private func assertSingleGraph(_ context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WordRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MeaningRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailySetRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailySetItemRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<WordRecord>()).map(\.id)).count, 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<MeaningRecord>()).map(\.id)).count, 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<DailySetRecord>()).map(\.id)).count, 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<AttemptRecord>()).map(\.id)).count, 1)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        return ModelContext(try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ))
    }

    private enum InjectedFailure: Error {
        case importFailed
        case partialSave
    }
}

private final class MemoryCredentialDataStore: VocabBootstrapCredentialDataStoring {
    var data: Data?
    private(set) var saveCount = 0

    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        saveCount += 1
        self.data = data
    }
}

private struct FailingCredentialDataStore: VocabBootstrapCredentialDataStoring {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw CocoaError(.fileWriteUnknown) }
}

private struct FakeExportObserver: VocabCloudExportObserving {
    let result: Result<Void, Error>
    let trace: FakeExportTrace?

    func beginWaiting(
        storeURL: URL,
        requestID: UUID,
        fingerprint: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool
    ) throws -> any VocabCloudExportExpectation {
        trace?.didBeginWaiting = true
        return FakeExportExpectation(
            result: result,
            requestID: requestID,
            fingerprint: fingerprint,
            receiptMatches: receiptMatches,
            trace: trace
        )
    }
}

@MainActor
private final class FakeExportTrace {
    var didBeginWaiting = false
    var boundaries: [VocabBootstrapExportBoundary] = []
}

@MainActor
private final class FakeExportExpectation: VocabCloudExportExpectation {
    let storeIdentifier = "fake-store-uuid"
    let result: Result<Void, Error>
    let requestID: UUID
    let fingerprint: String
    let receiptMatches: @MainActor (VocabBootstrapExportBoundary) -> Bool
    let trace: FakeExportTrace?
    var boundary: VocabBootstrapExportBoundary?

    init(
        result: Result<Void, Error>,
        requestID: UUID,
        fingerprint: String,
        receiptMatches: @escaping @MainActor (VocabBootstrapExportBoundary) -> Bool,
        trace: FakeExportTrace?
    ) {
        self.result = result
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.receiptMatches = receiptMatches
        self.trace = trace
    }

    func setCommittedBoundary(_ boundary: VocabBootstrapExportBoundary) {
        guard boundary.requestID == requestID,
              boundary.fingerprint == fingerprint,
              boundary.storeUUID == storeIdentifier else { return }
        self.boundary = boundary
        trace?.boundaries.append(boundary)
    }

    func waitForResult(timeout: TimeInterval) async throws {
        let boundary = try XCTUnwrap(boundary)
        XCTAssertTrue(receiptMatches(boundary))
        try result.get()
    }
}

private actor FakeClaimService: VocabBootstrapClaiming {
    enum CompletionBehavior {
        case normal
        case timeoutBeforeSave
        case saveThenLoseResponse
    }

    private var request: VocabBootstrapClaimRequest?
    private var state: VocabBootstrapClaimState?
    private var claimCreations = 0
    private var completionBehavior: CompletionBehavior
    private let claimDenial: VocabBootstrapClaimDenial?

    init(
        claimDenial: VocabBootstrapClaimDenial? = nil,
        completionBehavior: CompletionBehavior = .normal
    ) {
        self.claimDenial = claimDenial
        self.completionBehavior = completionBehavior
    }

    func claim(_ incoming: VocabBootstrapClaimRequest) async -> VocabBootstrapClaimResult {
        if let claimDenial { return .denied(claimDenial) }
        if let request {
            guard request == incoming else { return .denied(.foreign) }
            return resumed(incoming, state: state ?? .claimed, wasCreated: false)
        }
        request = incoming
        state = .claimed
        claimCreations += 1
        return resumed(incoming, state: .claimed, wasCreated: true)
    }

    func transition(
        _ incoming: VocabBootstrapClaimRequest,
        from expectedState: VocabBootstrapClaimState,
        to newState: VocabBootstrapClaimState
    ) async -> VocabBootstrapClaimResult {
        guard request == incoming else { return .denied(.foreign) }
        if state == newState { return resumed(incoming, state: newState, wasCreated: false) }
        guard state == expectedState else { return .denied(.competing) }
        if newState == .completed {
            switch completionBehavior {
            case .normal:
                break
            case .timeoutBeforeSave:
                completionBehavior = .normal
                return .denied(.timeout)
            case .saveThenLoseResponse:
                completionBehavior = .normal
                state = .completed
                return .denied(.timeout)
            }
        }
        state = newState
        return resumed(incoming, state: newState, wasCreated: false)
    }

    func currentState() -> VocabBootstrapClaimState? { state }
    func createdClaimCount() -> Int { claimCreations }

    private func resumed(
        _ request: VocabBootstrapClaimRequest,
        state: VocabBootstrapClaimState,
        wasCreated: Bool
    ) -> VocabBootstrapClaimResult {
        .resumed(VocabBootstrapClaimApproval(
            request: request,
            state: state,
            recordName: VocabCloudKitBootstrapClaimService.recordName,
            wasCreated: wasCreated
        ))
    }
}
