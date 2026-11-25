import Foundation
import CryptoKit

struct VocabSyncSnapshot: Codable, Equatable {
    var formatVersion: Int
    var exportedAt: Date
    var syncMetadata: SyncMetadataPayload? = nil
    var words: [WordPayload]
    var dailySets: [DailySetPayload]
    var testSessions: [TestSessionPayload] = []
    var attempts: [AttemptPayload] = []
    var anonymousAggregates: [AnonymousAggregatePayload] = []
    var memoryAidCaches: [MemoryAidCachePayload] = []
    var tombstones: [TombstonePayload] = []

    struct SyncMetadataPayload: Codable, Equatable {
        var schemaVersion: Int
        var bootstrapUUID: UUID
        var contentFingerprint: String
        var expectedCounts: VocabEntityCounts
        var createdAt: Date
        var completedAt: Date? = nil
        var lastReconciledAt: Date? = nil
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct WordPayload: Codable, Equatable {
        var id: UUID
        var term: String
        var englishAliases: [String]
        var createdAt: Date
        var statusRaw: String
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
        var meanings: [MeaningPayload]
        var reviewState: ReviewStatePayload?
    }

    struct MeaningPayload: Codable, Equatable {
        var id: UUID
        var text: String
        var isCore: Bool
        var aliases: [String]
        var successDays: [String]
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
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
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct DailySetPayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var createdAt: Date
        var completedAt: Date?
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
        var items: [DailySetItemPayload]
    }

    struct DailySetItemPayload: Codable, Equatable {
        var id: UUID
        var orderIndex: Int
        var entryKind: String
        var wordID: UUID
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date?
    }

    struct TestSessionPayload: Codable, Equatable {
        var id: UUID
        var directionRaw: String
        var modeRaw: String
        var questionFormatRaw: String = QuestionFormat.typed.rawValue
        var seoulDay: String
        var startedAt: Date
        var completedAt: Date?
        var wordIDs: [UUID]
        var wasReduced: Bool
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct AttemptPayload: Codable, Equatable {
        var id: UUID
        var directionRaw: String
        var modeRaw: String
        var questionFormatRaw: String = QuestionFormat.typed.rawValue
        var sessionID: UUID
        var questionIndex: Int
        var seoulDay: String
        var prompt: String
        var submittedAnswer: String
        var automaticJudgementRaw: String
        var finalJudgementRaw: String
        var correctionRaw: String?
        var matchedMeaningID: UUID?
        var answeredAt: Date
        var wordID: UUID?
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct AnonymousAggregatePayload: Codable, Equatable {
        var id: UUID
        var seoulDay: String
        var modeRaw: String
        var correctCount: Int
        var incorrectCount: Int
        var unknownCount: Int
        var deletedMasteredCount: Int
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct MemoryAidCachePayload: Codable, Equatable {
        var id: UUID
        var wordID: UUID
        var modelRaw: String
        var promptVersion: Int
        var contentSignature: String
        var markdown: String
        var generatedAt: Date
        var updatedAt: Date? = nil
        var originDeviceID: String? = nil
        var deletedAt: Date? = nil
    }

    struct TombstonePayload: Codable, Equatable {
        var id: UUID
        var recordID: UUID
        var recordType: String
        var deletedAt: Date
        var updatedAt: Date? = nil
        var originDeviceID: String
    }
}

extension VocabSyncSnapshot {
    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case exportedAt
        case syncMetadata
        case words
        case dailySets
        case testSessions
        case attempts
        case anonymousAggregates
        case memoryAidCaches
        case tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        syncMetadata = try container.decodeIfPresent(SyncMetadataPayload.self, forKey: .syncMetadata)
        words = try container.decode([WordPayload].self, forKey: .words)
        dailySets = try container.decode([DailySetPayload].self, forKey: .dailySets)
        testSessions = try container.decodeIfPresent([TestSessionPayload].self, forKey: .testSessions) ?? []
        attempts = try container.decodeIfPresent([AttemptPayload].self, forKey: .attempts) ?? []
        anonymousAggregates = try container.decodeIfPresent(
            [AnonymousAggregatePayload].self,
            forKey: .anonymousAggregates
        ) ?? []
        memoryAidCaches = try container.decodeIfPresent([MemoryAidCachePayload].self, forKey: .memoryAidCaches) ?? []
        tombstones = try container.decodeIfPresent([TombstonePayload].self, forKey: .tombstones) ?? []
    }
}

extension VocabSyncSnapshot.TestSessionPayload {
    private enum CodingKeys: String, CodingKey {
        case id
        case directionRaw
        case modeRaw
        case questionFormatRaw
        case seoulDay
        case startedAt
        case completedAt
        case wordIDs
        case wasReduced
        case updatedAt
        case originDeviceID
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        directionRaw = try container.decode(String.self, forKey: .directionRaw)
        modeRaw = try container.decode(String.self, forKey: .modeRaw)
        questionFormatRaw = try container.decodeIfPresent(String.self, forKey: .questionFormatRaw) ?? QuestionFormat.typed.rawValue
        seoulDay = try container.decode(String.self, forKey: .seoulDay)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        wordIDs = try container.decode([UUID].self, forKey: .wordIDs)
        wasReduced = try container.decode(Bool.self, forKey: .wasReduced)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

extension VocabSyncSnapshot.AttemptPayload {
    private enum CodingKeys: String, CodingKey {
        case id
        case directionRaw
        case modeRaw
        case questionFormatRaw
        case sessionID
        case questionIndex
        case seoulDay
        case prompt
        case submittedAnswer
        case automaticJudgementRaw
        case finalJudgementRaw
        case correctionRaw
        case matchedMeaningID
        case answeredAt
        case wordID
        case updatedAt
        case originDeviceID
        case deletedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        directionRaw = try container.decode(String.self, forKey: .directionRaw)
        modeRaw = try container.decode(String.self, forKey: .modeRaw)
        questionFormatRaw = try container.decodeIfPresent(String.self, forKey: .questionFormatRaw) ?? QuestionFormat.typed.rawValue
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        questionIndex = try container.decode(Int.self, forKey: .questionIndex)
        seoulDay = try container.decode(String.self, forKey: .seoulDay)
        prompt = try container.decode(String.self, forKey: .prompt)
        submittedAnswer = try container.decode(String.self, forKey: .submittedAnswer)
        automaticJudgementRaw = try container.decode(String.self, forKey: .automaticJudgementRaw)
        finalJudgementRaw = try container.decode(String.self, forKey: .finalJudgementRaw)
        correctionRaw = try container.decodeIfPresent(String.self, forKey: .correctionRaw)
        matchedMeaningID = try container.decodeIfPresent(UUID.self, forKey: .matchedMeaningID)
        answeredAt = try container.decode(Date.self, forKey: .answeredAt)
        wordID = try container.decodeIfPresent(UUID.self, forKey: .wordID)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        originDeviceID = try container.decodeIfPresent(String.self, forKey: .originDeviceID)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

extension VocabSyncSnapshot {
    func contentFingerprint() throws -> String {
        var normalized = self
        normalized.exportedAt = Date(timeIntervalSince1970: 0)
        normalized.syncMetadata = nil
        let deletionMarker = Date(timeIntervalSince1970: 0)
        func stableDate(_ date: Date) -> Date {
            Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        }
        func stableDate(_ date: Date?) -> Date? {
            date.map(stableDate)
        }
        func stableSetCreationDate(_ date: Date) -> Date {
            // Legacy sets stored a missing required date as NULL. CloudKit materializes
            // the same sentinel as its reference date, so both represent no user data.
            guard date > Date(timeIntervalSinceReferenceDate: 0) else { return deletionMarker }
            return stableDate(date)
        }
        let tombstoned = Set(tombstones.map { "\($0.recordType):\($0.recordID.uuidString)" })
        func isDeleted(_ recordType: String, _ id: UUID, _ deletedAt: Date?) -> Bool {
            deletedAt != nil || tombstoned.contains("\(recordType):\(id.uuidString)")
        }

        normalized.words = normalized.words.map { word in
            var word = word
            word.updatedAt = nil
            word.originDeviceID = nil
            word.statusRaw = ""
            word.createdAt = stableDate(word.createdAt)
            word.deletedAt = isDeleted("WordRecord", word.id, word.deletedAt) ? deletionMarker : nil
            word.meanings = word.meanings.map { meaning in
                var meaning = meaning
                meaning.updatedAt = nil
                meaning.originDeviceID = nil
                meaning.deletedAt = isDeleted("MeaningRecord", meaning.id, meaning.deletedAt) ? deletionMarker : nil
                meaning.aliases.sort()
                meaning.successDays = []
                return meaning
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            word.reviewState = nil
            word.englishAliases.sort()
            return word
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.dailySets = normalized.dailySets.map { set in
            var set = set
            set.createdAt = stableSetCreationDate(set.createdAt)
            set.completedAt = stableDate(set.completedAt)
            set.updatedAt = nil
            set.originDeviceID = nil
            set.deletedAt = isDeleted("DailySetRecord", set.id, set.deletedAt) ? deletionMarker : nil
            set.items = set.items.map { item in
                var item = item
                item.updatedAt = nil
                item.originDeviceID = nil
                item.deletedAt = isDeleted("DailySetItemRecord", item.id, item.deletedAt) ? deletionMarker : nil
                return item
            }.sorted { $0.id.uuidString < $1.id.uuidString }
            return set
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.testSessions = normalized.testSessions.map { record in
            var record = record
            record.startedAt = stableDate(record.startedAt)
            record.completedAt = stableDate(record.completedAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.attempts = normalized.attempts.map { record in
            var record = record
            record.answeredAt = stableDate(record.answeredAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.anonymousAggregates = normalized.anonymousAggregates.map { record in
            var record = record
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.memoryAidCaches = normalized.memoryAidCaches.map { record in
            var record = record
            record.generatedAt = stableDate(record.generatedAt)
            record.updatedAt = nil
            record.originDeviceID = nil
            record.deletedAt = record.deletedAt == nil ? nil : deletionMarker
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        normalized.tombstones = normalized.tombstones.map { record in
            var record = record
            record.deletedAt = deletionMarker
            record.updatedAt = nil
            record.originDeviceID = ""
            return record
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(normalized)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
