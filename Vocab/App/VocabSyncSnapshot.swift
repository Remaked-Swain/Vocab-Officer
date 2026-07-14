import Foundation
import CryptoKit
import SwiftData

struct VocabSyncSnapshot: Codable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    var words: [WordPayload]
    var dailySets: [DailySetPayload]

    struct WordPayload: Codable, Equatable {
        var id: UUID
        var term: String
        var englishAliases: [String]
        var createdAt: Date
        var statusRaw: String
        var deletedAt: Date?
        var meanings: [MeaningPayload]
        var reviewState: ReviewStatePayload?
    }

    struct MeaningPayload: Codable, Equatable {
        var id: UUID
        var text: String
        var isCore: Bool
        var aliases: [String]
        var successDays: [String]
    }

    struct ReviewStatePayload: Codable, Equatable {
        var failureCheck: Int
        var activePriority: Int
        var enToKoStreak: Int
        var koToEnStreak: Int
        var koToEnSuccessDays: [String]
        var latestWrongDirection: String?
        var latestWrongAt: Date?
        var lastTestedAt: Date?
        var presentationCount: Int?
        var lastPresentedAt: Date?
    }

    struct DailySetPayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var createdAt: Date
        var completedAt: Date?
        var items: [DailySetItemPayload]
    }

    struct DailySetItemPayload: Codable, Equatable {
        var id: UUID
        var orderIndex: Int
        var entryKind: String
        var wordID: UUID
    }
}

extension VocabSyncSnapshot {
    func contentFingerprint() throws -> String {
        var normalized = self
        normalized.exportedAt = Date(timeIntervalSince1970: 0)
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(normalized)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
enum VocabSyncSnapshotService {
    static let currentFormatVersion = 1

    enum SnapshotValidationError: Error, Equatable {
        case unsupportedFormatVersion(Int)
        case duplicateWordID(UUID)
        case duplicateMeaningID(UUID)
        case duplicateDailySetID(UUID)
        case duplicateDailySetItemID(UUID)
        case missingWordForDailySetItem(UUID)
    }

    static func exportSnapshot(context: ModelContext, exportedAt: Date = .now) throws -> VocabSyncSnapshot {
        let words = try context.fetch(
            FetchDescriptor<WordRecord>(
                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.normalizedTerm)]
            )
        )
        let sets = try context.fetch(
            FetchDescriptor<DailySetRecord>(
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )

        return VocabSyncSnapshot(
            formatVersion: currentFormatVersion,
            exportedAt: exportedAt,
            words: words.map(wordPayload),
            dailySets: sets.map(dailySetPayload)
        )
    }

    static func replaceLocalStore(with snapshot: VocabSyncSnapshot, context: ModelContext) throws {
        try validate(snapshot)
        try deleteExistingSyncData(context: context)

        var wordsByID: [UUID: WordRecord] = [:]
        for payload in snapshot.words {
            let word = WordRecord(term: payload.term, createdAt: payload.createdAt)
            word.id = payload.id
            word.normalizedTerm = TextNormalizer.normalizeEnglish(payload.term)
            word.englishAliases = payload.englishAliases
            word.statusRaw = payload.statusRaw
            word.deletedAt = payload.deletedAt

            for meaningPayload in payload.meanings {
                let meaning = MeaningRecord(
                    text: meaningPayload.text,
                    isCore: meaningPayload.isCore,
                    aliases: meaningPayload.aliases
                )
                meaning.id = meaningPayload.id
                meaning.normalizedText = TextNormalizer.normalizeKorean(meaningPayload.text)
                meaning.successDays = meaningPayload.successDays
                meaning.word = word
                word.meanings.append(meaning)
                context.insert(meaning)
            }

            if let statePayload = payload.reviewState {
                let state = ReviewStateRecord()
                state.failureCheck = statePayload.failureCheck
                state.activePriority = statePayload.activePriority
                state.enToKoStreak = statePayload.enToKoStreak
                state.koToEnStreak = statePayload.koToEnStreak
                state.koToEnSuccessDays = statePayload.koToEnSuccessDays
                state.latestWrongDirection = statePayload.latestWrongDirection
                state.latestWrongAt = statePayload.latestWrongAt
                state.lastTestedAt = statePayload.lastTestedAt
                state.presentationCount = statePayload.presentationCount
                state.lastPresentedAt = statePayload.lastPresentedAt
                state.word = word
                word.reviewState = state
                context.insert(state)
            }

            context.insert(word)
            wordsByID[word.id] = word
        }

        for payload in snapshot.dailySets {
            let set = DailySetRecord(seoulDay: payload.seoulDay, createdAt: payload.createdAt)
            set.id = payload.id
            set.completedAt = payload.completedAt

            for itemPayload in payload.items {
                guard wordsByID[itemPayload.wordID] != nil else { continue }
                let item = DailySetItemRecord(
                    orderIndex: itemPayload.orderIndex,
                    entryKind: itemPayload.entryKind,
                    wordID: itemPayload.wordID
                )
                item.id = itemPayload.id
                item.set = set
                set.items.append(item)
                context.insert(item)
            }

            context.insert(set)
        }

        try context.save()
    }

    static func validate(_ snapshot: VocabSyncSnapshot) throws {
        guard snapshot.formatVersion == currentFormatVersion else {
            throw SnapshotValidationError.unsupportedFormatVersion(snapshot.formatVersion)
        }

        var wordIDs = Set<UUID>()
        var meaningIDs = Set<UUID>()
        var dailySetIDs = Set<UUID>()
        var dailySetItemIDs = Set<UUID>()

        for word in snapshot.words {
            guard wordIDs.insert(word.id).inserted else {
                throw SnapshotValidationError.duplicateWordID(word.id)
            }
            for meaning in word.meanings {
                guard meaningIDs.insert(meaning.id).inserted else {
                    throw SnapshotValidationError.duplicateMeaningID(meaning.id)
                }
            }
        }

        for set in snapshot.dailySets {
            guard dailySetIDs.insert(set.id).inserted else {
                throw SnapshotValidationError.duplicateDailySetID(set.id)
            }
            for item in set.items {
                guard dailySetItemIDs.insert(item.id).inserted else {
                    throw SnapshotValidationError.duplicateDailySetItemID(item.id)
                }
                guard wordIDs.contains(item.wordID) else {
                    throw SnapshotValidationError.missingWordForDailySetItem(item.wordID)
                }
            }
        }
    }

    private static func wordPayload(_ word: WordRecord) -> VocabSyncSnapshot.WordPayload {
        VocabSyncSnapshot.WordPayload(
            id: word.id,
            term: word.term,
            englishAliases: word.englishAliases,
            createdAt: word.createdAt,
            statusRaw: word.statusRaw,
            deletedAt: word.deletedAt,
            meanings: word.meanings.sorted { $0.text < $1.text }.map(meaningPayload),
            reviewState: word.reviewState.map(reviewPayload)
        )
    }

    private static func meaningPayload(_ meaning: MeaningRecord) -> VocabSyncSnapshot.MeaningPayload {
        VocabSyncSnapshot.MeaningPayload(
            id: meaning.id,
            text: meaning.text,
            isCore: meaning.isCore,
            aliases: meaning.aliases,
            successDays: meaning.successDays
        )
    }

    private static func reviewPayload(_ state: ReviewStateRecord) -> VocabSyncSnapshot.ReviewStatePayload {
        VocabSyncSnapshot.ReviewStatePayload(
            failureCheck: state.failureCheck,
            activePriority: state.activePriority,
            enToKoStreak: state.enToKoStreak,
            koToEnStreak: state.koToEnStreak,
            koToEnSuccessDays: state.koToEnSuccessDays,
            latestWrongDirection: state.latestWrongDirection,
            latestWrongAt: state.latestWrongAt,
            lastTestedAt: state.lastTestedAt,
            presentationCount: state.presentationCount,
            lastPresentedAt: state.lastPresentedAt
        )
    }

    private static func dailySetPayload(_ set: DailySetRecord) -> VocabSyncSnapshot.DailySetPayload {
        VocabSyncSnapshot.DailySetPayload(
            id: set.id,
            seoulDay: set.seoulDay,
            createdAt: set.createdAt,
            completedAt: set.completedAt,
            items: set.items.sorted { $0.orderIndex < $1.orderIndex }.map(itemPayload)
        )
    }

    private static func itemPayload(_ item: DailySetItemRecord) -> VocabSyncSnapshot.DailySetItemPayload {
        VocabSyncSnapshot.DailySetItemPayload(
            id: item.id,
            orderIndex: item.orderIndex,
            entryKind: item.entryKind,
            wordID: item.wordID
        )
    }

    private static func deleteExistingSyncData(context: ModelContext) throws {
        for record in try context.fetch(FetchDescriptor<TestSessionRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<MemoryAidCacheRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<DailySetRecord>()) {
            context.delete(record)
        }
        for record in try context.fetch(FetchDescriptor<WordRecord>()) {
            context.delete(record)
        }
    }
}
