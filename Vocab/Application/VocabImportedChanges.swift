import CryptoKit
import Foundation
import SwiftData

struct VocabImportedChangeIndex: Codable, Equatable {
    static let currentFormatVersion = 2

    struct Entry: Codable, Equatable {
        var signature: String
        var wordID: UUID?
    }

    var formatVersion: Int
    var canonicalAttemptSignatureVersion: Int
    var attempts: [String: Entry]
    var words: [String: Entry]
    var meanings: [String: Entry]
    var tombstones: [String: Entry]
}

struct VocabImportedChangeSet {
    var affectedWordIDs: Set<UUID>
    var changedTombstoneIDs: Set<UUID>
    var nextIndex: VocabImportedChangeIndex
    var requiresFullAudit: Bool
}

enum VocabImportedChangeSource: Equatable, Sendable {
    /// Reconcile the records changed in persistent history since the cursor.
    case persistentHistory
    case cloudImportWithoutIdentifiers
}

struct VocabChangedRecordID: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case attempt
        case word
        case meaning
        case tombstone
        /// Derived per word; changes are not diffed against the index but
        /// always recheck the word and the record's own tombstone.
        case reviewState
        case memoryAid
    }

    let kind: Kind
    let id: UUID

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

enum VocabImportedChangeIndexStore {
    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Vocab/SyncRuntime", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("import-index-v2.json")
    }

    static func load(from url: URL) throws -> VocabImportedChangeIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(VocabImportedChangeIndex.self, from: Data(contentsOf: url))
    }

    static func save(_ index: VocabImportedChangeIndex, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(index).write(to: url, options: .atomic)
    }
}

enum VocabImportedChangeDiscovery {
    static func discover(
        context: ModelContext,
        previous: VocabImportedChangeIndex?,
        changedRecords: Set<VocabChangedRecordID>
    ) throws -> VocabImportedChangeSet {
        guard let previous,
              previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
              previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion else {
            return try discover(context: context, previous: nil)
        }

        var next = previous
        var affectedWordIDs = Set<UUID>()
        var changedTombstoneIDs = Set<UUID>()
        var hasUnresolvedIdentifier = false
        for changedRecord in changedRecords {
            if changedRecord.kind == .attempt {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = attemptEntry(record)
                if previous.attempts[key] != entry {
                    if let old = previous.attempts[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    next.attempts[key] = entry
                }
            } else if changedRecord.kind == .word {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = wordEntry(record)
                if previous.words[key] != entry {
                    affectedWordIDs.insert(record.id)
                    next.words[key] = entry
                }
            } else if changedRecord.kind == .meaning {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = meaningEntry(record)
                if previous.meanings[key] != entry {
                    if let old = previous.meanings[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    next.meanings[key] = entry
                }
            } else if changedRecord.kind == .tombstone {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<RecordTombstone>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                let key = record.id.uuidString
                let entry = try tombstoneEntry(record, context: context)
                if previous.tombstones[key] != entry {
                    if let old = previous.tombstones[key]?.wordID { affectedWordIDs.insert(old) }
                    if let current = entry.wordID { affectedWordIDs.insert(current) }
                    changedTombstoneIDs.insert(record.id)
                    next.tombstones[key] = entry
                }
            } else if changedRecord.kind == .reviewState {
                // A peer may overwrite a derived state without an attempt
                // change: recompute it from the word's attempts.
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<ReviewStateRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                if let wordID = record.word?.id { affectedWordIDs.insert(wordID) }
            } else if changedRecord.kind == .memoryAid {
                let recordID = changedRecord.id
                guard let record = try context.fetch(FetchDescriptor<MemoryAidCacheRecord>(predicate: #Predicate { $0.id == recordID })).first else {
                    hasUnresolvedIdentifier = true
                    continue
                }
                affectedWordIDs.insert(record.wordID)
            }
        }
        // A tombstone's ID is its target's ID: every changed record rechecks
        // its own tombstone, so an older peer cannot resurrect it.
        changedTombstoneIDs.formUnion(changedRecords.compactMap { changedRecord in
            changedRecord.kind == .tombstone ? nil : changedRecord.id
        })
        return VocabImportedChangeSet(
            affectedWordIDs: affectedWordIDs,
            changedTombstoneIDs: changedTombstoneIDs,
            nextIndex: next,
            requiresFullAudit: hasUnresolvedIdentifier
        )
    }

    static func discover(
        context: ModelContext,
        previous: VocabImportedChangeIndex?
    ) throws -> VocabImportedChangeSet {
        let words = try context.fetch(FetchDescriptor<WordRecord>())
        let meanings = try context.fetch(FetchDescriptor<MeaningRecord>())
        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        let reviewStates = try context.fetch(FetchDescriptor<ReviewStateRecord>())
        let memoryAids = try context.fetch(FetchDescriptor<MemoryAidCacheRecord>())
        let setItems = try context.fetch(FetchDescriptor<DailySetItemRecord>())
        let tombstones = try context.fetch(FetchDescriptor<RecordTombstone>())

        let next = VocabImportedChangeIndex(
            formatVersion: VocabImportedChangeIndex.currentFormatVersion,
            canonicalAttemptSignatureVersion: VocabAttemptCanonicalPayload.signatureVersion,
            attempts: Dictionary(uniqueKeysWithValues: attempts.map { ($0.id.uuidString, attemptEntry($0)) }),
            words: Dictionary(uniqueKeysWithValues: words.map { ($0.id.uuidString, wordEntry($0)) }),
            meanings: Dictionary(uniqueKeysWithValues: meanings.map { ($0.id.uuidString, meaningEntry($0)) }),
            tombstones: Dictionary(uniqueKeysWithValues: tombstones.map {
                ($0.id.uuidString, tombstoneEntry(
                    $0,
                    words: words,
                    meanings: meanings,
                    attempts: attempts,
                    reviewStates: reviewStates,
                    memoryAids: memoryAids,
                    setItems: setItems
                ))
            })
        )

        guard let previous,
              previous.formatVersion == VocabImportedChangeIndex.currentFormatVersion,
              previous.canonicalAttemptSignatureVersion == VocabAttemptCanonicalPayload.signatureVersion else {
            return VocabImportedChangeSet(
                affectedWordIDs: Set(words.map(\.id)),
                changedTombstoneIDs: Set(tombstones.map(\.id)),
                nextIndex: next,
                requiresFullAudit: true
            )
        }

        var affected = changedWordIDs(previous: previous.attempts, next: next.attempts)
        affected.formUnion(changedWordIDs(previous: previous.words, next: next.words))
        affected.formUnion(changedWordIDs(previous: previous.meanings, next: next.meanings))
        affected.formUnion(changedWordIDs(previous: previous.tombstones, next: next.tombstones))
        let changedTombstones = changedKeys(previous: previous.tombstones, next: next.tombstones)
            .compactMap(UUID.init(uuidString:))
        let reappliedTombstones = changedKeys(previous: previous.attempts, next: next.attempts)
            .union(changedKeys(previous: previous.words, next: next.words))
            .union(changedKeys(previous: previous.meanings, next: next.meanings))
            .compactMap(UUID.init(uuidString:))

        return VocabImportedChangeSet(
            affectedWordIDs: affected,
            changedTombstoneIDs: Set(changedTombstones).union(reappliedTombstones),
            nextIndex: next,
            requiresFullAudit: false
        )
    }

    private static func changedWordIDs(
        previous: [String: VocabImportedChangeIndex.Entry],
        next: [String: VocabImportedChangeIndex.Entry]
    ) -> Set<UUID> {
        changedKeys(previous: previous, next: next).reduce(into: Set<UUID>()) { result, key in
            if let id = next[key]?.wordID ?? previous[key]?.wordID { result.insert(id) }
        }
    }

    static func attemptEntry(_ record: AttemptRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString
        ] + VocabAttemptCanonicalPayload(record).signatureComponents + [
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.word?.id)
    }

    static func wordEntry(_ record: WordRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.term, record.statusRaw,
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.id)
    }

    static func meaningEntry(_ record: MeaningRecord) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.word?.id.uuidString ?? "", record.text,
            String(record.isCore), record.aliases.sorted().joined(separator: "\u{1f}"),
            timestamp(record.updatedAt), timestamp(record.deletedAt)
        ]), wordID: record.word?.id)
    }

    static func tombstoneEntry(
        _ record: RecordTombstone,
        words: [WordRecord],
        meanings: [MeaningRecord],
        attempts: [AttemptRecord] = [],
        reviewStates: [ReviewStateRecord] = [],
        memoryAids: [MemoryAidCacheRecord] = [],
        setItems: [DailySetItemRecord] = []
    ) -> VocabImportedChangeIndex.Entry {
        .init(signature: digest([
            record.id.uuidString, record.recordType, record.recordID.uuidString,
            timestamp(record.deletedAt), timestamp(record.updatedAt)
        ]), wordID: tombstoneWordID(
            record,
            words: words,
            meanings: meanings,
            attempts: attempts,
            reviewStates: reviewStates,
            memoryAids: memoryAids,
            setItems: setItems
        ))
    }

    static func tombstoneEntry(
        _ record: RecordTombstone,
        context: ModelContext
    ) throws -> VocabImportedChangeIndex.Entry {
        let wordID: UUID?
        switch record.recordType {
        case "WordRecord":
            wordID = record.recordID
        case "MeaningRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<MeaningRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.word?.id
        case "DailySetItemRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<DailySetItemRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.wordID
        case "AttemptRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<AttemptRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.word?.id
        case "ReviewStateRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<ReviewStateRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.word?.id
        case "MemoryAidCacheRecord":
            let recordID = record.recordID
            wordID = try context.fetch(
                FetchDescriptor<MemoryAidCacheRecord>(predicate: #Predicate { $0.id == recordID })
            ).first?.wordID
        default:
            wordID = nil
        }
        return .init(signature: digest([
            record.id.uuidString, record.recordType, record.recordID.uuidString,
            timestamp(record.deletedAt), timestamp(record.updatedAt)
        ]), wordID: wordID)
    }

    private static func changedKeys(
        previous: [String: VocabImportedChangeIndex.Entry],
        next: [String: VocabImportedChangeIndex.Entry]
    ) -> Set<String> {
        Set(previous.keys).union(next.keys).filter { previous[$0] != next[$0] }
    }

    private static func tombstoneWordID(
        _ tombstone: RecordTombstone,
        words: [WordRecord],
        meanings: [MeaningRecord],
        attempts: [AttemptRecord],
        reviewStates: [ReviewStateRecord],
        memoryAids: [MemoryAidCacheRecord],
        setItems: [DailySetItemRecord]
    ) -> UUID? {
        switch tombstone.recordType {
        case "WordRecord": tombstone.recordID
        case "MeaningRecord": meanings.first(where: { $0.id == tombstone.recordID })?.word?.id
        case "AttemptRecord": attempts.first(where: { $0.id == tombstone.recordID })?.word?.id
        case "ReviewStateRecord": reviewStates.first(where: { $0.id == tombstone.recordID })?.word?.id
        case "MemoryAidCacheRecord": memoryAids.first(where: { $0.id == tombstone.recordID })?.wordID
        case "DailySetItemRecord": setItems.first(where: { $0.id == tombstone.recordID })?.wordID
        default: nil
        }
    }

    private static func timestamp(_ date: Date?) -> String {
        date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "nil"
    }

    private static func digest(_ fields: [String]) -> String {
        SHA256.hash(data: Data(fields.joined(separator: "\u{1e}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
