import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabBootstrapClaimTests: XCTestCase {
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
        beforeImport: () throws -> Void = {}
    ) async throws -> VocabStoreMigrationReport {
        try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
            localContext: local,
            mirroredContext: mirrored,
            bootstrapToken: token,
            claimService: service,
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
