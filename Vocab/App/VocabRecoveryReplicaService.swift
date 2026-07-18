#if os(macOS)
import CryptoKit
import Combine
import Foundation
import SQLite3
import SwiftData

struct VocabRecoveryReplicaManifest: Codable, Equatable {
    struct Generation: Codable, Equatable, Identifiable {
        let id: UUID
        let seoulDay: String
        let sourceFingerprint: String
        let schemaVersion: Int
        let counts: VocabEntityCounts
        let requiredIDDigest: String
        let verifiedAt: Date
    }

    var formatVersion = 1
    var currentGenerationID: UUID
    var generations: [Generation]
}

enum VocabRecoveryReplicaManifestStore {
    static func rootURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("Vocab/RecoveryReplica", isDirectory: true)
    }

    static func manifestURL(root: URL) -> URL {
        root.appendingPathComponent("manifest.json")
    }

    static func load(root: URL) throws -> VocabRecoveryReplicaManifest? {
        let url = manifestURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabRecoveryReplicaManifest.self,
            from: Data(contentsOf: url)
        )
    }

    static func save(_ manifest: VocabRecoveryReplicaManifest, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(manifest)
        try data.write(to: manifestURL(root: root), options: .atomic)
    }

    static func storeURL(generationID: UUID, root: URL) -> URL {
        root.appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
            .appendingPathComponent("Vocab.store")
    }

    static func verifiedRecoveryStoreURL(root: URL) throws -> URL? {
        guard let manifest = try load(root: root),
              manifest.generations.contains(where: { $0.id == manifest.currentGenerationID }) else {
            return nil
        }
        let url = storeURL(generationID: manifest.currentGenerationID, root: root)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum VocabRecoveryReplicaResult: Equatable {
    case published(UUID, maintenancePending: Bool)
    case skippedAlreadyPublishedToday
    case skippedUnchanged
    case skippedIneligible
}

enum VocabRecoveryReplicaRefreshTrigger {
    case foregroundActive
    case inactive
    case background

    var permitsAutomaticRefresh: Bool {
        switch self {
        case .foregroundActive:
            false
        case .inactive, .background:
            true
        }
    }
}

enum VocabRecoveryReplicaError: Error, Equatable {
    case verificationMismatch
    case publishedStoreMissing
    case staleAuditReceipt
    case sourceChangedDuringBuild
    case persistentStoreUnavailable
    case onlineBackupFailed(Int32)
    case auditEvidenceIncomplete
    case relationshipIntegrityFailure
    case injected(VocabRecoveryReplicaFailurePoint)
}

enum VocabRecoveryReplicaFailurePoint: CaseIterable, Equatable {
    case export
    case importStore
    case saveStore
    case prePublishVerification
    case publish
    case postPublishVerification
    case manifestWrite
    case pruning
}

actor VocabRecoveryReplicaService {
    static let shared = VocabRecoveryReplicaService(barrier: .shared)
    private var isRunning = false
    private let injectedFailure: VocabRecoveryReplicaFailurePoint?
    private let barrier: VocabSyncWorkBarrier

    init(
        injectedFailure: VocabRecoveryReplicaFailurePoint? = nil,
        barrier: VocabSyncWorkBarrier = VocabSyncWorkBarrier()
    ) {
        self.injectedFailure = injectedFailure
        self.barrier = barrier
    }

    func refreshIfEligible(
        modelContainer: ModelContainer,
        syncMode: VocabSyncMode,
        now: Date = .now,
        rootURL: URL? = nil,
        auditReceiptURL: URL? = nil
    ) async throws -> VocabRecoveryReplicaResult {
        guard syncMode == .cloudKitPrivate, !isRunning,
              let observedRevision = await barrier.beginReplicaObservation() else {
            return .skippedIneligible
        }
        isRunning = true
        defer { isRunning = false }

        let receipt = try VocabFullAuditReceiptStore.load(
            from: try auditReceiptURL ?? VocabFullAuditReceiptStore.defaultURL()
        )
        let root = try rootURL ?? VocabRecoveryReplicaManifestStore.rootURL()
        let manifest = try VocabRecoveryReplicaManifestStore.load(root: root)
        let currentGeneration = manifest?.generations.first { $0.id == manifest?.currentGenerationID }
        let currentGenerationStoreExists = currentGeneration.map {
            FileManager.default.fileExists(
                atPath: VocabRecoveryReplicaManifestStore.storeURL(generationID: $0.id, root: root).path
            )
        } ?? false
        if let fingerprint = receipt?.canonicalFingerprint,
           currentGenerationStoreExists,
           currentGeneration?.sourceFingerprint == fingerprint {
            return .skippedUnchanged
        }
        try cleanupUnreferencedGenerations(root: root, manifest: manifest)
        let day = SeoulCalendar.day(for: now)
        if currentGenerationStoreExists,
           currentGeneration?.seoulDay == day {
            return .skippedAlreadyPublishedToday
        }

        try failIfInjected(.export)
        let worker = await VocabRecoveryReplicaWorkerFactory.make(modelContainer: modelContainer)
        guard let receipt,
              receipt.storeIdentity == VocabFullAuditReceipt.storeIdentity(for: modelContainer),
              receipt.expectedCounts != nil,
              receipt.requiredIDDigest != nil,
              try await worker.sourceIsCovered(by: receipt) else {
            throw VocabRecoveryReplicaError.staleAuditReceipt
        }
        let fingerprint = receipt.canonicalFingerprint

        try cleanupAbandonedStaging(root: root, now: now)
        let generationID = UUID()
        let staging = root.appendingPathComponent("staging-\(generationID.uuidString)", isDirectory: true)
        let stagedStore = staging.appendingPathComponent("Vocab.store")
        let generationsRoot = root.appendingPathComponent("generations", isDirectory: true)
        let publishedDirectory = generationsRoot.appendingPathComponent(generationID.uuidString, isDirectory: true)
        var manifestCommitted = false
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try failIfInjected(.importStore)
            guard let sourceStore = modelContainer.configurations.first?.url,
                  sourceStore.isFileURL,
                  FileManager.default.fileExists(atPath: sourceStore.path) else {
                throw VocabRecoveryReplicaError.persistentStoreUnavailable
            }
            try await VocabSQLiteOnlineBackup.copy(
                source: sourceStore,
                destination: stagedStore
            )
            try failIfInjected(.saveStore)
            try failIfInjected(.prePublishVerification)
            let expected = try await verifyReplica(at: stagedStore, receipt: receipt)

            try FileManager.default.createDirectory(at: generationsRoot, withIntermediateDirectories: true)
            guard await barrier.remainsStable(since: observedRevision) else {
                throw VocabRecoveryReplicaError.sourceChangedDuringBuild
            }
            try failIfInjected(.publish)
            try FileManager.default.moveItem(at: staging, to: publishedDirectory)
            let publishedStore = publishedDirectory.appendingPathComponent("Vocab.store")
            guard FileManager.default.fileExists(atPath: publishedStore.path) else {
                throw VocabRecoveryReplicaError.publishedStoreMissing
            }
            try failIfInjected(.postPublishVerification)
            guard try await verifyReplica(at: publishedStore, receipt: receipt) == expected else {
                throw VocabRecoveryReplicaError.verificationMismatch
            }
            guard await barrier.remainsStable(since: observedRevision) else {
                throw VocabRecoveryReplicaError.sourceChangedDuringBuild
            }

            let generation = VocabRecoveryReplicaManifest.Generation(
                id: generationID,
                seoulDay: day,
                sourceFingerprint: fingerprint,
                schemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                counts: expected.counts,
                requiredIDDigest: expected.requiredIDDigest,
                verifiedAt: now
            )
            var generations = [generation] + (manifest?.generations ?? []).filter { $0.id != generationID }
            let retained = Array(generations.prefix(3))
            let updated = VocabRecoveryReplicaManifest(
                currentGenerationID: generationID,
                generations: retained
            )
            try failIfInjected(.manifestWrite)
            try VocabRecoveryReplicaManifestStore.save(updated, root: root)
            manifestCommitted = true

            var maintenancePending = false
            do {
                try failIfInjected(.pruning)
                generations.removeFirst(min(generations.count, 3))
                for obsolete in generations where obsolete.id != updated.currentGenerationID {
                    try FileManager.default.removeItem(
                        at: VocabRecoveryReplicaManifestStore.storeURL(generationID: obsolete.id, root: root)
                            .deletingLastPathComponent()
                    )
                }
                try cleanupUnreferencedGenerations(root: root, manifest: updated)
            } catch {
                maintenancePending = true
            }
            return .published(generationID, maintenancePending: maintenancePending)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if !manifestCommitted {
                try? FileManager.default.removeItem(at: publishedDirectory)
            }
            throw error
        }
    }

    private func failIfInjected(_ point: VocabRecoveryReplicaFailurePoint) throws {
        if injectedFailure == point { throw VocabRecoveryReplicaError.injected(point) }
    }

    struct Verification: Equatable {
        let fingerprint: String
        let counts: VocabEntityCounts
        let requiredIDDigest: String
    }

    private func cleanupUnreferencedGenerations(
        root: URL,
        manifest: VocabRecoveryReplicaManifest?
    ) throws {
        let generationsRoot = root.appendingPathComponent("generations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: generationsRoot.path) else { return }
        let referenced = Set((manifest?.generations ?? []).map { $0.id.uuidString })
        for directory in try FileManager.default.contentsOfDirectory(
            at: generationsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) where !referenced.contains(directory.lastPathComponent) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func verifyReplica(
        at storeURL: URL,
        receipt: VocabFullAuditReceipt
    ) async throws -> Verification {
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: storeURL)
        let worker = await VocabRecoveryReplicaWorkerFactory.make(modelContainer: container)
        return try await worker.verify(receipt: receipt)
    }

    private func cleanupAbandonedStaging(root: URL, now: Date) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) where url.lastPathComponent.hasPrefix("staging-") {
            let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

enum VocabRecoveryReplicaScheduler {
    static let automaticRefreshEnabled = true

    static func automaticRefreshIsEligible(
        trigger: VocabRecoveryReplicaRefreshTrigger,
        syncMode: VocabSyncMode,
        hydrationState: VocabHydrationState,
        localContentIsUsable: Bool,
        hasRunningTask: Bool
    ) -> Bool {
        automaticRefreshEnabled
            && trigger.permitsAutomaticRefresh
            && !hasRunningTask
            && syncMode == .cloudKitPrivate
            && localContentIsUsable
            && hydrationState == .ready
    }

    static func refresh(
        service: VocabRecoveryReplicaService = .shared,
        modelContainer: ModelContainer,
        syncMode: VocabSyncMode,
        now: Date = .now,
        rootURL: URL? = nil,
        auditReceiptURL: URL? = nil
    ) async throws -> VocabRecoveryReplicaResult {
        try Task.checkCancellation()
        return try await service.refreshIfEligible(
            modelContainer: modelContainer,
            syncMode: syncMode,
            now: now,
            rootURL: rootURL,
            auditReceiptURL: auditReceiptURL
        )
    }
}

struct VocabExplicitRecoveryRequest: Equatable, Sendable {
    let generationID: UUID
}

struct VocabClosedStoreRecoveryCapability: Sendable {
    fileprivate let id: UUID
}

private actor VocabClosedStoreRecoveryCapabilityRegistry {
    static let shared = VocabClosedStoreRecoveryCapabilityRegistry()
    private var available = Set<UUID>()

    func issue() -> VocabClosedStoreRecoveryCapability {
        let id = UUID()
        available.insert(id)
        return VocabClosedStoreRecoveryCapability(id: id)
    }

    func consume(_ capability: VocabClosedStoreRecoveryCapability) -> Bool {
        available.remove(capability.id) != nil
    }
}

struct VocabExplicitRecoveryResult: Equatable {
    let generationID: UUID
    let checkpointStoreURL: URL
    let restoredStoreURL: URL
}

enum VocabExplicitRecoveryError: Error, Equatable {
    case userConfirmationRequired
    case applicationStoreMustBeClosed
    case invalidClosedStoreCapability
    case generationNotFound
    case generationValidationFailed
    case existingStoreMissing
    case checkpointValidationFailed
    case destinationValidationFailed
    case interruptedSwapRecoveryFailed
    case injected(VocabExplicitRecoveryFailurePoint)
}

enum VocabExplicitRecoveryFailurePoint: Equatable {
    case afterCheckpoint
    case afterStagingValidation
    case afterSwapPrepared
    case afterAtomicSwap
    case afterDestinationValidation
}

fileprivate struct VocabExplicitRecoverySwapManifest: Codable, Equatable {
    enum Phase: String, Codable {
        case prepared
        case replacementInstalled
        case committed
    }

    let formatVersion: Int
    let operationID: UUID
    let generationID: UUID
    let destinationPath: String
    let replacementPath: String
    let originalBackupPath: String
    let rollbackReplacementPath: String
    let checkpointDirectoryPath: String
    var phase: Phase
}

enum VocabExplicitRecoverySwapStore {
    static func manifestURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".VocabExplicitRecoverySwap.json")
    }

    static func recoverInterruptedSwapIfNeeded(destination: URL) throws {
        let journalURL = manifestURL(for: destination)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let manifest = try JSONDecoder.vocabSnapshotDecoder.decode(
            VocabExplicitRecoverySwapManifest.self,
            from: Data(contentsOf: journalURL)
        )
        guard manifest.formatVersion == 1,
              manifest.destinationPath == destination.path else {
            throw VocabExplicitRecoveryError.interruptedSwapRecoveryFailed
        }

        let replacement = URL(fileURLWithPath: manifest.replacementPath)
        let originalBackup = URL(fileURLWithPath: manifest.originalBackupPath)
        let rollbackReplacement = URL(fileURLWithPath: manifest.rollbackReplacementPath)
        let checkpointDirectory = URL(fileURLWithPath: manifest.checkpointDirectoryPath)
        switch manifest.phase {
        case .committed:
            try? FileManager.default.removeItem(at: originalBackup)
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: rollbackReplacement)
        case .prepared, .replacementInstalled:
            if FileManager.default.fileExists(atPath: originalBackup.path) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destination,
                        withItemAt: originalBackup,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: originalBackup, to: destination)
                }
            } else if !FileManager.default.fileExists(atPath: replacement.path) {
                guard FileManager.default.fileExists(atPath: rollbackReplacement.path) else {
                    throw VocabExplicitRecoveryError.interruptedSwapRecoveryFailed
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destination,
                        withItemAt: rollbackReplacement,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: rollbackReplacement, to: destination)
                }
            }
            try restorePreservedSidecars(from: checkpointDirectory, to: destination)
            try? FileManager.default.removeItem(at: replacement)
            try? FileManager.default.removeItem(at: rollbackReplacement)
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    fileprivate static func save(_ manifest: VocabExplicitRecoverySwapManifest, destination: URL) throws {
        let url = manifestURL(for: destination)
        try JSONEncoder.vocabSnapshotEncoder.encode(manifest).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    static func preserveSidecars(of destination: URL, in checkpointDirectory: URL) throws {
        for sidecar in sidecarURLs(for: destination) where FileManager.default.fileExists(atPath: sidecar.path) {
            let preserved = checkpointDirectory.appendingPathComponent("preserved-\(sidecar.lastPathComponent)")
            try FileManager.default.moveItem(at: sidecar, to: preserved)
        }
    }

    static func removeSidecars(of store: URL) {
        for sidecar in sidecarURLs(for: store) {
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    private static func restorePreservedSidecars(from checkpointDirectory: URL, to destination: URL) throws {
        removeSidecars(of: destination)
        for sidecar in sidecarURLs(for: destination) {
            let preserved = checkpointDirectory.appendingPathComponent("preserved-\(sidecar.lastPathComponent)")
            if FileManager.default.fileExists(atPath: preserved.path) {
                try FileManager.default.moveItem(at: preserved, to: sidecar)
            }
        }
    }

    private static func sidecarURLs(for store: URL) -> [URL] {
        ["-wal", "-shm"].map {
            store.deletingLastPathComponent().appendingPathComponent(store.lastPathComponent + $0)
        }
    }
}

actor VocabExplicitRecoveryService {
    private let injectedFailure: VocabExplicitRecoveryFailurePoint?

    init(injectedFailure: VocabExplicitRecoveryFailurePoint? = nil) {
        self.injectedFailure = injectedFailure
    }

    func restore(
        request: VocabExplicitRecoveryRequest,
        capability: VocabClosedStoreRecoveryCapability,
        recoveryRoot: URL? = nil,
        localStoreURL: URL? = nil,
        checkpointRoot: URL? = nil,
        now: Date = .now
    ) async throws -> VocabExplicitRecoveryResult {
        guard await VocabClosedStoreRecoveryCapabilityRegistry.shared.consume(capability) else {
            throw VocabExplicitRecoveryError.invalidClosedStoreCapability
        }
        let root = try recoveryRoot ?? VocabRecoveryReplicaManifestStore.rootURL()
        guard let manifest = try VocabRecoveryReplicaManifestStore.load(root: root),
              let generation = manifest.generations.first(where: { $0.id == request.generationID }) else {
            throw VocabExplicitRecoveryError.generationNotFound
        }
        let generationStore = VocabRecoveryReplicaManifestStore.storeURL(
            generationID: generation.id,
            root: root
        )
        guard FileManager.default.fileExists(atPath: generationStore.path),
              try await validates(storeURL: generationStore, generation: generation) else {
            throw VocabExplicitRecoveryError.generationValidationFailed
        }

        let destination = try localStoreURL ?? VocabModelContainerFactory.localStoreURL()
        try VocabExplicitRecoverySwapStore.recoverInterruptedSwapIfNeeded(destination: destination)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw VocabExplicitRecoveryError.existingStoreMissing
        }
        let checkpointBase = try checkpointRoot ?? defaultCheckpointRoot()
        let operationID = UUID()
        let checkpointDirectory = checkpointBase.appendingPathComponent(
            "ExplicitRecovery-\(Self.timestamp(now))-\(operationID.uuidString)",
            isDirectory: true
        )
        let checkpointStore = checkpointDirectory.appendingPathComponent("Vocab.store")
        try await VocabSQLiteOnlineBackup.copy(source: destination, destination: checkpointStore)
        guard canOpenLocalStore(at: checkpointStore) else {
            throw VocabExplicitRecoveryError.checkpointValidationFailed
        }
        try writeCheckpointManifest(
            directory: checkpointDirectory,
            generation: generation,
            originalStoreURL: destination,
            now: now
        )
        try failIfInjected(.afterCheckpoint)

        let stagingDirectory = checkpointBase.appendingPathComponent(
            "ExplicitRecoveryStaging-\(operationID.uuidString)",
            isDirectory: true
        )
        let stagingStore = stagingDirectory.appendingPathComponent("Vocab.store")
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        try await VocabSQLiteOnlineBackup.copy(source: generationStore, destination: stagingStore)
        guard try await validates(storeURL: stagingStore, generation: generation) else {
            throw VocabExplicitRecoveryError.generationValidationFailed
        }
        try failIfInjected(.afterStagingValidation)
        VocabExplicitRecoverySwapStore.removeSidecars(of: stagingStore)

        let replacement = destination.deletingLastPathComponent().appendingPathComponent(
            ".VocabExplicitRecoveryReplacement-\(operationID.uuidString).store"
        )
        let originalBackup = destination.deletingLastPathComponent().appendingPathComponent(
            ".VocabExplicitRecoveryOriginal-\(operationID.uuidString).store"
        )
        let rollbackReplacement = destination.deletingLastPathComponent().appendingPathComponent(
            ".VocabExplicitRecoveryRollback-\(operationID.uuidString).store"
        )
        var swapJournalPublished = false
        defer {
            if !swapJournalPublished {
                try? FileManager.default.removeItem(at: replacement)
                try? FileManager.default.removeItem(at: rollbackReplacement)
            }
        }
        if FileManager.default.fileExists(atPath: replacement.path) {
            try FileManager.default.removeItem(at: replacement)
        }
        try FileManager.default.moveItem(at: stagingStore, to: replacement)
        try await VocabSQLiteOnlineBackup.copy(source: checkpointStore, destination: rollbackReplacement)
        guard canOpenLocalStore(at: rollbackReplacement) else {
            throw VocabExplicitRecoveryError.checkpointValidationFailed
        }
        VocabExplicitRecoverySwapStore.removeSidecars(of: rollbackReplacement)
        var swapManifest = VocabExplicitRecoverySwapManifest(
            formatVersion: 1,
            operationID: operationID,
            generationID: generation.id,
            destinationPath: destination.path,
            replacementPath: replacement.path,
            originalBackupPath: originalBackup.path,
            rollbackReplacementPath: rollbackReplacement.path,
            checkpointDirectoryPath: checkpointDirectory.path,
            phase: .prepared
        )
        try VocabExplicitRecoverySwapStore.save(swapManifest, destination: destination)
        swapJournalPublished = true
        try failIfInjected(.afterSwapPrepared)

        try VocabExplicitRecoverySwapStore.preserveSidecars(of: destination, in: checkpointDirectory)
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: replacement,
            backupItemName: originalBackup.lastPathComponent,
            options: []
        )
        try failIfInjected(.afterAtomicSwap)
        swapManifest.phase = .replacementInstalled
        try VocabExplicitRecoverySwapStore.save(swapManifest, destination: destination)
        guard try await validates(storeURL: destination, generation: generation) else {
            throw VocabExplicitRecoveryError.destinationValidationFailed
        }
        try failIfInjected(.afterDestinationValidation)
        swapManifest.phase = .committed
        try VocabExplicitRecoverySwapStore.save(swapManifest, destination: destination)
        try VocabExplicitRecoverySwapStore.recoverInterruptedSwapIfNeeded(destination: destination)
        return VocabExplicitRecoveryResult(
            generationID: generation.id,
            checkpointStoreURL: checkpointStore,
            restoredStoreURL: destination
        )
    }

    private func validates(
        storeURL: URL,
        generation: VocabRecoveryReplicaManifest.Generation
    ) async throws -> Bool {
        let container = try VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: storeURL)
        let worker = await VocabRecoveryReplicaWorkerFactory.make(modelContainer: container)
        return try await worker.verify(generation: generation) != nil
    }

    private func canOpenLocalStore(at url: URL) -> Bool {
        (try? VocabModelContainerFactory.makeContainer(syncMode: .localOnly, storeURL: url)) != nil
    }

    private func failIfInjected(_ point: VocabExplicitRecoveryFailurePoint) throws {
        if injectedFailure == point { throw VocabExplicitRecoveryError.injected(point) }
    }

    private func defaultCheckpointRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/ExplicitRecoveryCheckpoints", isDirectory: true)
    }

    private func writeCheckpointManifest(
        directory: URL,
        generation: VocabRecoveryReplicaManifest.Generation,
        originalStoreURL: URL,
        now: Date
    ) throws {
        struct Manifest: Codable {
            let formatVersion: Int
            let generationID: UUID
            let generationFingerprint: String
            let originalStorePath: String
            let createdAt: Date
        }
        let manifest = Manifest(
            formatVersion: 1,
            generationID: generation.id,
            generationFingerprint: generation.sourceFingerprint,
            originalStorePath: originalStoreURL.path,
            createdAt: now
        )
        try JSONEncoder.vocabSnapshotEncoder.encode(manifest).write(
            to: directory.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

@MainActor
final class VocabApplicationStoreBoundary: ObservableObject {
    @Published private(set) var launch: VocabLaunchPlan?
    private let reopen: () -> VocabLaunchPlan

    convenience init() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let reopen = {
                VocabLaunchPlan(
                    container: try! VocabModelContainerFactory.makeInMemoryContainer(),
                    mode: .localOnly,
                    connectionError: nil
                )
            }
            self.init(launchPlan: reopen(), reopen: reopen)
            return
        }

        let preferredMode = VocabSyncMode.current(allowsCloudKit: true)
        if preferredMode == .cloudKitPrivate {
            VocabMutationAuthorityRuntime.beginValidationEpoch()
        }
        let interruptedRecoveryError: Error?
        do {
            try VocabExplicitRecoverySwapStore.recoverInterruptedSwapIfNeeded(
                destination: VocabModelContainerFactory.localStoreURL()
            )
            interruptedRecoveryError = nil
        } catch {
            interruptedRecoveryError = error
        }
        let reopen = {
            VocabModelContainerFactory.makeLaunchPlan(preferredMode: preferredMode) { mode in
                if let interruptedRecoveryError { throw interruptedRecoveryError }
                return try VocabModelContainerFactory.makeContainer(syncMode: mode)
            }
        }
        self.init(launchPlan: reopen(), reopen: reopen)
    }

    init(launchPlan: VocabLaunchPlan, reopen: @escaping () -> VocabLaunchPlan) {
        launch = launchPlan
        self.reopen = reopen
    }

    func performConfirmedRecovery(
        request: VocabExplicitRecoveryRequest,
        userConfirmed: Bool,
        service: VocabExplicitRecoveryService = VocabExplicitRecoveryService(),
        recoveryRoot: URL? = nil,
        localStoreURL: URL? = nil,
        checkpointRoot: URL? = nil,
        now: Date = .now
    ) async throws -> VocabExplicitRecoveryResult {
        guard userConfirmed else { throw VocabExplicitRecoveryError.userConfirmationRequired }
        guard launch != nil else { throw VocabExplicitRecoveryError.applicationStoreMustBeClosed }
        let destination = try localStoreURL ?? VocabModelContainerFactory.localStoreURL()

        // Removing the sole application-owned plan first removes both SwiftUI container injections.
        launch = nil
        await Task.yield()
        await Task.yield()
        let capability = await VocabClosedStoreRecoveryCapabilityRegistry.shared.issue()
        do {
            let result = try await service.restore(
                request: request,
                capability: capability,
                recoveryRoot: recoveryRoot,
                localStoreURL: destination,
                checkpointRoot: checkpointRoot,
                now: now
            )
            launch = reopen()
            return result
        } catch {
            do {
                try VocabExplicitRecoverySwapStore.recoverInterruptedSwapIfNeeded(destination: destination)
            } catch {
                launch = nil
                throw VocabExplicitRecoveryError.interruptedSwapRecoveryFailed
            }
            launch = reopen()
            throw error
        }
    }
}

enum VocabSQLiteOnlineBackup {
    static func copy(source: URL, destination: URL, pagesPerStep: Int32 = 64) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            source.path,
            &sourceDB,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let sourceDB else {
            if let sourceDB { sqlite3_close_v2(sourceDB) }
            throw VocabRecoveryReplicaError.onlineBackupFailed(sourceResult)
        }
        defer { sqlite3_close_v2(sourceDB) }
        let destinationResult = sqlite3_open_v2(
            destination.path,
            &destinationDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destinationDB else {
            if let destinationDB { sqlite3_close_v2(destinationDB) }
            throw VocabRecoveryReplicaError.onlineBackupFailed(destinationResult)
        }
        defer { sqlite3_close_v2(destinationDB) }
        sqlite3_busy_timeout(sourceDB, 250)
        sqlite3_busy_timeout(destinationDB, 250)
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw VocabRecoveryReplicaError.onlineBackupFailed(sqlite3_errcode(destinationDB))
        }
        var backupFinished = false
        defer {
            if !backupFinished { sqlite3_backup_finish(backup) }
        }
        var busyRetries = 0
        while true {
            try Task.checkCancellation()
            let finalResult = sqlite3_backup_step(backup, pagesPerStep)
            switch finalResult {
            case SQLITE_DONE:
                let finishResult = sqlite3_backup_finish(backup)
                backupFinished = true
                guard finishResult == SQLITE_OK else {
                    throw VocabRecoveryReplicaError.onlineBackupFailed(finishResult)
                }
                return
            case SQLITE_OK:
                busyRetries = 0
                try await Task.sleep(for: .milliseconds(1))
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyRetries += 1
                guard busyRetries <= 100 else {
                    throw VocabRecoveryReplicaError.onlineBackupFailed(finalResult)
                }
                try await Task.sleep(for: .milliseconds(5))
            default:
                throw VocabRecoveryReplicaError.onlineBackupFailed(finalResult)
            }
        }
    }
}

@ModelActor
actor VocabRecoveryReplicaWorker {
    private let batchSize = 500

    func sourceIsCovered(by receipt: VocabFullAuditReceipt) async throws -> Bool {
        var metadataDescriptor = FetchDescriptor<CloudBootstrapRecord>(
            predicate: #Predicate { $0.key == "primary" && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.id)]
        )
        metadataDescriptor.fetchLimit = 1
        guard let metadata = try modelContext.fetch(metadataDescriptor).first else { return false }
        let latestRecordUpdate = try latestRecordUpdateAt()
        return receipt.formatVersion == VocabFullAuditReceipt.currentFormatVersion
            && receipt.schemaVersion == VocabCloudReconciler.metadataSchemaVersion
            && receipt.reconciliationVersion == VocabFullAuditReceipt.reconciliationVersion
            && receipt.importIndexFormatVersion == VocabImportedChangeIndex.currentFormatVersion
            && receipt.bootstrapUUID == metadata.bootstrapUUID
            && receipt.canonicalFingerprint == metadata.contentFingerprint
            && metadata.lastReconciledAt != nil
            && metadata.lastReconciledAt! >= receipt.auditedAt
            && latestRecordUpdate <= receipt.auditedAt
    }

    private func latestRecordUpdateAt() throws -> Date {
        let dates: [Date?] = [
            try latestUpdate(WordRecord.self, keyPath: \.updatedAt),
            try latestUpdate(MeaningRecord.self, keyPath: \.updatedAt),
            try latestUpdate(DailySetRecord.self, keyPath: \.updatedAt),
            try latestUpdate(DailySetItemRecord.self, keyPath: \.updatedAt),
            try latestUpdate(TestSessionRecord.self, keyPath: \.updatedAt),
            try latestUpdate(AttemptRecord.self, keyPath: \.updatedAt),
            try latestUpdate(ReviewStateRecord.self, keyPath: \.updatedAt),
            try latestUpdate(AnonymousAggregateRecord.self, keyPath: \.updatedAt),
            try latestUpdate(MemoryAidCacheRecord.self, keyPath: \.updatedAt),
            try latestUpdate(RecordTombstone.self, keyPath: \.updatedAt)
        ]
        return dates.compactMap { $0 }.max() ?? .distantPast
    }

    private func latestUpdate<Record: PersistentModel>(
        _ type: Record.Type,
        keyPath: KeyPath<Record, Date>
    ) throws -> Date? {
        var descriptor = FetchDescriptor<Record>(
            sortBy: [SortDescriptor(keyPath, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?[keyPath: keyPath]
    }

    func verify(receipt: VocabFullAuditReceipt) async throws -> VocabRecoveryReplicaService.Verification {
        guard let expectedCounts = receipt.expectedCounts,
              let expectedDigest = receipt.requiredIDDigest,
              try await sourceIsCovered(by: receipt) else {
            throw VocabRecoveryReplicaError.auditEvidenceIncomplete
        }
        let counts = try VocabCloudReconciler.counts(context: modelContext)
        guard counts == expectedCounts else { throw VocabRecoveryReplicaError.verificationMismatch }
        try await verifyRelationships()
        let digest = try await requiredIDDigest()
        guard digest == expectedDigest else { throw VocabRecoveryReplicaError.verificationMismatch }
        return VocabRecoveryReplicaService.Verification(
            fingerprint: receipt.canonicalFingerprint,
            counts: counts,
            requiredIDDigest: digest
        )
    }

    func verify(
        generation: VocabRecoveryReplicaManifest.Generation
    ) async throws -> VocabRecoveryReplicaService.Verification? {
        var descriptor = FetchDescriptor<CloudBootstrapRecord>(predicate: #Predicate {
            $0.key == "primary" && $0.deletedAt == nil
        })
        descriptor.fetchLimit = 1
        guard let metadata = try modelContext.fetch(descriptor).first,
              metadata.schemaVersion == generation.schemaVersion,
              metadata.contentFingerprint == generation.sourceFingerprint else { return nil }
        let counts = try VocabCloudReconciler.counts(context: modelContext)
        guard counts == generation.counts else { return nil }
        try await verifyRelationships()
        let digest = try await requiredIDDigest()
        guard digest == generation.requiredIDDigest else { return nil }
        return VocabRecoveryReplicaService.Verification(
            fingerprint: metadata.contentFingerprint,
            counts: counts,
            requiredIDDigest: digest
        )
    }

    private func requiredIDDigest() async throws -> String {
        var hasher = SHA256()
        var isFirst = true
        try await appendIDs(AttemptRecord.self, prefix: "a:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(RecordTombstone.self, prefix: "d:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(DailySetItemRecord.self, prefix: "i:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(MeaningRecord.self, prefix: "m:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(DailySetRecord.self, prefix: "s:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(TestSessionRecord.self, prefix: "t:", hasher: &hasher, isFirst: &isFirst)
        try await appendIDs(WordRecord.self, prefix: "w:", hasher: &hasher, isFirst: &isFirst)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func appendIDs<Record: PersistentModel & VocabStableIdentifiedRecord>(
        _ type: Record.Type,
        prefix: String,
        hasher: inout SHA256,
        isFirst: inout Bool
    ) async throws {
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Record>(sortBy: [SortDescriptor(\Record.id)])
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { return }
            for record in batch {
                if !isFirst { hasher.update(data: Data("|".utf8)) }
                hasher.update(data: Data("\(prefix)\(record.id.uuidString)".utf8))
                isFirst = false
            }
            offset += batch.count
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    private func verifyRelationships() async throws {
        let wordIDs = Set(try modelContext.fetch(FetchDescriptor<WordRecord>()).map(\.id))
        let meaningIDs = Set(try modelContext.fetch(FetchDescriptor<MeaningRecord>()).map(\.id))
        let sessionIDs = Set(try modelContext.fetch(FetchDescriptor<TestSessionRecord>()).map(\.id))
        try await inspect(MeaningRecord.self) { $0.word.map { wordIDs.contains($0.id) } == true }
        try await inspect(DailySetItemRecord.self) { wordIDs.contains($0.wordID) }
        try await inspect(TestSessionRecord.self) { $0.wordIDs.allSatisfy(wordIDs.contains) }
        try await inspect(AttemptRecord.self) { attempt in
            sessionIDs.contains(attempt.sessionID)
                && (attempt.word == nil || wordIDs.contains(attempt.word!.id))
                && (attempt.matchedMeaningID == nil || meaningIDs.contains(attempt.matchedMeaningID!))
        }
        try await inspect(MemoryAidCacheRecord.self) { wordIDs.contains($0.wordID) }
    }

    private func inspect<Record: PersistentModel & VocabStableIdentifiedRecord>(
        _ type: Record.Type,
        predicate: (Record) -> Bool
    ) async throws {
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<Record>(sortBy: [SortDescriptor(\Record.id)])
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = offset
            let batch = try modelContext.fetch(descriptor)
            guard !batch.isEmpty else { return }
            guard batch.allSatisfy(predicate) else { throw VocabRecoveryReplicaError.relationshipIntegrityFailure }
            offset += batch.count
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

enum VocabRecoveryReplicaWorkerFactory {
    static func make(modelContainer: ModelContainer) async -> VocabRecoveryReplicaWorker {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: VocabRecoveryReplicaWorker(modelContainer: modelContainer))
            }
        }
    }
}
#endif
