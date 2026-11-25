import Foundation
import SwiftData

/// Records changed in the store's persistent history since the reconciliation
/// cursor, by whichever author: CloudKit imports, local saves and
/// reconciliation's own writes alike.
struct VocabImportHistoryChanges: Equatable {
    var records: Set<VocabChangedRecordID>
    var requiresFullAudit: Bool
    /// The newest transaction accounted for. The cursor advances here only
    /// after these changes (or a full audit that started after reading it)
    /// have been reconciled; `nil` when the store has no history yet.
    var latestToken: DefaultHistoryToken?
}

enum VocabImportHistoryReader {
    /// Transactions read per fetch, so a long backlog never loads at once.
    static let pageSize = 200
    /// Above this many changed records a full audit is cheaper than
    /// per-record discovery.
    static let maximumChangedRecords = 2_000

    /// Models reconciliation neither diffs nor tombstones: bootstrap metadata
    /// and export receipts (sync bookkeeping), sessions (replay reaches them
    /// through their attempts; retirement only unlinks them) and anonymous
    /// daily counts (unlinkable by design). Everything identifying is
    /// tracked, so its own tombstone is rechecked when a peer rewrites it.
    static let ignoredEntityNames: Set<String> = [
        "CloudBootstrapRecord",
        "BootstrapExportReceipt",
        "TestSessionRecord",
        "AnonymousAggregateRecord"
    ]

    static func latestToken(context: ModelContext) throws -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetchHistory(descriptor).first?.token
    }

    /// Bound: `O(T + C)` for `T` transactions and `C` changes after the
    /// cursor, plus one indexed fetch per distinct tracked record.
    static func changes(
        since cursor: DefaultHistoryToken?,
        context: ModelContext
    ) throws -> VocabImportHistoryChanges {
        let latest = try latestToken(context: context)
        guard let cursor,
              let latest,
              // A token from another store (a store switch or recovery swap)
              // matches no transaction instead of failing, so it would
              // silently report no change.
              isFromSameStore(cursor, as: latest) else {
            return fullAudit(latestToken: latest)
        }
        guard cursor < latest else {
            return VocabImportHistoryChanges(records: [], requiresFullAudit: false, latestToken: cursor)
        }

        var identifiers = Set<PersistentIdentifier>()
        var lastRead = cursor
        while true {
            let after = lastRead
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate { $0.token > after },
                sortBy: [SortDescriptor(\.transactionIdentifier)]
            )
            descriptor.fetchLimit = UInt64(pageSize)
            let page: [DefaultHistoryTransaction]
            do {
                page = try context.fetchHistory(descriptor)
            } catch {
                // History pruned past the cursor: what changed is unknown.
                return fullAudit(latestToken: latest)
            }
            for transaction in page {
                for change in transaction.changes {
                    let identifier = change.changedPersistentIdentifier
                    guard !ignoredEntityNames.contains(identifier.entityName) else { continue }
                    guard case .delete = change else {
                        identifiers.insert(identifier)
                        continue
                    }
                    // A hard-deleted record can no longer be resolved to the
                    // UUID its index entry is keyed by.
                    return fullAudit(latestToken: latest)
                }
            }
            if identifiers.count > maximumChangedRecords {
                return fullAudit(latestToken: latest)
            }
            guard let last = page.last else { break }
            lastRead = last.token
            if page.count < pageSize { break }
        }

        var records = Set<VocabChangedRecordID>()
        for identifier in identifiers {
            guard let record = try record(for: identifier, context: context) else {
                return fullAudit(latestToken: latest)
            }
            records.insert(record)
        }
        return VocabImportHistoryChanges(records: records, requiresFullAudit: false, latestToken: lastRead)
    }

    /// A token's value maps each store's identifier to its position.
    /// (`HistoryToken.storeIdentifier` needs OS 27.) No value is never a match.
    private static func isFromSameStore(_ cursor: DefaultHistoryToken, as latest: DefaultHistoryToken) -> Bool {
        guard let cursorStores = cursor.tokenValue?.keys,
              let latestStores = latest.tokenValue?.keys else { return false }
        return Set(cursorStores) == Set(latestStores)
    }

    private static func fullAudit(latestToken: DefaultHistoryToken?) -> VocabImportHistoryChanges {
        VocabImportHistoryChanges(records: [], requiresFullAudit: true, latestToken: latestToken)
    }

    /// `nil` when the model is untracked or no longer exists. Fetching by
    /// identifier never faults in a deleted record.
    private static func record(
        for identifier: PersistentIdentifier,
        context: ModelContext
    ) throws -> VocabChangedRecordID? {
        switch identifier.entityName {
        case "AttemptRecord":
            return try context.fetch(identified(identifier, as: AttemptRecord.self)).first
                .map { VocabChangedRecordID(kind: .attempt, id: $0.id) }
        case "WordRecord":
            return try context.fetch(identified(identifier, as: WordRecord.self)).first
                .map { VocabChangedRecordID(kind: .word, id: $0.id) }
        case "MeaningRecord":
            return try context.fetch(identified(identifier, as: MeaningRecord.self)).first
                .map { VocabChangedRecordID(kind: .meaning, id: $0.id) }
        case "RecordTombstone":
            return try context.fetch(identified(identifier, as: RecordTombstone.self)).first
                .map { VocabChangedRecordID(kind: .tombstone, id: $0.id) }
        case "ReviewStateRecord":
            return try context.fetch(identified(identifier, as: ReviewStateRecord.self)).first
                .map { VocabChangedRecordID(kind: .reviewState, id: $0.id) }
        case "MemoryAidCacheRecord":
            return try context.fetch(identified(identifier, as: MemoryAidCacheRecord.self)).first
                .map { VocabChangedRecordID(kind: .memoryAid, id: $0.id) }
        default:
            return nil
        }
    }

    private static func identified<Model: PersistentModel>(
        _ identifier: PersistentIdentifier,
        as _: Model.Type
    ) -> FetchDescriptor<Model> {
        var descriptor = FetchDescriptor<Model>(predicate: #Predicate { $0.persistentModelID == identifier })
        descriptor.fetchLimit = 1
        return descriptor
    }
}

/// Persists the history cursor. Anything unreadable loads as `nil`, which
/// requests a full audit rather than guessing where to resume.
enum VocabImportHistoryCursorStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime/import-history-cursor-v1.json")
    }

    static func load(from url: URL) -> DefaultHistoryToken? {
        do {
            return try JSONDecoder().decode(DefaultHistoryToken.self, from: Data(contentsOf: url))
        } catch {
            return nil
        }
    }

    static func save(_ token: DefaultHistoryToken, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(token).write(to: url, options: .atomic)
    }
}
