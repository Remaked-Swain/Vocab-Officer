import CloudKit
import Foundation
import SwiftData

protocol VocabCloudSnapshotStoring {
    func save(_ snapshot: VocabSyncSnapshot) async throws
    func load() async throws -> VocabSyncSnapshot?
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

    init(snapshot: VocabSyncSnapshot) {
        self.wordCount = snapshot.words.count
        self.dailySetCount = snapshot.dailySets.count
        self.exportedAt = snapshot.exportedAt
    }

    init(metadata: VocabCloudSnapshotMetadata) {
        self.wordCount = metadata.wordCount
        self.dailySetCount = metadata.dailySetCount
        self.exportedAt = metadata.exportedAt
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

@MainActor
struct VocabCloudSnapshotSyncService {
    private let store: VocabCloudSnapshotStoring
    private let stateStore: VocabCloudBatchSyncStateStoring

    init(
        store: VocabCloudSnapshotStoring = VocabCloudKitSnapshotStore(),
        stateStore: VocabCloudBatchSyncStateStoring = VocabCloudBatchSyncUserDefaultsStore()
    ) {
        self.store = store
        self.stateStore = stateStore
    }

    func uploadLocalSnapshot(context: ModelContext, now: Date = .now) async throws -> VocabCloudSnapshotSyncResult {
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        try await store.save(snapshot)
        try recordSyncedSnapshot(snapshot, syncedAt: now)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot)
    }

    func replaceLocalStoreFromCloud(context: ModelContext, syncedAt: Date = .now) async throws -> VocabCloudSnapshotSyncResult? {
        guard let snapshot = try await store.load() else { return nil }
        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: context)
        try recordSyncedSnapshot(snapshot, syncedAt: syncedAt)
        return VocabCloudSnapshotSyncResult(snapshot: snapshot)
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
        switch plan.action {
        case .uploadLocalSnapshot:
            let result = try await uploadLocalSnapshot(context: context, now: now)
            return VocabCloudBatchSyncResult(
                action: .uploadLocalSnapshot,
                local: plan.local,
                cloud: plan.cloud,
                snapshotResult: result
            )
        case .downloadCloudSnapshot:
            let result = try await replaceLocalStoreFromCloud(context: context, syncedAt: now)
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
        record[Self.assetField] = CKAsset(fileURL: assetURL)
        record[Self.exportedAtField] = snapshot.exportedAt as NSDate
        record[Self.metadataField] = try JSONEncoder.vocabSnapshotEncoder.encode(
            VocabCloudSnapshotMetadata(snapshot: snapshot)
        ) as NSData
        _ = try await database.save(record)
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
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
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
