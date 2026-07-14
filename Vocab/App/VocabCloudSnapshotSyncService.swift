import CloudKit
import Foundation
import SwiftData

protocol VocabCloudSnapshotStoring {
    func save(_ snapshot: VocabSyncSnapshot) async throws
    func save(
        _ snapshot: VocabSyncSnapshot,
        ifCloudMetadataMatches expectedMetadata: VocabCloudSnapshotMetadata?
    ) async throws -> Bool
    func load() async throws -> VocabSyncSnapshot?
    func metadata() async throws -> VocabCloudSnapshotMetadata?
}

extension VocabCloudSnapshotStoring {
    func metadata() async throws -> VocabCloudSnapshotMetadata? {
        guard let snapshot = try await load() else { return nil }
        return try VocabCloudSnapshotMetadata(snapshot: snapshot)
    }
}

struct VocabCloudSnapshotSyncResult: Equatable {
    let wordCount: Int
    let dailySetCount: Int
    let exportedAt: Date
    let checkpointDirectoryName: String?

    init(snapshot: VocabSyncSnapshot, checkpoint: VocabLocalStoreCheckpoint? = nil) {
        self.wordCount = snapshot.words.count
        self.dailySetCount = snapshot.dailySets.count
        self.exportedAt = snapshot.exportedAt
        self.checkpointDirectoryName = checkpoint?.directory.lastPathComponent
    }

    init(metadata: VocabCloudSnapshotMetadata) {
        self.wordCount = metadata.wordCount
        self.dailySetCount = metadata.dailySetCount
        self.exportedAt = metadata.exportedAt
        self.checkpointDirectoryName = nil
    }
}

struct VocabCloudSnapshotMetadata: Codable, Equatable {
    let formatVersion: Int
    let exportedAt: Date
    let wordCount: Int
    let dailySetCount: Int
    let fingerprint: String

    init(snapshot: VocabSyncSnapshot) throws {
        self.formatVersion = snapshot.formatVersion
        self.exportedAt = snapshot.exportedAt
        self.wordCount = snapshot.words.count
        self.dailySetCount = snapshot.dailySets.count
        self.fingerprint = try snapshot.contentFingerprint()
    }
}

struct VocabCloudBatchSyncCursor: Codable, Equatable {
    let snapshotFingerprint: String
    let cloudExportedAt: Date
    let syncedAt: Date
}

protocol VocabCloudBatchSyncStateStoring {
    func loadCursor() -> VocabCloudBatchSyncCursor?
    func saveCursor(_ cursor: VocabCloudBatchSyncCursor)
}

struct VocabCloudBatchSyncUserDefaultsStore: VocabCloudBatchSyncStateStoring {
    private static let cursorKey = "vocabCloudBatchSyncCursor"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadCursor() -> VocabCloudBatchSyncCursor? {
        guard let data = defaults.data(forKey: Self.cursorKey) else { return nil }
        return try? JSONDecoder.vocabSnapshotDecoder.decode(VocabCloudBatchSyncCursor.self, from: data)
    }

    func saveCursor(_ cursor: VocabCloudBatchSyncCursor) {
        guard let data = try? JSONEncoder.vocabSnapshotEncoder.encode(cursor) else { return }
        defaults.set(data, forKey: Self.cursorKey)
    }
}

enum VocabCloudBatchSyncAction: Equatable {
    case uploadLocalSnapshot
    case downloadCloudSnapshot
    case alreadyInSync
    case blocked
    case conflict
}

struct VocabCloudBatchSyncPlan: Equatable {
    let action: VocabCloudBatchSyncAction
    let local: VocabCloudSnapshotMetadata
    let cloud: VocabCloudSnapshotMetadata?
    let cursor: VocabCloudBatchSyncCursor?
}

struct VocabCloudBatchSyncResult: Equatable {
    let action: VocabCloudBatchSyncAction
    let local: VocabCloudSnapshotMetadata
    let cloud: VocabCloudSnapshotMetadata?
    let snapshotResult: VocabCloudSnapshotSyncResult?
}

enum VocabCloudBatchSyncError: LocalizedError {
    case localCheckpointFailed
    case localCheckpointRestoreFailed

    var errorDescription: String? {
        switch self {
        case .localCheckpointFailed:
            return "로컬 단어장 보호 사본을 만들지 못해 iCloud 가져오기/자동 다운로드를 중단했습니다."
        case .localCheckpointRestoreFailed:
            return "iCloud 자동 다운로드가 실패했고 로컬 보호 사본 복원도 완료하지 못했습니다. 자동 동기화를 중단했습니다."
        }
    }
}

@MainActor
struct VocabCloudSnapshotSyncService {
    typealias LocalStoreCheckpointCreator = @MainActor (_ now: Date) throws -> VocabLocalStoreCheckpoint

    private let store: VocabCloudSnapshotStoring
    private let stateStore: VocabCloudBatchSyncStateStoring
    private let localStoreCheckpointCreator: LocalStoreCheckpointCreator?

    init(
        store: VocabCloudSnapshotStoring = VocabCloudKitSnapshotStore(),
        stateStore: VocabCloudBatchSyncStateStoring = VocabCloudBatchSyncUserDefaultsStore(),
        localStoreCheckpointCreator: LocalStoreCheckpointCreator? = nil
    ) {
        self.store = store
        self.stateStore = stateStore
        self.localStoreCheckpointCreator = localStoreCheckpointCreator
    }

    func uploadLocalSnapshot(context: ModelContext, now: Date = .now) async throws -> VocabCloudSnapshotSyncResult {
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        try await store.save(snapshot)
        try recordSyncedSnapshot(snapshot, syncedAt: now)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot)
    }

    func replaceLocalStoreFromCloud(context: ModelContext, syncedAt: Date = .now) async throws -> VocabCloudSnapshotSyncResult? {
        guard let snapshot = try await store.load() else { return nil }
        let checkpoint = try createLocalStoreCheckpointIfNeeded(now: syncedAt)
        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: context, syncMode: .localOnly)
        try recordSyncedSnapshot(snapshot, syncedAt: syncedAt)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot, checkpoint: checkpoint)
    }

    func inspectCloudSnapshot() async throws -> VocabCloudSnapshotSyncResult? {
        guard let snapshot = try await store.load() else { return nil }
        try VocabSyncSnapshotService.validate(snapshot)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot)
    }

    func planBatchSync(context: ModelContext, now: Date = .now) async throws -> VocabCloudBatchSyncPlan {
        let localSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        let local = try VocabCloudSnapshotMetadata(snapshot: localSnapshot)
        let cloud = try await store.metadata()
        let cursor = stateStore.loadCursor()

        return VocabCloudBatchSyncPlan(
            action: action(local: local, cloud: cloud, cursor: cursor),
            local: local,
            cloud: cloud,
            cursor: cursor
        )
    }

    func runBatchSyncIfReady(
        context: ModelContext,
        readiness: VocabCloudSyncReadiness,
        now: Date = .now
    ) async throws -> VocabCloudBatchSyncResult {
        guard readiness.isReadyForBatchSync else {
            let plan = try await planBatchSync(context: context, now: now)
            return VocabCloudBatchSyncResult(
                action: .blocked,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: nil
            )
        }

        let plan = try await planBatchSync(context: context, now: now)
        return try await applyBatchSyncPlan(plan, context: context, now: now)
    }

    func applyBatchSyncPlan(
        _ plan: VocabCloudBatchSyncPlan,
        context: ModelContext,
        now: Date = .now
    ) async throws -> VocabCloudBatchSyncResult {
        switch plan.action {
        case .uploadLocalSnapshot:
            guard let result = try await uploadLocalSnapshotIfCloudUnchanged(
                context: context,
                plan: plan,
                now: now
            ) else {
                return VocabCloudBatchSyncResult(
                    action: .conflict,
                    local: plan.local,
                    cloud: try await store.metadata(),
                    snapshotResult: nil
                )
            }
            return VocabCloudBatchSyncResult(
                action: .uploadLocalSnapshot,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: result
            )
        case .downloadCloudSnapshot:
            guard let result = try await replaceLocalStoreFromCloudIfLocalUnchanged(
                context: context,
                plan: plan,
                syncedAt: now
            ) else {
                return VocabCloudBatchSyncResult(
                    action: .conflict,
                    local: try currentLocalMetadata(context: context, now: now),
                    cloud: plan.cloud,
                    snapshotResult: nil
                )
            }
            return VocabCloudBatchSyncResult(
                action: .downloadCloudSnapshot,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: result
            )
        case .alreadyInSync:
            if let cloud = plan.cloud {
                stateStore.saveCursor(
                    VocabCloudBatchSyncCursor(
                        snapshotFingerprint: cloud.fingerprint,
                        cloudExportedAt: cloud.exportedAt,
                        syncedAt: now
                    )
                )
            }
            return VocabCloudBatchSyncResult(
                action: .alreadyInSync,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: nil
            )
        case .blocked:
            return VocabCloudBatchSyncResult(
                action: .blocked,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: nil
            )
        case .conflict:
            return VocabCloudBatchSyncResult(
                action: .conflict,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: nil
            )
        }
    }

    private func uploadLocalSnapshotIfCloudUnchanged(
        context: ModelContext,
        plan: VocabCloudBatchSyncPlan,
        now: Date
    ) async throws -> VocabCloudSnapshotSyncResult? {
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        let didSave = try await store.save(snapshot, ifCloudMetadataMatches: plan.cloud)
        guard didSave else { return nil }
        try recordSyncedSnapshot(snapshot, syncedAt: now)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot)
    }

    private func replaceLocalStoreFromCloudIfLocalUnchanged(
        context: ModelContext,
        plan: VocabCloudBatchSyncPlan,
        syncedAt: Date
    ) async throws -> VocabCloudSnapshotSyncResult? {
        let localCheckpoint: VocabSyncSnapshot
        do {
            localCheckpoint = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: syncedAt)
        } catch {
            throw VocabCloudBatchSyncError.localCheckpointFailed
        }

        let currentLocal = try VocabCloudSnapshotMetadata(snapshot: localCheckpoint)
        guard currentLocal.fingerprint == plan.local.fingerprint else { return nil }
        guard let cloudSnapshot = try await store.load() else { return nil }
        let checkpoint = try createLocalStoreCheckpointIfNeeded(now: syncedAt)

        do {
            try VocabSyncSnapshotService.replaceLocalStore(with: cloudSnapshot, context: context, syncMode: .localOnly)
        } catch {
            do {
                try VocabSyncSnapshotService.replaceLocalStore(with: localCheckpoint, context: context, syncMode: .localOnly)
            } catch {
                throw VocabCloudBatchSyncError.localCheckpointRestoreFailed
            }
            throw error
        }

        try recordSyncedSnapshot(cloudSnapshot, syncedAt: syncedAt)
        return VocabCloudSnapshotSyncResult(snapshot: cloudSnapshot, checkpoint: checkpoint)
    }

    private func createLocalStoreCheckpointIfNeeded(now: Date) throws -> VocabLocalStoreCheckpoint? {
        guard let localStoreCheckpointCreator else { return nil }
        do {
            return try localStoreCheckpointCreator(now)
        } catch {
            throw VocabCloudBatchSyncError.localCheckpointFailed
        }
    }

    private func currentLocalMetadata(context: ModelContext, now: Date) throws -> VocabCloudSnapshotMetadata {
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        return try VocabCloudSnapshotMetadata(snapshot: snapshot)
    }

    private func action(
        local: VocabCloudSnapshotMetadata,
        cloud: VocabCloudSnapshotMetadata?,
        cursor: VocabCloudBatchSyncCursor?
    ) -> VocabCloudBatchSyncAction {
        guard let cloud else { return .uploadLocalSnapshot }
        if local.fingerprint == cloud.fingerprint { return .alreadyInSync }
        guard let cursor else { return .conflict }

        let localChanged = local.fingerprint != cursor.snapshotFingerprint
        let cloudChanged = cloud.fingerprint != cursor.snapshotFingerprint

        switch (localChanged, cloudChanged) {
        case (false, true):
            return .downloadCloudSnapshot
        case (true, false):
            return .uploadLocalSnapshot
        case (false, false):
            return .alreadyInSync
        case (true, true):
            return .conflict
        }
    }

    private func recordSyncedSnapshot(_ snapshot: VocabSyncSnapshot, syncedAt: Date) throws {
        let metadata = try VocabCloudSnapshotMetadata(snapshot: snapshot)
        stateStore.saveCursor(
            VocabCloudBatchSyncCursor(
                snapshotFingerprint: metadata.fingerprint,
                cloudExportedAt: metadata.exportedAt,
                syncedAt: syncedAt
            )
        )
    }
}

enum VocabAutomaticSnapshotSyncPolicy {
    static func allowsAutomaticBatchSync(syncMode: VocabSyncMode) -> Bool {
        // Snapshot transport is retained only for explicit recovery operations.
        false
    }
}

struct VocabCloudKitSnapshotStore: VocabCloudSnapshotStoring {
    private static let recordType = "VocabSnapshot"
    private static let recordName = "primary"
    private static let assetField = "snapshot"
    private static let exportedAtField = "exportedAt"
    private static let metadataField = "metadata"

    private let database: CKDatabase
    private let temporaryDirectory: URL

    init(
        container: CKContainer = CKContainer(identifier: VocabSyncMode.cloudKitContainerIdentifier),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.database = container.privateCloudDatabase
        self.temporaryDirectory = temporaryDirectory
    }

    func save(_ snapshot: VocabSyncSnapshot) async throws {
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(snapshot)
        let assetURL = try writeTemporaryAsset(data)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record = try await existingRecord(for: recordID)
        try apply(snapshot, assetURL: assetURL, to: record)
        _ = try await database.save(record)
    }

    func save(
        _ snapshot: VocabSyncSnapshot,
        ifCloudMetadataMatches expectedMetadata: VocabCloudSnapshotMetadata?
    ) async throws -> Bool {
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(snapshot)
        let assetURL = try writeTemporaryAsset(data)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        let recordID = CKRecord.ID(recordName: Self.recordName)
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            guard expectedMetadata == nil else { return false }
            let newRecord = CKRecord(recordType: Self.recordType, recordID: recordID)
            try apply(snapshot, assetURL: assetURL, to: newRecord)
            do {
                _ = try await database.save(newRecord)
                return true
            } catch let error as CKError where error.code == .serverRecordChanged {
                return false
            }
        }

        let currentMetadata = try metadata(from: record)
        guard currentMetadata == expectedMetadata else { return false }
        try apply(snapshot, assetURL: assetURL, to: record)
        do {
            _ = try await database.save(record)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return false
        }
    }

    func load() async throws -> VocabSyncSnapshot? {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            guard
                let asset = record[Self.assetField] as? CKAsset,
                let fileURL = asset.fileURL
            else {
                return nil
            }
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder.vocabSnapshotDecoder.decode(VocabSyncSnapshot.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    func metadata() async throws -> VocabCloudSnapshotMetadata? {
        let recordID = CKRecord.ID(recordName: Self.recordName)
        do {
            let record = try await database.record(for: recordID)
            return try metadata(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func apply(_ snapshot: VocabSyncSnapshot, assetURL: URL, to record: CKRecord) throws {
        record[Self.assetField] = CKAsset(fileURL: assetURL)
        record[Self.exportedAtField] = snapshot.exportedAt as NSDate
        record[Self.metadataField] = try JSONEncoder.vocabSnapshotEncoder.encode(
            VocabCloudSnapshotMetadata(snapshot: snapshot)
        ) as NSData
    }

    private func metadata(from record: CKRecord) throws -> VocabCloudSnapshotMetadata? {
        if let data = record[Self.metadataField] as? Data {
            return try JSONDecoder.vocabSnapshotDecoder.decode(VocabCloudSnapshotMetadata.self, from: data)
        }
        guard
            let asset = record[Self.assetField] as? CKAsset,
            let fileURL = asset.fileURL
        else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        let snapshot = try JSONDecoder.vocabSnapshotDecoder.decode(VocabSyncSnapshot.self, from: data)
        return try VocabCloudSnapshotMetadata(snapshot: snapshot)
    }

    private func writeTemporaryAsset(_ data: Data) throws -> URL {
        let directory = temporaryDirectory.appendingPathComponent("VocabCloudSnapshots", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent("\(UUID().uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func existingRecord(for recordID: CKRecord.ID) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: Self.recordType, recordID: recordID)
        }
    }
}

extension JSONEncoder {
    static var vocabSnapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var vocabSnapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
