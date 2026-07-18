import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class AuthoringCapabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetGlobalMutationAuthority()
    }

    override func tearDown() {
        resetGlobalMutationAuthority()
        super.tearDown()
    }

    func testMacCapabilityAllowsVocabularyCreateUpdateAndDelete() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context: context, capability: .macAuthor)

        let word = try coordinator.addLooseWord(term: "before", meaningsText: "이전")
        try coordinator.updateWord(word, term: "after", meaningsText: "이후")
        XCTAssertEqual(word.term, "after")

        try coordinator.deleteWords([word])
        XCTAssertNotNil(word.deletedAt)
        XCTAssertFalse(try context.fetch(FetchDescriptor<RecordTombstone>()).isEmpty)
    }

    func testReadOnlyVocabularyCapabilityRejectsEveryVocabularyMutationEntryPoint() throws {
        let context = try makeContext()
        let word = insertWord(context: context, term: "existing")
        let set = DailySetRecord(seoulDay: "2026-07-17")
        context.insert(set)
        try context.save()
        let coordinator = makeCoordinator(context: context, capability: .readOnlyVocabulary)

        assertMacAuthoringRequired { try coordinator.saveDailySet(drafts(count: 100)) }
        assertMacAuthoringRequired { _ = try coordinator.addLooseWord(term: "blocked", meaningsText: "차단") }
        assertMacAuthoringRequired { try coordinator.updateWord(word, term: "changed", meaningsText: "변경") }
        word.statusRaw = "mastered"
        assertMacAuthoringRequired { try coordinator.deleteMastered(word) }
        assertMacAuthoringRequired { try coordinator.deleteWords([word]) }
        assertMacAuthoringRequired { try coordinator.discardDailySet(set) }

        XCTAssertNil(word.deletedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<RecordTombstone>()).isEmpty)
    }

    func testBothPlatformProfilesCanGenerateSessionAndCommitCorrectedAttempt() throws {
        for capability in [VocabAuthoringCapability.macAuthor, .readOnlyVocabulary] {
            let context = try makeContext()
            _ = insertWord(context: context, term: "fact-\(String(describing: capability))")
            try context.save()
            let coordinator = makeCoordinator(context: context, capability: capability)

            let (session, questions) = try coordinator.generateSession(mode: .loose, direction: .enToKo)
            let question = try XCTUnwrap(questions.first)
            try coordinator.commit(
                answer: "뜻",
                result: .correct,
                automatic: .incorrect,
                matchedMeaningID: question.word.activeMeanings.first?.id,
                question: question,
                session: session,
                correction: "oneTimeCorrect"
            )

            let attempt = try XCTUnwrap(context.fetch(FetchDescriptor<AttemptRecord>()).first)
            XCTAssertEqual(attempt.finalJudgementRaw, FinalResult.correct.rawValue)
            XCTAssertEqual(attempt.automaticJudgementRaw, FinalResult.incorrect.rawValue)
            XCTAssertEqual(attempt.correctionRaw, "oneTimeCorrect")
        }
    }

    func testIntegrityBlockedAuthorityRejectsAllWritesButLeavesReadsAvailable() throws {
        for capability in [VocabAuthoringCapability.macAuthor, .readOnlyVocabulary] {
            let context = try makeContext()
            let word = insertWord(context: context, term: "readable-\(String(describing: capability))")
            let session = TestSessionRecord(
                directionRaw: PracticeDirection.enToKo.rawValue,
                modeRaw: SessionMode.loose.rawValue,
                seoulDay: "2026-07-17",
                wordIDs: [word.id],
                wasReduced: true
            )
            context.insert(session)
            try context.save()
            let coordinator = makeCoordinator(
                context: context,
                capability: capability,
                authority: .integrityBlocked
            )

            XCTAssertEqual(word.activeMeanings.first?.text, "뜻")
            assertIntegrityBlocked { _ = try coordinator.generateSession(mode: .loose, direction: .enToKo) }
            let question = SessionQuestion(word: word, direction: .enToKo, index: 0)
            assertIntegrityBlocked {
                try coordinator.commit(
                    answer: "뜻",
                    result: .correct,
                    automatic: .correct,
                    matchedMeaningID: word.activeMeanings.first?.id,
                    question: question,
                    session: session
                )
            }
            assertIntegrityBlocked { try coordinator.completeSession(session) }
            assertIntegrityBlocked { _ = try coordinator.addLooseWord(term: "blocked", meaningsText: "차단") }
            XCTAssertEqual(try context.fetch(FetchDescriptor<TestSessionRecord>()).count, 1)
            XCTAssertEqual(try context.fetch(FetchDescriptor<AttemptRecord>()).count, 0)
        }
    }

    func testReadOnlyVocabularyCanWriteLearningFactsWhenCloudStoreIsReadyAndAudited() throws {
        let context = try makeContext()
        _ = insertWord(context: context, term: "ios-learning")
        try authorizeReadyCloudStore(context: context, fingerprint: "ios-learning-fingerprint")
        let coordinator = LearningCoordinator(
            context: context,
            syncMode: .cloudKitPrivate,
            authoringCapability: .readOnlyVocabulary,
            mutationAuthority: .allowed
        )

        let (session, questions) = try coordinator.generateSession(mode: .loose, direction: .enToKo)
        let question = try XCTUnwrap(questions.first)
        try coordinator.commit(
            answer: "뜻",
            result: .correct,
            automatic: .correct,
            matchedMeaningID: question.word.activeMeanings.first?.id,
            question: question,
            session: session,
            date: Date(timeIntervalSince1970: 100)
        )
        try coordinator.completeSession(session, date: Date(timeIntervalSince1970: 120))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TestSessionRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
        XCTAssertEqual(question.word.reviewState?.lastTestedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(session.completedAt, Date(timeIntervalSince1970: 120))
    }

    func testReadOnlyVocabularyStillRejectsAuthoringWhenCloudStoreIsReadyAndAudited() throws {
        let context = try makeContext()
        let word = insertWord(context: context, term: "ios-authoring")
        try authorizeReadyCloudStore(context: context, fingerprint: "ios-authoring-fingerprint")
        let coordinator = LearningCoordinator(
            context: context,
            syncMode: .cloudKitPrivate,
            authoringCapability: .readOnlyVocabulary,
            mutationAuthority: .allowed
        )

        assertMacAuthoringRequired { _ = try coordinator.addLooseWord(term: "blocked", meaningsText: "차단") }
        assertMacAuthoringRequired { try coordinator.updateWord(word, term: "changed", meaningsText: "변경") }
    }

    func testTransientFailureDoesNotRevokePreviouslyAllowedMutationAuthority() {
        XCTAssertNil(VocabMutationAuthorityPolicy.authority(for: NSError(domain: NSURLErrorDomain, code: -1009)))
        XCTAssertEqual(VocabMutationAuthorityPolicy.authority(for: .ready), .allowed)
        XCTAssertEqual(VocabMutationAuthorityPolicy.authority(for: .reconciling), .integrityBlocked)
        XCTAssertEqual(VocabMutationAuthorityPolicy.authority(for: .failed), .integrityBlocked)
        XCTAssertEqual(
            VocabMutationAuthorityPolicy.authority(
                for: VocabCloudReconciliationError.attemptReplayConflicts([])
            ),
            .integrityBlocked
        )
    }

    func testCurrentInvalidMetadataBlocksPreviouslyAllowedCoordinatorAtWriteTime() throws {
        let context = try makeContext()
        let word = insertWord(context: context, term: "still-readable")
        let metadata = CloudBootstrapRecord(contentFingerprint: "valid-before-write")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.expectedWordCount = 1
        metadata.expectedMeaningCount = 1
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: "audited-canonical-state",
            auditedAt: .now
        )
        let validationEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: receipt,
            validationEpoch: validationEpoch
        )
        let coordinator = LearningCoordinator(
            context: context,
            syncMode: .cloudKitPrivate,
            authoringCapability: .macAuthor,
            mutationAuthority: .allowed
        )

        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion + 1
        try context.save()

        XCTAssertEqual(word.term, "still-readable")
        assertIntegrityBlocked { _ = try coordinator.addLooseWord(term: "blocked", meaningsText: "차단") }
        assertIntegrityBlocked { _ = try coordinator.generateSession(mode: .loose, direction: .enToKo) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WordRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 0)
    }

    func testMutationLeasePersistsAcrossStoreInstancesAndInvalidationClosesIt() throws {
        let suite = "VocabMutationLeaseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstStore = VocabMutationLeaseStore(defaults: defaults)
        let lease = VocabMutationLease(
            formatVersion: VocabMutationLease.currentFormatVersion,
            storeIdentity: "store",
            bootstrapUUID: UUID(),
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            metadataFingerprint: "metadata",
            canonicalFingerprint: "canonical",
            issuedAt: .now
        )

        firstStore.save(lease)
        let relaunchedStore = VocabMutationLeaseStore(defaults: defaults)
        XCTAssertEqual(relaunchedStore.load(), lease)
        relaunchedStore.invalidate()
        XCTAssertNil(firstStore.load())
    }

    func testPersistedLeaseNeverAuthorizesANewRuntimeEpoch() throws {
        let context = try makeContext()
        _ = insertWord(context: context, term: "epoch-word")
        let metadata = CloudBootstrapRecord(contentFingerprint: "epoch-fingerprint")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: "epoch-canonical",
            auditedAt: .now
        )
        let firstEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: receipt,
            validationEpoch: firstEpoch
        )
        XCTAssertTrue(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))
        let authorizedCoordinator = LearningCoordinator(
            context: context,
            syncMode: .cloudKitPrivate,
            authoringCapability: .macAuthor,
            mutationAuthority: .allowed
        )
        let (session, questions) = try authorizedCoordinator.generateSession(mode: .loose, direction: .enToKo)
        let question = try XCTUnwrap(questions.first)
        let oldLease = try XCTUnwrap(VocabMutationLeaseStore().load())

        VocabMutationAuthorityRuntime.beginValidationEpoch()
        VocabMutationLeaseStore().save(oldLease)

        XCTAssertEqual(VocabMutationAuthorityRuntime.current, .integrityBlocked)
        XCTAssertFalse(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))
        let coordinator = LearningCoordinator(
            context: context,
            syncMode: .cloudKitPrivate,
            authoringCapability: .macAuthor,
            mutationAuthority: .allowed
        )
        assertIntegrityBlocked {
            try coordinator.commit(
                answer: "뜻",
                result: .correct,
                automatic: .correct,
                matchedMeaningID: question.word.activeMeanings.first?.id,
                question: question,
                session: session,
                correction: nil
            )
        }
        assertIntegrityBlocked { _ = try coordinator.addLooseWord(term: "blocked", meaningsText: "차단") }
        assertIntegrityBlocked { _ = try coordinator.generateSession(mode: .loose, direction: .enToKo) }
    }

    func testForegroundReentryKeepsAuthorizedLease() throws {
        let context = try makeContext()
        _ = insertWord(context: context, term: "foreground-word")
        let metadata = CloudBootstrapRecord(contentFingerprint: "foreground-fingerprint")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: "foreground-canonical",
            auditedAt: .now
        )
        let initialEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: receipt,
            validationEpoch: initialEpoch
        )
        XCTAssertTrue(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))

        VocabMutationAuthorityRuntime.noteForegroundReentry()

        XCTAssertEqual(VocabMutationAuthorityRuntime.currentValidationEpoch, initialEpoch)
        XCTAssertEqual(VocabMutationAuthorityRuntime.current, .allowed)
        XCTAssertTrue(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))

        VocabMutationAuthorityRuntime.invalidate()
        XCTAssertFalse(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))
    }

    func testAuditFromPreviousEpochCannotAuthorizeAfterForegroundRotation() throws {
        let context = try makeContext()
        let metadata = CloudBootstrapRecord(contentFingerprint: "rotated-fingerprint")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: "rotated-canonical",
            auditedAt: .now
        )
        let auditEpoch = VocabMutationAuthorityRuntime.prepareForFullAudit()

        VocabMutationAuthorityRuntime.beginValidationEpoch()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: receipt,
            validationEpoch: auditEpoch
        )

        XCTAssertEqual(VocabMutationAuthorityRuntime.current, .integrityBlocked)
        XCTAssertFalse(VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context))
    }

    private func makeContext() throws -> ModelContext {
        ModelContext(try VocabModelContainerFactory.makeInMemoryContainer())
    }

    private func makeCoordinator(
        context: ModelContext,
        capability: VocabAuthoringCapability,
        authority: VocabMutationAuthority = .allowed
    ) -> LearningCoordinator {
        LearningCoordinator(
            context: context,
            syncMode: .localOnly,
            authoringCapability: capability,
            mutationAuthority: authority
        )
    }

    @discardableResult
    private func insertWord(context: ModelContext, term: String) -> WordRecord {
        let word = WordRecord(term: term)
        let meaning = MeaningRecord(text: "뜻")
        meaning.word = word
        word.appendMeaning(meaning)
        let state = ReviewStateRecord()
        state.word = word
        word.reviewState = state
        context.insert(word)
        context.insert(meaning)
        context.insert(state)
        return word
    }

    private func authorizeReadyCloudStore(
        context: ModelContext,
        fingerprint: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        VocabMutationAuthorityRuntime.invalidate()
        let metadata = CloudBootstrapRecord(contentFingerprint: fingerprint)
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.expectedWordCount = try context.fetchCount(FetchDescriptor<WordRecord>())
        metadata.expectedMeaningCount = try context.fetchCount(FetchDescriptor<MeaningRecord>())
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: context.container),
            bootstrapUUID: metadata.bootstrapUUID,
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: "canonical-\(fingerprint)",
            auditedAt: .now
        )
        let epoch = VocabMutationAuthorityRuntime.prepareForFullAudit()
        try VocabMutationAuthorityRuntime.authorize(
            container: context.container,
            context: context,
            receipt: receipt,
            validationEpoch: epoch
        )
        XCTAssertTrue(
            VocabMutationAuthorityRuntime.permitsMutation(container: context.container, context: context),
            file: file,
            line: line
        )
    }

    private func resetGlobalMutationAuthority() {
        VocabMutationAuthorityRuntime.invalidate()
    }

    private func drafts(count: Int) -> [WordDraft] {
        (0..<count).map { WordDraft(term: "word-\($0)", meanings: "뜻-\($0)") }
    }

    private func assertMacAuthoringRequired(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            guard case LearningError.vocabularyAuthoringRequiresMac = $0 else {
                return XCTFail("Unexpected error: \($0)", file: file, line: line)
            }
        }
    }

    private func assertIntegrityBlocked(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            guard case LearningError.mutationsBlockedForIntegrity = $0 else {
                return XCTFail("Unexpected error: \($0)", file: file, line: line)
            }
        }
    }
}
