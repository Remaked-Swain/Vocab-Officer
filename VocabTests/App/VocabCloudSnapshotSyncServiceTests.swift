import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabCloudSnapshotSyncServiceTests: XCTestCase {
    func testMirroredModeNeverAllowsAutomaticSnapshotBatchSync() {
        XCTAssertFalse(VocabAutomaticSnapshotSyncPolicy.allowsAutomaticBatchSync(syncMode: .cloudKitPrivate))
    }

    func testUploadLocalSnapshotSavesExportedWordsToStore() async throws {
        let context = try makeContext()
        let word = WordRecord(term: "train")
        let meaning = MeaningRecord(text: "기차")
        meaning.word = word
        word.appendMeaning(meaning)
        context.insert(word)
        context.insert(meaning)
        try context.save()
        let store = MemorySnapshotStore()
        let service = VocabCloudSnapshotSyncService(store: store)

        let result = try await service.uploadLocalSnapshot(
            context: context,
            now: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(result.wordCount, 1)
        XCTAssertEqual(store.snapshot?.words.first?.term, "train")
    }

    func testDownloadSnapshotReplacesPhoneLocalStore() async throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "old"))
        try context.save()
        let snapshot = makeSnapshot(term: "subway", meaning: "지하철")
        let service = VocabCloudSnapshotSyncService(store: MemorySnapshotStore(snapshot: snapshot))

        let result = try await service.replaceLocalStoreFromCloud(context: context)

        XCTAssertEqual(result?.wordCount, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["subway"])
    }

    func testDownloadSnapshotStopsBeforeReplaceWhenCheckpointFails() async throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "old"))
        try context.save()
        let snapshot = makeSnapshot(term: "subway", meaning: "지하철")
        let stateStore = MemoryBatchSyncStateStore()
        let originalCursor = try cursor(for: snapshot)
        stateStore.saveCursor(originalCursor)
        let service = VocabCloudSnapshotSyncService(
            store: MemorySnapshotStore(snapshot: snapshot),
            stateStore: stateStore,
            localStoreCheckpointCreator: { _ in throw TestCheckpointError.failed }
        )

        do {
            _ = try await service.replaceLocalStoreFromCloud(
                context: context,
                syncedAt: Date(timeIntervalSince1970: 500)
            )
            XCTFail("Expected checkpoint failure to stop cloud import.")
        } catch VocabCloudBatchSyncError.localCheckpointFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["old"])
        XCTAssertEqual(stateStore.cursor, originalCursor)
    }

    func testInspectCloudSnapshotReturnsSummaryWithoutReplacingLocalStore() async throws {
        let context = try makeContext()
        context.insert(WordRecord(term: "local"))
        try context.save()
        let snapshot = makeSnapshot(term: "cloud", meaning: "구름")
        let service = VocabCloudSnapshotSyncService(store: MemorySnapshotStore(snapshot: snapshot))

        let result = try await service.inspectCloudSnapshot()

        XCTAssertEqual(result?.wordCount, 1)
        XCTAssertEqual(result?.dailySetCount, 0)
        XCTAssertEqual(result?.exportedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["local"])
    }

    func testBatchSyncUploadsWhenOnlyLocalChangedAfterBaseline() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let store = MemorySnapshotStore(snapshot: baseline)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        let word = WordRecord(term: "local")
        context.insert(word)
        try context.save()

        let plan = try await service.planBatchSync(context: context)

        XCTAssertEqual(plan.action, .uploadLocalSnapshot)
    }

    func testBatchSyncDownloadsWhenOnlyCloudChangedAfterBaseline() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        try VocabSyncSnapshotService.replaceLocalStore(with: baseline, context: context, syncMode: .localOnly)

        let plan = try await service.planBatchSync(context: context)

        XCTAssertEqual(plan.action, .downloadCloudSnapshot)
    }

    func testBatchSyncConflictsWhenLocalAndCloudBothChangedAfterBaseline() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        let word = WordRecord(term: "local")
        context.insert(word)
        try context.save()

        let plan = try await service.planBatchSync(context: context)

        XCTAssertEqual(plan.action, .conflict)
    }

    func testBatchSyncRequiresReadinessBeforeMutatingStore() async throws {
        let context = try makeContext()
        let snapshot = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: snapshot)
        let stateStore = MemoryBatchSyncStateStore()
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        let readiness = VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: VocabCloudSyncRuntimeConditions(
                hasSyncBaseline: false,
                isNetworkAvailable: true,
                isNetworkConstrained: false,
                isLowPowerModeEnabled: false,
                isUserInitiated: false
            )
        )

        let result = try await service.runBatchSyncIfReady(context: context, readiness: readiness)

        XCTAssertEqual(result.action, .blocked)
        XCTAssertNil(stateStore.cursor)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WordRecord>()).isEmpty)
    }

    func testBatchSyncUploadConflictsWhenCloudChangesAfterPlan() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let updatedCloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: baseline)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        context.insert(WordRecord(term: "local"))
        try context.save()
        let originalCursor = stateStore.cursor

        let plan = try await service.planBatchSync(context: context)
        store.snapshot = updatedCloud
        let result = try await service.applyBatchSyncPlan(
            plan,
            context: context,
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .conflict)
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertEqual(stateStore.cursor, originalCursor)
        XCTAssertEqual(store.snapshot, updatedCloud)
    }

    func testBatchSyncUploadConflictsWhenCloudChangesAfterConditionalFetchBeforeSave() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let updatedCloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: baseline)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        context.insert(WordRecord(term: "local"))
        try context.save()
        let originalCursor = stateStore.cursor

        let plan = try await service.planBatchSync(context: context)
        store.snapshotToInstallAfterConditionalFetch = updatedCloud
        let result = try await service.applyBatchSyncPlan(
            plan,
            context: context,
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .conflict)
        XCTAssertEqual(store.conditionalSaveCallCount, 1)
        XCTAssertEqual(store.saveCallCount, 0)
        XCTAssertEqual(stateStore.cursor, originalCursor)
        XCTAssertEqual(store.snapshot, updatedCloud)
    }

    func testBatchSyncDownloadConflictsWhenLocalChangesAfterPlan() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        try VocabSyncSnapshotService.replaceLocalStore(with: baseline, context: context, syncMode: .localOnly)
        let originalCursor = stateStore.cursor

        let plan = try await service.planBatchSync(context: context)
        context.insert(WordRecord(term: "local-after-plan"))
        try context.save()
        let result = try await service.applyBatchSyncPlan(
            plan,
            context: context,
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .conflict)
        XCTAssertEqual(stateStore.cursor, originalCursor)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<WordRecord>()).map(\.term).sorted(),
            ["baseline", "local-after-plan"]
        )
    }

    func testBatchSyncUpdatesCursorOnlyAfterSuccessfulUpload() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let store = MemorySnapshotStore(snapshot: baseline)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        context.insert(WordRecord(term: "local"))
        try context.save()

        let result = try await service.runBatchSyncIfReady(
            context: context,
            readiness: readyForBatchSync(),
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .uploadLocalSnapshot)
        XCTAssertEqual(store.saveCallCount, 1)
        XCTAssertEqual(stateStore.cursor?.snapshotFingerprint, try store.snapshot?.contentFingerprint())
        XCTAssertEqual(stateStore.cursor?.syncedAt, Date(timeIntervalSince1970: 500))
    }

    func testBatchSyncUpdatesCursorOnlyAfterSuccessfulDownload() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let service = VocabCloudSnapshotSyncService(store: store, stateStore: stateStore)
        try VocabSyncSnapshotService.replaceLocalStore(with: baseline, context: context, syncMode: .localOnly)

        let result = try await service.runBatchSyncIfReady(
            context: context,
            readiness: readyForBatchSync(),
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .downloadCloudSnapshot)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["cloud"])
        XCTAssertEqual(stateStore.cursor?.snapshotFingerprint, try cloud.contentFingerprint())
        XCTAssertEqual(stateStore.cursor?.syncedAt, Date(timeIntervalSince1970: 500))
    }

    func testBatchSyncSuccessfulDownloadReturnsCheckpointDirectoryName() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        stateStore.saveCursor(try cursor(for: baseline))
        let checkpoint = VocabLocalStoreCheckpoint(
            directory: URL(fileURLWithPath: "/tmp/VocabStoreCheckpoint-test"),
            copiedFiles: ["Vocab.store"]
        )
        let service = VocabCloudSnapshotSyncService(
            store: store,
            stateStore: stateStore,
            localStoreCheckpointCreator: { _ in checkpoint }
        )
        try VocabSyncSnapshotService.replaceLocalStore(with: baseline, context: context, syncMode: .localOnly)

        let result = try await service.runBatchSyncIfReady(
            context: context,
            readiness: readyForBatchSync(),
            now: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.action, .downloadCloudSnapshot)
        XCTAssertEqual(result.snapshotResult?.checkpointDirectoryName, "VocabStoreCheckpoint-test")
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["cloud"])
    }

    func testBatchSyncDownloadStopsBeforeReplaceAndCursorUpdateWhenCheckpointFails() async throws {
        let context = try makeContext()
        let baseline = makeSnapshot(term: "baseline", meaning: "기준")
        let cloud = makeSnapshot(term: "cloud", meaning: "구름")
        let store = MemorySnapshotStore(snapshot: cloud)
        let stateStore = MemoryBatchSyncStateStore()
        let originalCursor = try cursor(for: baseline)
        stateStore.saveCursor(originalCursor)
        let service = VocabCloudSnapshotSyncService(
            store: store,
            stateStore: stateStore,
            localStoreCheckpointCreator: { _ in throw TestCheckpointError.failed }
        )
        try VocabSyncSnapshotService.replaceLocalStore(with: baseline, context: context, syncMode: .localOnly)

        do {
            _ = try await service.runBatchSyncIfReady(
                context: context,
                readiness: readyForBatchSync(),
                now: Date(timeIntervalSince1970: 500)
            )
            XCTFail("Expected checkpoint failure to stop batch download.")
        } catch VocabCloudBatchSyncError.localCheckpointFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).map(\.term), ["baseline"])
        XCTAssertEqual(stateStore.cursor, originalCursor)
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema(VocabModelContainerFactory.schemaModels)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeSnapshot(term: String, meaning: String) -> VocabSyncSnapshot {
        let metadataDate = Date(timeIntervalSince1970: 300)
        var snapshot = VocabSyncSnapshot(
            formatVersion: VocabSyncSnapshotService.currentFormatVersion,
            exportedAt: Date(timeIntervalSince1970: 300),
            syncMetadata: VocabSyncSnapshot.SyncMetadataPayload(
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                bootstrapUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                contentFingerprint: "",
                expectedCounts: VocabEntityCounts(
                    words: 1,
                    meanings: 1,
                    dailySets: 0,
                    dailySetItems: 0,
                    testSessions: 0,
                    attempts: 0,
                    anonymousAggregates: 0,
                    memoryAidCaches: 0,
                    tombstones: 0
                ),
                createdAt: metadataDate,
                completedAt: metadataDate,
                updatedAt: metadataDate,
                originDeviceID: "fixture-device"
            ),
            words: [
                VocabSyncSnapshot.WordPayload(
                    id: UUID(),
                    term: term,
                    englishAliases: [],
                    createdAt: Date(timeIntervalSince1970: 100),
                    statusRaw: "active",
                    updatedAt: metadataDate,
                    originDeviceID: "fixture-device",
                    deletedAt: nil,
                    meanings: [
                        VocabSyncSnapshot.MeaningPayload(
                            id: UUID(),
                            text: meaning,
                            isCore: true,
                            aliases: [],
                            successDays: [],
                            updatedAt: metadataDate,
                            originDeviceID: "fixture-device"
                        )
                    ],
                    reviewState: nil
                )
            ],
            dailySets: []
        )
        let fingerprint = try! snapshot.contentFingerprint()
        snapshot.syncMetadata?.contentFingerprint = fingerprint
        return snapshot
    }

    private func cursor(for snapshot: VocabSyncSnapshot) throws -> VocabCloudBatchSyncCursor {
        let metadata = try VocabCloudSnapshotMetadata(snapshot: snapshot)
        return VocabCloudBatchSyncCursor(
            snapshotFingerprint: metadata.fingerprint,
            cloudExportedAt: metadata.exportedAt,
            syncedAt: Date(timeIntervalSince1970: 400)
        )
    }

    private func readyForBatchSync() -> VocabCloudSyncReadiness {
        VocabCloudSyncReadiness(
            accountState: .available,
            allowsCloudKitRuntime: true,
            hasCloudKitEntitlement: true,
            isSchemaCloudKitReady: true,
            hasConfirmedFirstUpload: true,
            runtimeConditions: VocabCloudSyncRuntimeConditions(
                hasSyncBaseline: true,
                isNetworkAvailable: true,
                isNetworkConstrained: false,
                isLowPowerModeEnabled: false,
                isUserInitiated: false
            )
        )
    }
}

private enum TestCheckpointError: Error {
    case failed
}

private final class MemorySnapshotStore: VocabCloudSnapshotStoring {
    var snapshot: VocabSyncSnapshot?
    var snapshotToInstallAfterConditionalFetch: VocabSyncSnapshot?
    private(set) var saveCallCount = 0
    private(set) var conditionalSaveCallCount = 0

    init(snapshot: VocabSyncSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func save(_ snapshot: VocabSyncSnapshot) async throws {
        saveCallCount += 1
        self.snapshot = snapshot
    }

    func save(
        _ snapshot: VocabSyncSnapshot,
        ifCloudMetadataMatches expectedMetadata: VocabCloudSnapshotMetadata?
    ) async throws -> Bool {
        conditionalSaveCallCount += 1
        let fetchedMetadata = try self.snapshot.map(VocabCloudSnapshotMetadata.init(snapshot:))
        guard fetchedMetadata == expectedMetadata else { return false }
        if let snapshotToInstallAfterConditionalFetch {
            self.snapshotToInstallAfterConditionalFetch = nil
            self.snapshot = snapshotToInstallAfterConditionalFetch
            return false
        }
        saveCallCount += 1
        self.snapshot = snapshot
        return true
    }

    func load() async throws -> VocabSyncSnapshot? {
        snapshot
    }
}

private final class MemoryBatchSyncStateStore: VocabCloudBatchSyncStateStoring {
    var cursor: VocabCloudBatchSyncCursor?

    func loadCursor() -> VocabCloudBatchSyncCursor? {
        cursor
    }

    func saveCursor(_ cursor: VocabCloudBatchSyncCursor) {
        self.cursor = cursor
    }
}
