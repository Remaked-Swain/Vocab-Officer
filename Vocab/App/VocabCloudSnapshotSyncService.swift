import CloudKit
import Foundation
import SwiftData

protocol VocabCloudSnapshotStoring {
    func save(_ snapshot: VocabSyncSnapshot) async throws
    func load() async throws -> VocabSyncSnapshot?
}

struct VocabCloudSnapshotSyncResult: Equatable {
    let wordCount: Int
    let dailySetCount: Int
    let exportedAt: Date
}

@MainActor
struct VocabCloudSnapshotSyncService {
    private let store: VocabCloudSnapshotStoring

    init(store: VocabCloudSnapshotStoring = VocabCloudKitSnapshotStore()) {
        self.store = store
    }

    func uploadLocalSnapshot(context: ModelContext, now: Date = .now) async throws -> VocabCloudSnapshotSyncResult {
        let snapshot = try VocabSyncSnapshotService.exportSnapshot(context: context, exportedAt: now)
        try await store.save(snapshot)
        return VocabCloudSnapshotSyncResult(
            wordCount: snapshot.words.count,
            dailySetCount: snapshot.dailySets.count,
            exportedAt: snapshot.exportedAt
        )
    }

    func replaceLocalStoreFromCloud(context: ModelContext) async throws -> VocabCloudSnapshotSyncResult? {
        guard let snapshot = try await store.load() else { return nil }
        try VocabSyncSnapshotService.replaceLocalStore(with: snapshot, context: context)
        return VocabCloudSnapshotSyncResult(
            wordCount: snapshot.words.count,
            dailySetCount: snapshot.dailySets.count,
            exportedAt: snapshot.exportedAt
        )
    }

    func inspectCloudSnapshot() async throws -> VocabCloudSnapshotSyncResult? {
        guard let snapshot = try await store.load() else { return nil }
        try VocabSyncSnapshotService.validate(snapshot)
        return VocabCloudSnapshotSyncResult(
            wordCount: snapshot.words.count,
            dailySetCount: snapshot.dailySets.count,
            exportedAt: snapshot.exportedAt
        )
    }
}

struct VocabCloudKitSnapshotStore: VocabCloudSnapshotStoring {
    private static let recordType = "VocabSnapshot"
    private static let recordName = "primary"
    private static let assetField = "snapshot"
    private static let exportedAtField = "exportedAt"

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
