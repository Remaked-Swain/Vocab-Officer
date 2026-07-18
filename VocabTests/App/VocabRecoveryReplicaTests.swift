import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabRecoveryReplicaTests: XCTestCase {
    private enum TestError: Error {
        case failedToPublishGeneration
    }

    private static var cachedPerformanceContainer: ModelContainer?
    func testReplicaRejectsMissingOrStaleAuditReceipt() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        await XCTAssertThrowsErrorAsync {
            _ = try await VocabRecoveryReplicaService().refreshIfEligible(
                modelContainer: try sourceContainer(term: "not-audited"),
                syncMode: .cloudKitPrivate,
                rootURL: root,
                auditReceiptURL: root.appendingPathComponent("missing-receipt.json")
            )
        }
        XCTAssertNil(try VocabRecoveryReplicaManifestStore.load(root: root))

        let container = try sourceContainer(term: "audited")
        let receiptURL = try writeAuditReceipt(container: container, root: root)
        let context = ModelContext(container)
        let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first)
        word.term = "changed-after-audit"
        word.normalizedTerm = TextNormalizer.normalizeEnglish(word.term)
        word.updatedAt = .now
        try context.save()
        await XCTAssertThrowsErrorAsync {
            _ = try await VocabRecoveryReplicaService().refreshIfEligible(
                modelContainer: container,
                syncMode: .cloudKitPrivate,
                rootURL: root,
                auditReceiptURL: receiptURL
            )
        }
        XCTAssertNil(try VocabRecoveryReplicaManifestStore.load(root: root))
    }

    func testReplicaSkipsWhileReconciliationIsActive() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try sourceContainer(term: "busy")
        let receiptURL = try writeAuditReceipt(container: container, root: root)
        let barrier = VocabSyncWorkBarrier()
        _ = await barrier.beginReconciliation()

        let result = try await VocabRecoveryReplicaService(barrier: barrier).refreshIfEligible(
            modelContainer: container,
            syncMode: .cloudKitPrivate,
            rootURL: root,
            auditReceiptURL: receiptURL
        )
        await barrier.finishReconciliation()

        XCTAssertEqual(result, .skippedIneligible)
    }

    func testReplicaPublishesVerifiedGenerationAndSkipsSameDay() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try sourceContainer(term: "first")
        let service = VocabRecoveryReplicaService()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let receiptURL = try writeAuditReceipt(container: container, root: root, now: now)

        let first = try await service.refreshIfEligible(
            modelContainer: container,
            syncMode: .cloudKitPrivate,
            now: now,
            rootURL: root,
            auditReceiptURL: receiptURL
        )
        guard case .published(let generationID, maintenancePending: false) = first else {
            return XCTFail("Expected a published generation, got \(first)")
        }
        let manifest = try XCTUnwrap(VocabRecoveryReplicaManifestStore.load(root: root))
        XCTAssertEqual(manifest.currentGenerationID, generationID)
        XCTAssertEqual(manifest.generations.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: VocabRecoveryReplicaManifestStore.storeURL(generationID: generationID, root: root).path
        ))
        let replicaContainer = try VocabModelContainerFactory.makeContainer(
            syncMode: .localOnly,
            storeURL: VocabRecoveryReplicaManifestStore.storeURL(generationID: generationID, root: root)
        )
        XCTAssertEqual(try ModelContext(replicaContainer).fetchCount(FetchDescriptor<WordRecord>()), 1)

        let second = try await service.refreshIfEligible(
            modelContainer: container,
            syncMode: .cloudKitPrivate,
            now: now.addingTimeInterval(60),
            rootURL: root,
            auditReceiptURL: receiptURL
        )
        XCTAssertEqual(second, .skippedAlreadyPublishedToday)
    }

    func testCloudConfiguredStoreBackupReopensAsLocalOnlyWithTechnicalMetadata() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("CloudSource.store")
        let source = try VocabModelContainerFactory.makeContainer(
            syncMode: .cloudKitPrivate,
            storeURL: sourceURL
        )
        try populateSourceContainer(source, term: "cloud-source")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let receiptURL = try writeAuditReceipt(container: source, root: root, now: now)

        let result = try await VocabRecoveryReplicaService().refreshIfEligible(
            modelContainer: source,
            syncMode: .cloudKitPrivate,
            now: now,
            rootURL: root,
            auditReceiptURL: receiptURL
        )
        guard case .published(let generationID, maintenancePending: false) = result else {
            return XCTFail("Expected CloudKit-backed store publication")
        }
        let replica = try VocabModelContainerFactory.makeContainer(
            syncMode: .localOnly,
            storeURL: VocabRecoveryReplicaManifestStore.storeURL(generationID: generationID, root: root)
        )
        let replicaContext = ModelContext(replica)
        XCTAssertEqual(try replicaContext.fetchCount(FetchDescriptor<WordRecord>()), 1)
        XCTAssertEqual(try replicaContext.fetchCount(FetchDescriptor<CloudBootstrapRecord>()), 1)
    }

    func testExplicitRecoveryRequiresApplicationBoundaryConfirmation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "recovery-source")
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "active-local")
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        let manifestBefore = try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root))
        let boundary = try makeApplicationBoundary(storeURL: localStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await boundary.performConfirmedRecovery(
                request: VocabExplicitRecoveryRequest(generationID: generation.id),
                userConfirmed: false,
                recoveryRoot: root,
                localStoreURL: localStore,
                checkpointRoot: checkpointRoot
            )
        }

        XCTAssertNotNil(boundary.launch)
        XCTAssertEqual(try terms(in: localStore), ["active-local"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointRoot.path))
        XCTAssertEqual(try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root)), manifestBefore)
        XCTAssertEqual(try terms(in: VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: root)), ["recovery-source"])
    }

    func testExplicitRecoveryCheckpointsThenRestoresValidatedGeneration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "recovered")
        let generationStore = VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: root)
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "before-recovery")
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        let manifestBefore = try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root))
        let boundary = try makeApplicationBoundary(storeURL: localStore)

        let result = try await boundary.performConfirmedRecovery(
            request: VocabExplicitRecoveryRequest(generationID: generation.id),
            userConfirmed: true,
            recoveryRoot: root,
            localStoreURL: localStore,
            checkpointRoot: checkpointRoot
        )

        XCTAssertEqual(result.generationID, generation.id)
        XCTAssertEqual(try terms(in: result.checkpointStoreURL), ["before-recovery"])
        XCTAssertEqual(try terms(in: localStore), ["recovered"])
        XCTAssertEqual(try terms(in: generationStore), ["recovered"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: result.checkpointStoreURL.deletingLastPathComponent().appendingPathComponent("manifest.json").path
        ))
        XCTAssertEqual(try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root)), manifestBefore)
        XCTAssertFalse(VocabRecoveryReplicaScheduler.automaticRefreshEnabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VocabExplicitRecoverySwapStore.manifestURL(for: localStore).path
        ))
        XCTAssertNotNil(boundary.launch)
    }

    func testExplicitRecoveryStagingFailureNeverWritesTarget() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "staging-source")
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "target-must-not-change")
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        let boundary = try makeApplicationBoundary(storeURL: localStore)
        let originalFileNumber = try systemFileNumber(at: localStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await boundary.performConfirmedRecovery(
                request: VocabExplicitRecoveryRequest(generationID: generation.id),
                userConfirmed: true,
                service: VocabExplicitRecoveryService(injectedFailure: .afterStagingValidation),
                recoveryRoot: root,
                localStoreURL: localStore,
                checkpointRoot: checkpointRoot
            )
        }

        XCTAssertEqual(try systemFileNumber(at: localStore), originalFileNumber)
        XCTAssertEqual(try terms(in: localStore), ["target-must-not-change"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VocabExplicitRecoverySwapStore.manifestURL(for: localStore).path
        ))
    }

    func testInterruptedAtomicSwapRestoresOriginalBeforeReopen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "failed-recovery-source")
        let generationStore = VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: root)
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "must-survive")
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        let manifestBefore = try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root))
        let boundary = try makeApplicationBoundary(storeURL: localStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await boundary.performConfirmedRecovery(
                request: VocabExplicitRecoveryRequest(generationID: generation.id),
                userConfirmed: true,
                service: VocabExplicitRecoveryService(injectedFailure: .afterAtomicSwap),
                recoveryRoot: root,
                localStoreURL: localStore,
                checkpointRoot: checkpointRoot
            )
        }

        XCTAssertEqual(try terms(in: localStore), ["must-survive"])
        XCTAssertEqual(try terms(in: generationStore), ["failed-recovery-source"])
        XCTAssertEqual(try Data(contentsOf: VocabRecoveryReplicaManifestStore.manifestURL(root: root)), manifestBefore)
        let checkpointStores = try FileManager.default.subpathsOfDirectory(atPath: checkpointRoot.path)
            .filter { $0.hasSuffix("/Vocab.store") }
        XCTAssertEqual(checkpointStores.count, 1)
        XCTAssertEqual(try terms(in: checkpointRoot.appendingPathComponent(checkpointStores[0])), ["must-survive"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VocabExplicitRecoverySwapStore.manifestURL(for: localStore).path
        ))
        XCTAssertNotNil(boundary.launch)
    }

    func testInterruptedPreparedSwapKeepsOriginalAndCleansJournal() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "unused-replacement")
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "original")
        let boundary = try makeApplicationBoundary(storeURL: localStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await boundary.performConfirmedRecovery(
                request: VocabExplicitRecoveryRequest(generationID: generation.id),
                userConfirmed: true,
                service: VocabExplicitRecoveryService(injectedFailure: .afterSwapPrepared),
                recoveryRoot: root,
                localStoreURL: localStore,
                checkpointRoot: root.appendingPathComponent("Checkpoints", isDirectory: true)
            )
        }

        XCTAssertEqual(try terms(in: localStore), ["original"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: VocabExplicitRecoverySwapStore.manifestURL(for: localStore).path
        ))
    }

    func testExplicitRecoveryRejectsInvalidGenerationBeforeCheckpoint() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try await publishGeneration(root: root, term: "validated-source")
        let originalManifest = try XCTUnwrap(VocabRecoveryReplicaManifestStore.load(root: root))
        let invalidGeneration = VocabRecoveryReplicaManifest.Generation(
            id: generation.id,
            seoulDay: generation.seoulDay,
            sourceFingerprint: "tampered-fingerprint",
            schemaVersion: generation.schemaVersion,
            counts: generation.counts,
            requiredIDDigest: generation.requiredIDDigest,
            verifiedAt: generation.verifiedAt
        )
        try VocabRecoveryReplicaManifestStore.save(
            VocabRecoveryReplicaManifest(
                currentGenerationID: generation.id,
                generations: originalManifest.generations.map {
                    $0.id == generation.id ? invalidGeneration : $0
                }
            ),
            root: root
        )
        let localStore = root.appendingPathComponent("Active/Vocab.store")
        try writeLocalStore(url: localStore, term: "unchanged-local")
        let checkpointRoot = root.appendingPathComponent("Checkpoints", isDirectory: true)
        let boundary = try makeApplicationBoundary(storeURL: localStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await boundary.performConfirmedRecovery(
                request: VocabExplicitRecoveryRequest(generationID: generation.id),
                userConfirmed: true,
                recoveryRoot: root,
                localStoreURL: localStore,
                checkpointRoot: checkpointRoot
            )
        }

        XCTAssertEqual(try terms(in: localStore), ["unchanged-local"])
        XCTAssertEqual(
            try terms(in: VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: root)),
            ["validated-source"]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointRoot.path))
        XCTAssertEqual(
            try VocabRecoveryReplicaManifestStore.load(root: root)?.generations.first?.sourceFingerprint,
            "tampered-fingerprint"
        )
    }

    func testReplicaRetainsOnlyThreeVerifiedGenerations() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try sourceContainer(term: "generation-0")
        let context = ModelContext(container)
        let service = VocabRecoveryReplicaService()
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for day in 0..<4 {
            let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first)
            word.term = "generation-\(day)"
            word.normalizedTerm = TextNormalizer.normalizeEnglish(word.term)
            word.updatedAt = start.addingTimeInterval(Double(day) * 86_400)
            try context.save()
            let receiptURL = try writeAuditReceipt(
                container: container,
                root: root,
                now: start.addingTimeInterval(Double(day) * 86_400)
            )
            _ = try await service.refreshIfEligible(
                modelContainer: container,
                syncMode: .cloudKitPrivate,
                now: start.addingTimeInterval(Double(day) * 86_400),
                rootURL: root,
                auditReceiptURL: receiptURL
            )
        }

        let manifest = try XCTUnwrap(VocabRecoveryReplicaManifestStore.load(root: root))
        XCTAssertEqual(manifest.generations.count, 3)
        XCTAssertEqual(manifest.currentGenerationID, manifest.generations.first?.id)
        for generation in manifest.generations {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: VocabRecoveryReplicaManifestStore.storeURL(generationID: generation.id, root: root).path
            ))
        }
    }

    func testInjectedFailuresNeverRemovePreviousVerifiedGeneration() async throws {
        for point in VocabRecoveryReplicaFailurePoint.allCases {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let container = try sourceContainer(term: "baseline")
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let baselineService = VocabRecoveryReplicaService()
            let receiptURL = try writeAuditReceipt(container: container, root: root, now: start)
            let baselineResult = try await baselineService.refreshIfEligible(
                modelContainer: container,
                syncMode: .cloudKitPrivate,
                now: start,
                rootURL: root,
                auditReceiptURL: receiptURL
            )
            guard case .published(let baselineID, maintenancePending: false) = baselineResult else {
                return XCTFail("Baseline publication failed")
            }
            let context = ModelContext(container)
            let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first)
            word.term = "changed-\(String(describing: point))"
            word.normalizedTerm = TextNormalizer.normalizeEnglish(word.term)
            word.updatedAt = start.addingTimeInterval(86_400)
            try context.save()
            let changedReceiptURL = try writeAuditReceipt(
                container: container,
                root: root,
                now: start.addingTimeInterval(86_400)
            )

            let failingService = VocabRecoveryReplicaService(injectedFailure: point)
            if point == .pruning {
                let result = try await failingService.refreshIfEligible(
                    modelContainer: container,
                    syncMode: .cloudKitPrivate,
                    now: start.addingTimeInterval(86_400),
                    rootURL: root,
                    auditReceiptURL: changedReceiptURL
                )
                guard case .published(let currentID, maintenancePending: true) = result else {
                    return XCTFail("Pruning must be a committed publication with pending maintenance")
                }
                let committed = try XCTUnwrap(VocabRecoveryReplicaManifestStore.load(root: root))
                XCTAssertEqual(committed.currentGenerationID, currentID)
                _ = try VocabModelContainerFactory.makeContainer(
                    syncMode: .localOnly,
                    storeURL: VocabRecoveryReplicaManifestStore.storeURL(generationID: currentID, root: root)
                )
                continue
            }
            await XCTAssertThrowsErrorAsync {
                _ = try await failingService.refreshIfEligible(
                    modelContainer: container,
                    syncMode: .cloudKitPrivate,
                    now: start.addingTimeInterval(86_400),
                    rootURL: root,
                    auditReceiptURL: changedReceiptURL
                )
            }
            let manifest = try XCTUnwrap(VocabRecoveryReplicaManifestStore.load(root: root))
            XCTAssertEqual(manifest.currentGenerationID, baselineID)
            XCTAssertEqual(manifest.generations.map(\.id), [baselineID])
            XCTAssertTrue(manifest.generations.contains(where: { $0.id == baselineID }))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: VocabRecoveryReplicaManifestStore.storeURL(generationID: baselineID, root: root).path
            ))
        }
    }

    func testLargeReplicaFixtureKeepsMainActorResponsive() async throws {
        try requirePerformanceTests()
        let container = try performanceContainer()
        let worker = await VocabCloudReconciliationWorkerFactory.make(modelContainer: container)

        for run in 1...3 {
            let heartbeat = MainActorHeartbeat()
            let heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    heartbeat.tick()
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            let started = ContinuousClock.now
            _ = try await worker.reconcileFullCooperatively(syncMode: .cloudKitPrivate)
            let elapsed = started.duration(to: .now)
            heartbeatTask.cancel()
            await Task.yield()

            print("PERF full_audit_run=\(run) seconds=\(elapsed.secondsValue) p95_ms=\(heartbeat.p95Gap * 1_000) max_ms=\(heartbeat.maximumGap * 1_000)")
            try appendPerformanceEvidence(
                run: run,
                auditSeconds: elapsed.secondsValue,
                p95GapMilliseconds: heartbeat.p95Gap * 1_000,
                maximumGapMilliseconds: heartbeat.maximumGap * 1_000
            )
            XCTAssertLessThanOrEqual(heartbeat.p95Gap, 0.100)
            XCTAssertLessThanOrEqual(heartbeat.maximumGap, 0.100)
        }
    }

    func testRollingRecoveryReplicaProductionPathKeepsMainActorResponsive() async throws {
        try requirePerformanceTests()
        let setupStarted = ContinuousClock.now
        let container = try performanceContainer()
        let evidenceRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: evidenceRoot) }
        let receiptURL = evidenceRoot.appendingPathComponent("audit-receipt.json")
        let startDate = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try writeAuditReceipt(
            container: container,
            root: evidenceRoot,
            now: startDate,
            targetURL: receiptURL
        )
        let setupElapsed = setupStarted.duration(to: .now).secondsValue
        print("PERF rolling_replica_setup seconds=\(setupElapsed)")
        try appendReplicaSetupEvidence(duration: setupElapsed)

        for run in 1...3 {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = VocabRecoveryReplicaService()

            let heartbeat = MainActorHeartbeat()
            let heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    heartbeat.tick()
                    try? await Task.sleep(for: .milliseconds(1))
                }
            }
            let started = ContinuousClock.now
            let result = try await VocabRecoveryReplicaScheduler.refresh(
                service: service,
                modelContainer: container,
                syncMode: .cloudKitPrivate,
                now: startDate.addingTimeInterval(Double(run) * 86_400),
                rootURL: root,
                auditReceiptURL: receiptURL
            )
            let elapsed = started.duration(to: .now)
            heartbeatTask.cancel()
            await Task.yield()

            guard case .published = result else {
                return XCTFail("Run \(run) skipped production replica path: \(result)")
            }
            print("PERF rolling_replica_run=\(run) seconds=\(elapsed.secondsValue) p95_ms=\(heartbeat.p95Gap * 1_000) max_ms=\(heartbeat.maximumGap * 1_000)")
            try appendReplicaPerformanceEvidence(
                run: run,
                duration: elapsed.secondsValue,
                p95: heartbeat.p95Gap * 1_000,
                maximum: heartbeat.maximumGap * 1_000
            )
            XCTAssertLessThanOrEqual(heartbeat.p95Gap, 0.100)
            XCTAssertLessThanOrEqual(heartbeat.maximumGap, 0.100)
        }
    }

    private func sourceContainer(term: String) throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabReplicaSource-\(UUID().uuidString).store")
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: url)
        try populateSourceContainer(container, term: term)
        return container
    }

    private func publishGeneration(
        root: URL,
        term: String
    ) async throws -> VocabRecoveryReplicaManifest.Generation {
        let container = try sourceContainer(term: term)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let receiptURL = try writeAuditReceipt(container: container, root: root, now: now)
        let result = try await VocabRecoveryReplicaService().refreshIfEligible(
            modelContainer: container,
            syncMode: .cloudKitPrivate,
            now: now,
            rootURL: root,
            auditReceiptURL: receiptURL
        )
        guard case .published(let generationID, maintenancePending: false) = result,
              let manifest = try VocabRecoveryReplicaManifestStore.load(root: root),
              let generation = manifest.generations.first(where: { $0.id == generationID }) else {
            throw TestError.failedToPublishGeneration
        }
        return generation
    }

    private func writeLocalStore(url: URL, term: String) throws {
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: url)
        let context = ModelContext(container)
        context.insert(WordRecord(term: term))
        try context.save()
    }

    private func makeApplicationBoundary(storeURL: URL) throws -> VocabApplicationStoreBoundary {
        let reopen = {
            try! VocabExplicitRecoverySwapStore.recoverInterruptedSwapIfNeeded(destination: storeURL)
            return VocabLaunchPlan(
                container: try! VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: storeURL),
                mode: .localOnly,
                connectionError: nil
            )
        }
        return VocabApplicationStoreBoundary(launchPlan: reopen(), reopen: reopen)
    }

    private func systemFileNumber(at url: URL) throws -> UInt64 {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]
        return try XCTUnwrap((value as? NSNumber)?.uint64Value)
    }

    private func terms(in url: URL) throws -> [String] {
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: url)
        return try ModelContext(container).fetch(FetchDescriptor<WordRecord>()).map(\.term).sorted()
    }

    private func populateSourceContainer(_ container: ModelContainer, term: String) throws {
        let context = ModelContext(container)
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
        let metadata = CloudBootstrapRecord(contentFingerprint: "pending")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.expectedWordCount = 1
        metadata.expectedMeaningCount = 1
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
    }

    private func writeAuditReceipt(
        container: ModelContainer,
        root: URL,
        now: Date = .now,
        targetURL: URL? = nil
    ) throws -> URL {
        let context = ModelContext(container)
        var snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        let fingerprint = try snapshot.contentFingerprint()
        let counts = VocabRequiredIDDigest.counts(snapshot: snapshot)
        let metadata = try XCTUnwrap(context.fetch(FetchDescriptor<CloudBootstrapRecord>()).first)
        metadata.contentFingerprint = fingerprint
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.expectedWordCount = counts.words
        metadata.expectedMeaningCount = counts.meanings
        metadata.expectedDailySetCount = counts.dailySets
        metadata.expectedDailySetItemCount = counts.dailySetItems
        metadata.expectedTestSessionCount = counts.testSessions
        metadata.expectedAttemptCount = counts.attempts
        metadata.expectedAnonymousAggregateCount = counts.anonymousAggregates
        metadata.expectedMemoryAidCacheCount = counts.memoryAidCaches
        metadata.expectedTombstoneCount = counts.tombstones
        metadata.lastReconciledAt = now
        metadata.updatedAt = now
        try context.save()
        snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        let receipt = VocabFullAuditReceipt(
            formatVersion: VocabFullAuditReceipt.currentFormatVersion,
            storeIdentity: VocabFullAuditReceipt.storeIdentity(for: container),
            bootstrapUUID: try XCTUnwrap(snapshot.syncMetadata?.bootstrapUUID),
            schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
            reconciliationVersion: VocabFullAuditReceipt.reconciliationVersion,
            importIndexFormatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalFingerprint: try snapshot.contentFingerprint(),
            expectedCounts: VocabRequiredIDDigest.counts(snapshot: snapshot),
            requiredIDDigest: VocabRequiredIDDigest.make(snapshot: snapshot),
            auditedAt: now
        )
        let url = targetURL ?? root.appendingPathComponent("audit-receipt.json")
        try VocabFullAuditReceiptStore.save(receipt, to: url)
        return url
    }

    private func largeSourceContainer(wordCount: Int, attemptCount: Int) throws -> ModelContainer {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabReplicaPerformance-\(UUID().uuidString).store")
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: url)
        let context = ModelContext(container)
        var words: [WordRecord] = []
        words.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            let word = WordRecord(term: "fixture-\(index)")
            for meaningIndex in 0..<3 {
                let meaning = MeaningRecord(text: "뜻-\(index)-\(meaningIndex)")
                meaning.word = word
                word.appendMeaning(meaning)
                context.insert(meaning)
            }
            let state = ReviewStateRecord()
            state.word = word
            word.reviewState = state
            context.insert(word)
            context.insert(state)
            words.append(word)
        }
        try context.save()
        let session = TestSessionRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.review.rawValue,
            seoulDay: "2026-07-17",
            wordIDs: Array(words.prefix(20).map(\.id)),
            wasReduced: false
        )
        context.insert(session)
        for index in 0..<attemptCount {
            let word = words[index % wordCount]
            let attempt = AttemptRecord(
                directionRaw: PracticeDirection.enToKo.rawValue,
                modeRaw: SessionMode.review.rawValue,
                sessionID: session.id,
                questionIndex: index,
                seoulDay: "2026-07-17",
                prompt: word.term,
                submittedAnswer: "뜻",
                automaticJudgementRaw: Judgement.correct.rawValue,
                finalJudgementRaw: Judgement.correct.rawValue,
                matchedMeaningID: word.activeMeanings.first?.id
            )
            attempt.word = word
            word.appendAttempt(attempt)
            context.insert(attempt)
            if index > 0, index.isMultiple(of: 5_000) {
                try context.save()
            }
        }
        let metadata = CloudBootstrapRecord(contentFingerprint: "performance-fixture")
        metadata.schemaVersion = VocabCloudReconciler.metadataSchemaVersion
        metadata.expectedWordCount = wordCount
        metadata.expectedTestSessionCount = 1
        metadata.expectedAttemptCount = attemptCount
        metadata.lastReconciledAt = .now
        context.insert(metadata)
        try context.save()
        return container
    }

    private func performanceContainer() throws -> ModelContainer {
        if let cached = Self.cachedPerformanceContainer { return cached }
        let container = try largeSourceContainer(wordCount: 10_000, attemptCount: 200_000)
        Self.cachedPerformanceContainer = container
        return container
    }

    private func requirePerformanceTests() throws {
        guard Bundle.main.bundlePath.contains("/performance-build/") else {
            throw XCTSkip("Run via script/measure_intake_performance.sh.")
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabRecoveryReplicaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func appendPerformanceEvidence(
        run: Int,
        auditSeconds: TimeInterval,
        p95GapMilliseconds: TimeInterval,
        maximumGapMilliseconds: TimeInterval
    ) throws {
        let url = URL(fileURLWithPath: "/tmp/RUN-20260717-SYNC-REFACTOR-performance.jsonl")
        let line = "{\"run\":\(run),\"auditSeconds\":\(auditSeconds),\"p95GapMilliseconds\":\(p95GapMilliseconds),\"maximumGapMilliseconds\":\(maximumGapMilliseconds)}\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func appendReplicaPerformanceEvidence(
        run: Int,
        duration: TimeInterval,
        p95: TimeInterval,
        maximum: TimeInterval
    ) throws {
        let url = URL(fileURLWithPath: "/tmp/RUN-20260717-SYNC-REFACTOR-replica-performance.jsonl")
        let line = "{\"run\":\(run),\"durationSeconds\":\(duration),\"p95GapMilliseconds\":\(p95),\"maximumGapMilliseconds\":\(maximum)}\n"
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func appendReplicaSetupEvidence(duration: TimeInterval) throws {
        let url = URL(fileURLWithPath: "/tmp/RUN-20260717-SYNC-REFACTOR-replica-performance.jsonl")
        let line = "{\"phase\":\"fixture_setup_and_initial_audit\",\"durationSeconds\":\(duration)}\n"
        try Data(line.utf8).write(to: url, options: .atomic)
    }
}

@MainActor
private final class MainActorHeartbeat {
    private var lastTick = ContinuousClock.now
    private var gaps: [TimeInterval] = []
    private(set) var maximumGap: TimeInterval = 0

    var p95Gap: TimeInterval {
        guard !gaps.isEmpty else { return 0 }
        let sorted = gaps.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return sorted[index]
    }

    func tick() {
        let now = ContinuousClock.now
        let gap = lastTick.duration(to: now).secondsValue
        gaps.append(gap)
        maximumGap = max(maximumGap, gap)
        lastTick = now
    }
}

private extension Duration {
    var secondsValue: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
