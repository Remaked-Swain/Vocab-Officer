import SwiftData
import XCTest
@testable import Vocab

final class VocabModelContainerFactoryTests: XCTestCase {
    func testDefaultSyncModeKeepsExistingMacStoreLocalOnly() throws {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)

        let configuration = try VocabModelContainerFactory.makeConfiguration(syncMode: .localOnly)

        XCTAssertNil(configuration.cloudKitContainerIdentifier)
        XCTAssertTrue(configuration.url.lastPathComponent == "Vocab.store")
        XCTAssertTrue(configuration.url.deletingLastPathComponent().lastPathComponent == "Vocab")
    }

    func testCloudKitModeUsesPrivateVocabContainer() throws {
        let configuration = try VocabModelContainerFactory.makeConfiguration(syncMode: .cloudKitPrivate)

        XCTAssertEqual(configuration.cloudKitContainerIdentifier, VocabSyncMode.cloudKitContainerIdentifier)
        XCTAssertTrue(configuration.url.lastPathComponent == "VocabMirrored.store")
    }

    func testLocalAndMirroredStoresUseSeparateFiles() throws {
        let local = try VocabModelContainerFactory.makeConfiguration(syncMode: .localOnly)
        let mirrored = try VocabModelContainerFactory.makeConfiguration(syncMode: .cloudKitPrivate)

        XCTAssertNotEqual(local.url, mirrored.url)
        XCTAssertEqual(local.url.deletingLastPathComponent(), mirrored.url.deletingLastPathComponent())
        XCTAssertEqual(local.url.lastPathComponent, "Vocab.store")
        XCTAssertEqual(mirrored.url.lastPathComponent, "VocabMirrored.store")
    }

    func testValidRecoveryManifestNeverShadowsNormalLocalStoreURL() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabLocalPathSafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let recoveryRoot = appSupport.appendingPathComponent("Vocab/RecoveryReplica", isDirectory: true)
        let generation = recoveryGeneration()
        let generationURL = VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: recoveryRoot)
        try FileManager.default.createDirectory(at: generationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("verified-generation".utf8).write(to: generationURL)
        try VocabRecoveryReplicaManifestStore.save(
            VocabRecoveryReplicaManifest(currentGenerationID: generation.id, generations: [generation]),
            root: recoveryRoot
        )

        let localURL = try VocabModelContainerFactory.localStoreURL(applicationSupportURL: appSupport)

        XCTAssertEqual(localURL, appSupport.appendingPathComponent("Vocab/Vocab.store"))
        XCTAssertNotEqual(localURL, generationURL)
        XCTAssertEqual(
            try VocabRecoveryReplicaManifestStore.verifiedRecoveryStoreURL(root: recoveryRoot),
            generationURL
        )
    }

    func testLocalOnlyWritesNeverMutateVerifiedRecoveryGenerationOrManifest() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabLocalWriteSafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let recoveryRoot = appSupport.appendingPathComponent("Vocab/RecoveryReplica", isDirectory: true)
        let generation = recoveryGeneration()
        let generationURL = VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: recoveryRoot)
        try FileManager.default.createDirectory(at: generationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let generationContainer = try VocabModelContainerFactory.makeContainer(
                syncMode: .localOnly,
                storeURL: generationURL
            )
            let context = ModelContext(generationContainer)
            context.insert(WordRecord(term: "recovery-only"))
            try context.save()
        }
        try VocabRecoveryReplicaManifestStore.save(
            VocabRecoveryReplicaManifest(currentGenerationID: generation.id, generations: [generation]),
            root: recoveryRoot
        )
        let manifestURL = VocabRecoveryReplicaManifestStore.manifestURL(root: recoveryRoot)
        let manifestBefore = try Data(contentsOf: manifestURL)

        let localURL = try VocabModelContainerFactory.localStoreURL(applicationSupportURL: appSupport)
        do {
            let localContainer = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: localURL)
            let context = ModelContext(localContainer)
            context.insert(WordRecord(term: "active-local"))
            try context.save()
        }

        let localContainer = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: localURL)
        let recoveryContainer = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: generationURL)
        XCTAssertEqual(try ModelContext(localContainer).fetch(FetchDescriptor<WordRecord>()).map(\.term), ["active-local"])
        XCTAssertEqual(
            try ModelContext(recoveryContainer).fetch(FetchDescriptor<WordRecord>()).map(\.term),
            ["recovery-only"]
        )
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
        XCTAssertEqual(try VocabRecoveryReplicaManifestStore.load(root: recoveryRoot)?.currentGenerationID, generation.id)
    }

    private func recoveryGeneration() -> VocabRecoveryReplicaManifest.Generation {
        VocabRecoveryReplicaManifest.Generation(
            id: UUID(),
            seoulDay: "2026-07-18",
            sourceFingerprint: "verified-fingerprint",
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            counts: .zero,
            requiredIDDigest: "verified-id-digest",
            verifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func testCloudKitCompatibilityProbeUsesTemporaryMirroredStore() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabCloudProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let probeURL = temporaryDirectory.appendingPathComponent("ProbeMirrored.store")
        let configuration = ModelConfiguration(
            "VocabCloudProbe",
            schema: Schema(VocabModelContainerFactory.schemaModels),
            url: probeURL,
            cloudKitDatabase: .private(VocabSyncMode.cloudKitContainerIdentifier)
        )

        XCTAssertEqual(configuration.url, probeURL)
        XCTAssertEqual(configuration.cloudKitContainerIdentifier, VocabSyncMode.cloudKitContainerIdentifier)
    }

    func testSyncModeReadsUserDefaultsWhenExplicitlySet() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults, allowsCloudKit: true), .cloudKitPrivate)
    }

    func testCloudKitModeFallsBackToLocalUntilRuntimeAllowsIt() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)
    }

    func testInvalidPersistedSyncModeFallsBackToLocalOnly() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!
        defaults.set("invalid", forKey: VocabSyncMode.userDefaultsKey)

        XCTAssertEqual(VocabSyncMode.current(defaults: defaults), .localOnly)
    }

    func testIOSFirstLaunchDefaultsToMirroredConnectionWithoutPersistingASeedMode() {
        let defaults = UserDefaults(suiteName: "VocabTests.\(UUID().uuidString)")!

        XCTAssertEqual(
            VocabSyncMode.current(defaults: defaults, allowsCloudKit: true, defaultMode: .cloudKitPrivate),
            .cloudKitPrivate
        )
        XCTAssertNil(defaults.string(forKey: VocabSyncMode.userDefaultsKey))
    }

    func testMirroredOpenFailureDoesNotAttemptWritableLocalFallback() throws {
        var attemptedModes: [VocabSyncMode] = []

        let plan = VocabModelContainerFactory.makeLaunchPlan(preferredMode: .cloudKitPrivate) { mode in
            attemptedModes.append(mode)
            throw TestOpenError.failed
        }

        XCTAssertEqual(attemptedModes, [.cloudKitPrivate])
        XCTAssertFalse(plan.isUsable)
        XCTAssertEqual(plan.mode, .cloudKitPrivate)
        XCTAssertNotNil(plan.connectionError)
    }

    func testPersistentTemporaryStoreReopensWithStableMetadataAndTombstone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabPersistentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Persistent.store")
        let schema = Schema(VocabModelContainerFactory.schemaModels)

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration("Persistent", schema: schema, url: url, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            let word = WordRecord(term: "durable")
            word.originDeviceID = "test-device"
            context.insert(word)
            context.insert(RecordTombstone(recordID: word.id, recordType: "WordRecord"))
            context.insert(BootstrapExportReceipt(
                requestID: UUID(),
                fingerprint: "persistent-fingerprint",
                storeUUID: "persistent-store",
                transactionCommittedAt: Date(timeIntervalSince1970: 123),
                probeGeneration: 2,
                nonce: UUID()
            ))
            try context.save()
        }

        let reopened = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration("Persistent", schema: schema, url: url, cloudKitDatabase: .none)
        )
        let context = ModelContext(reopened)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).first?.originDeviceID, "test-device")
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecordTombstone>()).first?.recordType, "WordRecord")
        let receipt = try XCTUnwrap(context.fetch(FetchDescriptor<BootstrapExportReceipt>()).first)
        XCTAssertEqual(receipt.fingerprint, "persistent-fingerprint")
        XCTAssertEqual(receipt.storeUUID, "persistent-store")
        XCTAssertEqual(receipt.probeGeneration, 2)
    }

    func testExactLegacyProductionSchemaMigratesThroughFactoryAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabSchemaMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Previous.store")
        let wordID = UUID()
        let meaningID = UUID()
        let setID = UUID()
        let itemID = UUID()
        let sessionID = UUID()
        let attemptID = UUID()
        let reviewID = UUID()
        let aggregateID = UUID()
        let cacheID = UUID()
        let secondaryWordID = UUID()
        let createdAt = Date(timeIntervalSince1970: 10)
        let answeredAt = Date(timeIntervalSince1970: 20)
        let completedAt = Date(timeIntervalSince1970: 30)
        let deletedAt = Date(timeIntervalSince1970: 40)

        do {
            let v1Schema = Schema(VocabSchemaV1.models)
            let v1Container = try ModelContainer(
                for: v1Schema,
                configurations: ModelConfiguration("Previous", schema: v1Schema, url: storeURL, cloudKitDatabase: .none)
            )
            let context = ModelContext(v1Container)
            let word = VocabSchemaV1.WordRecord(term: "Legacy Term", createdAt: createdAt)
            word.id = wordID
            word.normalizedTerm = "legacy term"
            word.englishAliases = ["alias-one", "alias-two"]
            word.statusRaw = "mastered"
            word.deletedAt = deletedAt

            let meaning = VocabSchemaV1.MeaningRecord(text: "옛 뜻", isCore: false, aliases: ["별칭"])
            meaning.id = meaningID
            meaning.normalizedText = "옛뜻"
            meaning.successDays = ["2026-01-01", "2026-01-02"]
            meaning.word = word
            word.meanings = [meaning]

            let attempt = VocabSchemaV1.AttemptRecord(
                directionRaw: "영어 -> 한국어",
                modeRaw: "복습",
                sessionID: sessionID,
                questionIndex: 7,
                seoulDay: "2026-01-03",
                prompt: "Legacy Term",
                submittedAnswer: "옛 뜻",
                automaticJudgementRaw: "incorrect",
                finalJudgementRaw: "correct",
                matchedMeaningID: meaningID,
                answeredAt: answeredAt
            )
            attempt.id = attemptID
            attempt.correctionRaw = "acceptedAlias"
            attempt.word = word
            word.attempts = [attempt]

            let review = VocabSchemaV1.ReviewStateRecord()
            review.id = reviewID
            review.failureCheck = 3
            review.activePriority = 2
            review.enToKoStreak = 4
            review.koToEnStreak = 5
            review.koToEnSuccessDays = ["2026-01-01"]
            review.latestWrongDirection = "한국어 -> 영어"
            review.latestWrongAt = answeredAt
            review.lastTestedAt = completedAt
            review.presentationCount = 9
            review.lastPresentedAt = createdAt
            review.word = word
            word.reviewState = review

            let set = VocabSchemaV1.DailySetRecord(seoulDay: "2026-01-03", createdAt: createdAt)
            set.id = setID
            set.completedAt = completedAt
            let item = VocabSchemaV1.DailySetItemRecord(orderIndex: 6, entryKind: "new", wordID: wordID)
            item.id = itemID
            item.set = set
            set.items = [item]

            let session = VocabSchemaV1.TestSessionRecord(
                id: sessionID,
                directionRaw: "영어 -> 한국어",
                modeRaw: "복습",
                seoulDay: "2026-01-03",
                wordIDs: [wordID, secondaryWordID],
                wasReduced: true,
                startedAt: createdAt
            )
            session.completedAt = completedAt

            let aggregate = VocabSchemaV1.AnonymousAggregateRecord(seoulDay: "2026-01-03", modeRaw: "복습")
            aggregate.id = aggregateID
            aggregate.correctCount = 11
            aggregate.incorrectCount = 12
            aggregate.unknownCount = 13
            aggregate.deletedMasteredCount = 14

            let cache = VocabSchemaV1.MemoryAidCacheRecord(
                wordID: wordID,
                modelRaw: "legacy-model",
                promptVersion: 4,
                contentSignature: "legacy-signature",
                markdown: "legacy markdown",
                generatedAt: completedAt
            )
            cache.id = cacheID

            context.insert(word)
            context.insert(set)
            context.insert(session)
            context.insert(aggregate)
            context.insert(cache)
            try context.save()
        }

        func openCurrent() throws -> ModelContainer {
            try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: storeURL)
        }

        do {
            let migrated = try openCurrent()
            let context = ModelContext(migrated)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<WordRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MeaningRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailySetRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailySetItemRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<TestSessionRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AttemptRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewStateRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AnonymousAggregateRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryAidCacheRecord>()), 1)
            let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first)
            XCTAssertEqual(word.id, wordID)
            XCTAssertEqual(word.term, "Legacy Term")
            XCTAssertEqual(word.normalizedTerm, "legacy term")
            XCTAssertEqual(word.englishAliases, ["alias-one", "alias-two"])
            XCTAssertEqual(word.createdAt, createdAt)
            XCTAssertEqual(word.statusRaw, "mastered")
            XCTAssertEqual(word.deletedAt, deletedAt)
            XCTAssertEqual(word.updatedAt, .distantPast)
            XCTAssertEqual(word.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            let meaning = try XCTUnwrap(word.allMeanings.first)
            XCTAssertEqual(meaning.id, meaningID)
            XCTAssertEqual(meaning.word?.id, wordID)
            XCTAssertEqual(meaning.text, "옛 뜻")
            XCTAssertEqual(meaning.normalizedText, "옛뜻")
            XCTAssertFalse(meaning.isCore)
            XCTAssertEqual(meaning.aliases, ["별칭"])
            XCTAssertEqual(meaning.successDays, ["2026-01-01", "2026-01-02"])
            XCTAssertEqual(meaning.updatedAt, .distantPast)
            XCTAssertEqual(meaning.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(meaning.deletedAt)
            let attempt = try XCTUnwrap(word.allAttempts.first)
            XCTAssertEqual(attempt.id, attemptID)
            XCTAssertEqual(attempt.word?.id, wordID)
            XCTAssertEqual(attempt.directionRaw, "영어 -> 한국어")
            XCTAssertEqual(attempt.modeRaw, "복습")
            XCTAssertEqual(attempt.sessionID, sessionID)
            XCTAssertEqual(attempt.questionIndex, 7)
            XCTAssertEqual(attempt.seoulDay, "2026-01-03")
            XCTAssertEqual(attempt.prompt, "Legacy Term")
            XCTAssertEqual(attempt.submittedAnswer, "옛 뜻")
            XCTAssertEqual(attempt.automaticJudgementRaw, "incorrect")
            XCTAssertEqual(attempt.finalJudgementRaw, "correct")
            XCTAssertEqual(attempt.correctionRaw, "acceptedAlias")
            XCTAssertEqual(attempt.matchedMeaningID, meaningID)
            XCTAssertEqual(attempt.answeredAt, answeredAt)
            XCTAssertEqual(attempt.updatedAt, .distantPast)
            XCTAssertEqual(attempt.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(attempt.deletedAt)
            let review = try XCTUnwrap(word.reviewState)
            XCTAssertEqual(review.id, reviewID)
            XCTAssertEqual(review.word?.id, wordID)
            XCTAssertEqual(review.failureCheck, 3)
            XCTAssertEqual(review.activePriority, 2)
            XCTAssertEqual(review.enToKoStreak, 4)
            XCTAssertEqual(review.koToEnStreak, 5)
            XCTAssertEqual(review.koToEnSuccessDays, ["2026-01-01"])
            XCTAssertEqual(review.latestWrongDirection, "한국어 -> 영어")
            XCTAssertEqual(review.latestWrongAt, answeredAt)
            XCTAssertEqual(review.lastTestedAt, completedAt)
            XCTAssertEqual(review.presentationCount, 9)
            XCTAssertEqual(review.lastPresentedAt, createdAt)
            XCTAssertEqual(review.updatedAt, .distantPast)
            XCTAssertEqual(review.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(review.deletedAt)
            let set = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first)
            XCTAssertEqual(set.id, setID)
            XCTAssertEqual(set.seoulDay, "2026-01-03")
            XCTAssertEqual(set.createdAt, createdAt)
            XCTAssertEqual(set.completedAt, completedAt)
            XCTAssertEqual(set.updatedAt, .distantPast)
            XCTAssertEqual(set.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(set.deletedAt)
            let item = try XCTUnwrap(set.allItems.first)
            XCTAssertEqual(item.id, itemID)
            XCTAssertEqual(item.set?.id, setID)
            XCTAssertEqual(item.orderIndex, 6)
            XCTAssertEqual(item.entryKind, "new")
            XCTAssertEqual(item.wordID, wordID)
            XCTAssertEqual(item.updatedAt, .distantPast)
            XCTAssertEqual(item.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(item.deletedAt)
            let session = try XCTUnwrap(context.fetch(FetchDescriptor<TestSessionRecord>()).first)
            XCTAssertEqual(session.id, sessionID)
            XCTAssertEqual(session.directionRaw, "영어 -> 한국어")
            XCTAssertEqual(session.modeRaw, "복습")
            XCTAssertEqual(session.seoulDay, "2026-01-03")
            XCTAssertEqual(session.startedAt, createdAt)
            XCTAssertEqual(session.wordIDs, [wordID, secondaryWordID])
            XCTAssertTrue(session.wasReduced)
            XCTAssertEqual(session.completedAt, completedAt)
            XCTAssertEqual(session.updatedAt, .distantPast)
            XCTAssertEqual(session.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(session.deletedAt)
            let aggregate = try XCTUnwrap(context.fetch(FetchDescriptor<AnonymousAggregateRecord>()).first)
            XCTAssertEqual(aggregate.id, aggregateID)
            XCTAssertEqual(aggregate.seoulDay, "2026-01-03")
            XCTAssertEqual(aggregate.modeRaw, "복습")
            XCTAssertEqual(aggregate.correctCount, 11)
            XCTAssertEqual(aggregate.incorrectCount, 12)
            XCTAssertEqual(aggregate.unknownCount, 13)
            XCTAssertEqual(aggregate.deletedMasteredCount, 14)
            XCTAssertEqual(aggregate.updatedAt, .distantPast)
            XCTAssertEqual(aggregate.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(aggregate.deletedAt)
            let cache = try XCTUnwrap(context.fetch(FetchDescriptor<MemoryAidCacheRecord>()).first)
            XCTAssertEqual(cache.id, cacheID)
            XCTAssertEqual(cache.wordID, wordID)
            XCTAssertEqual(cache.modelRaw, "legacy-model")
            XCTAssertEqual(cache.promptVersion, 4)
            XCTAssertEqual(cache.contentSignature, "legacy-signature")
            XCTAssertEqual(cache.markdown, "legacy markdown")
            XCTAssertEqual(cache.generatedAt, completedAt)
            XCTAssertEqual(cache.updatedAt, .distantPast)
            XCTAssertEqual(cache.originDeviceID, VocabRecordMetadata.legacyOriginDeviceID)
            XCTAssertNil(cache.deletedAt)

            word.term = "Migrated Term"
            word.updatedAt = Date(timeIntervalSince1970: 50)
            meaning.aliases.append("추가")
            review.failureCheck = 8
            attempt.finalJudgementRaw = "incorrect"
            try context.save()
        }

        let reopened = try openCurrent()
        let reopenedContext = ModelContext(reopened)
        let reopenedWord = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<WordRecord>()).first)
        XCTAssertEqual(reopenedWord.id, wordID)
        XCTAssertEqual(reopenedWord.term, "Migrated Term")
        XCTAssertEqual(reopenedWord.updatedAt, Date(timeIntervalSince1970: 50))
        XCTAssertEqual(reopenedWord.allMeanings.first?.aliases, ["별칭", "추가"])
        XCTAssertEqual(reopenedWord.reviewState?.failureCheck, 8)
        XCTAssertEqual(reopenedWord.allAttempts.first?.finalJudgementRaw, "incorrect")
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<DailySetItemRecord>()), 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<TestSessionRecord>()), 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<AnonymousAggregateRecord>()), 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<MemoryAidCacheRecord>()), 1)
    }
}

private enum TestOpenError: Error {
    case failed
}
