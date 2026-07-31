import Foundation
import SwiftData

enum VocabRecordMetadata {
    static let legacyOriginDeviceID = "legacy"
}

enum VocabDeviceIdentity {
    private static let defaultsKey = "vocabOriginDeviceID"

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: defaultsKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: defaultsKey)
        return created
    }
}

@Model
final class WordRecord {
    var id: UUID = UUID()
    var term: String = ""
    var normalizedTerm: String = ""
    var englishAliases: [String] = []
    var createdAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var statusRaw: String = "active"
    var deletedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \MeaningRecord.word) var meanings: [MeaningRecord]?
    @Relationship(deleteRule: .nullify, inverse: \AttemptRecord.word) var attempts: [AttemptRecord]?
    @Relationship(deleteRule: .nullify, inverse: \ReviewStateRecord.word) var reviewState: ReviewStateRecord?

    init(term: String, createdAt: Date = .now) {
        self.id = UUID()
        self.term = term
        self.normalizedTerm = TextNormalizer.normalizeEnglish(term)
        self.englishAliases = []
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.originDeviceID = VocabDeviceIdentity.current
        self.statusRaw = "active"
        self.meanings = []
        self.attempts = []
    }

    var allMeanings: [MeaningRecord] { meanings ?? [] }
    var allAttempts: [AttemptRecord] { attempts ?? [] }

    func appendMeaning(_ meaning: MeaningRecord) {
        meanings = allMeanings + [meaning]
    }

    func replaceMeanings(with records: [MeaningRecord]) {
        meanings = records
    }

    func appendAttempt(_ attempt: AttemptRecord) {
        attempts = allAttempts + [attempt]
    }

    func replaceAttempts(with records: [AttemptRecord]) {
        attempts = records
    }
}

@Model
final class MeaningRecord {
    var id: UUID = UUID()
    var text: String = ""
    var normalizedText: String = ""
    var isCore: Bool = true
    var aliases: [String] = []
    var successDays: [String] = []
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?
    var word: WordRecord?

    init(text: String, isCore: Bool = true, aliases: [String] = []) {
        self.id = UUID()
        self.text = text
        self.normalizedText = TextNormalizer.normalizeKorean(text)
        self.isCore = isCore
        self.aliases = aliases
        self.successDays = []
        self.updatedAt = .now
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class DailySetRecord {
    var id: UUID = UUID()
    var seoulDay: String = ""
    var createdAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var completedAt: Date?
    var deletedAt: Date?
    @Relationship(deleteRule: .nullify, inverse: \DailySetItemRecord.set) var items: [DailySetItemRecord]?

    init(seoulDay: String, createdAt: Date = .now) {
        self.id = UUID()
        self.seoulDay = seoulDay
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.originDeviceID = VocabDeviceIdentity.current
        self.items = []
    }

    var allItems: [DailySetItemRecord] { items ?? [] }

    func appendItem(_ item: DailySetItemRecord) {
        items = allItems + [item]
    }

    var isComplete: Bool { allItems.count == 100 }
}

@Model
final class DailySetItemRecord {
    var id: UUID = UUID()
    var orderIndex: Int = 0
    var entryKind: String = ""
    var wordID: UUID = UUID()
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?
    var set: DailySetRecord?

    init(orderIndex: Int, entryKind: String, wordID: UUID) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.entryKind = entryKind
        self.wordID = wordID
        self.updatedAt = .now
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class AttemptRecord {
    var id: UUID = UUID()
    var directionRaw: String = ""
    var modeRaw: String = ""
    var sessionID: UUID = UUID()
    var questionIndex: Int = 0
    var seoulDay: String = ""
    var prompt: String = ""
    var submittedAnswer: String = ""
    var automaticJudgementRaw: String = ""
    var finalJudgementRaw: String = ""
    var correctionRaw: String?
    var questionFormatRaw: String = QuestionFormat.typed.rawValue
    var matchedMeaningID: UUID?
    var answeredAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?
    var word: WordRecord?

    init(directionRaw: String, modeRaw: String, sessionID: UUID, questionIndex: Int, seoulDay: String, prompt: String, submittedAnswer: String, automaticJudgementRaw: String, finalJudgementRaw: String, matchedMeaningID: UUID?, answeredAt: Date = .now, questionFormatRaw: String = QuestionFormat.typed.rawValue) {
        self.id = UUID()
        self.directionRaw = directionRaw
        self.modeRaw = modeRaw
        self.sessionID = sessionID
        self.questionIndex = questionIndex
        self.seoulDay = seoulDay
        self.prompt = prompt
        self.submittedAnswer = submittedAnswer
        self.automaticJudgementRaw = automaticJudgementRaw
        self.finalJudgementRaw = finalJudgementRaw
        self.questionFormatRaw = questionFormatRaw
        self.matchedMeaningID = matchedMeaningID
        self.answeredAt = answeredAt
        self.updatedAt = answeredAt
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class TestSessionRecord {
    var id: UUID = UUID()
    var directionRaw: String = ""
    var modeRaw: String = ""
    var seoulDay: String = ""
    var startedAt: Date = Date.distantPast
    var completedAt: Date?
    var questionFormatRaw: String = QuestionFormat.typed.rawValue
    var wordIDs: [UUID] = []
    var wasReduced: Bool = false
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?

    init(id: UUID = UUID(), directionRaw: String, modeRaw: String, seoulDay: String, wordIDs: [UUID], wasReduced: Bool, startedAt: Date = .now, questionFormatRaw: String = QuestionFormat.typed.rawValue) {
        self.id = id
        self.directionRaw = directionRaw
        self.modeRaw = modeRaw
        self.seoulDay = seoulDay
        self.startedAt = startedAt
        self.questionFormatRaw = questionFormatRaw
        self.updatedAt = startedAt
        self.originDeviceID = VocabDeviceIdentity.current
        self.wordIDs = wordIDs
        self.wasReduced = wasReduced
    }
}

@Model
final class ReviewStateRecord {
    var id: UUID = UUID()
    var failureCheck: Int = 0
    var activePriority: Int = 0
    var enToKoStreak: Int = 0
    var koToEnStreak: Int = 0
    var koToEnSuccessDays: [String] = []
    var latestWrongDirection: String?
    var latestWrongAt: Date?
    var lastTestedAt: Date?
    var presentationCount: Int?
    var lastPresentedAt: Date?
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?
    var word: WordRecord?

    init() {
        self.id = UUID()
        self.failureCheck = 0
        self.activePriority = 0
        self.enToKoStreak = 0
        self.koToEnStreak = 0
        self.koToEnSuccessDays = []
        self.presentationCount = 0
        self.updatedAt = .now
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class AnonymousAggregateRecord {
    var id: UUID = UUID()
    var seoulDay: String = ""
    var modeRaw: String = ""
    var correctCount: Int = 0
    var incorrectCount: Int = 0
    var unknownCount: Int = 0
    var deletedMasteredCount: Int = 0
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?

    init(seoulDay: String, modeRaw: String) {
        self.id = UUID()
        self.seoulDay = seoulDay
        self.modeRaw = modeRaw
        self.correctCount = 0
        self.incorrectCount = 0
        self.unknownCount = 0
        self.deletedMasteredCount = 0
        self.updatedAt = .now
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class MemoryAidCacheRecord {
    var id: UUID = UUID()
    var wordID: UUID = UUID()
    var modelRaw: String = ""
    var promptVersion: Int = 0
    var contentSignature: String = ""
    var markdown: String = ""
    var generatedAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?

    init(
        wordID: UUID,
        modelRaw: String,
        promptVersion: Int,
        contentSignature: String,
        markdown: String,
        generatedAt: Date = .now
    ) {
        self.id = UUID()
        self.wordID = wordID
        self.modelRaw = modelRaw
        self.promptVersion = promptVersion
        self.contentSignature = contentSignature
        self.markdown = markdown
        self.generatedAt = generatedAt
        self.updatedAt = generatedAt
        self.originDeviceID = VocabDeviceIdentity.current
    }
}

@Model
final class CloudBootstrapRecord {
    var id: UUID = UUID()
    var key: String = "primary"
    var schemaVersion: Int = 1
    var bootstrapUUID: UUID = UUID()
    var contentFingerprint: String = ""
    var expectedWordCount: Int = 0
    var expectedMeaningCount: Int = 0
    var expectedDailySetCount: Int = 0
    var expectedDailySetItemCount: Int = 0
    var expectedTestSessionCount: Int = 0
    var expectedAttemptCount: Int = 0
    var expectedAnonymousAggregateCount: Int = 0
    var expectedMemoryAidCacheCount: Int = 0
    var expectedTombstoneCount: Int = 0
    var sourcePlatform: String = "macOS"
    var sourceDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var createdAt: Date = Date.distantPast
    var completedAt: Date = Date.distantPast
    var lastReconciledAt: Date?
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID
    var deletedAt: Date?

    init(
        bootstrapUUID: UUID = UUID(),
        contentFingerprint: String = "",
        completedAt: Date = .now,
        sourceDeviceID: String = VocabDeviceIdentity.current
    ) {
        self.bootstrapUUID = bootstrapUUID
        self.contentFingerprint = contentFingerprint
        self.sourceDeviceID = sourceDeviceID
        self.createdAt = completedAt
        self.completedAt = completedAt
        self.updatedAt = completedAt
        self.originDeviceID = sourceDeviceID
    }
}

@Model
final class BootstrapExportReceipt {
    var id: UUID = UUID()
    var requestID: UUID = UUID()
    var fingerprint: String = ""
    var storeUUID: String = ""
    var transactionCommittedAt: Date = Date.distantPast
    var probeGeneration: Int = 0
    var state: String = "awaitingExport"
    var nonce: UUID = UUID()

    init(
        requestID: UUID,
        fingerprint: String,
        storeUUID: String,
        transactionCommittedAt: Date,
        probeGeneration: Int = 0,
        state: String = "awaitingExport",
        nonce: UUID = UUID()
    ) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.storeUUID = storeUUID
        self.transactionCommittedAt = transactionCommittedAt
        self.probeGeneration = probeGeneration
        self.state = state
        self.nonce = nonce
    }
}

@Model
final class RecordTombstone {
    var id: UUID = UUID()
    var recordID: UUID = UUID()
    var recordType: String = ""
    var deletedAt: Date = Date.distantPast
    var updatedAt: Date = Date.distantPast
    var originDeviceID: String = VocabRecordMetadata.legacyOriginDeviceID

    init(recordID: UUID, recordType: String, deletedAt: Date = .now, originDeviceID: String = VocabDeviceIdentity.current) {
        self.id = recordID
        self.recordID = recordID
        self.recordType = recordType
        self.deletedAt = deletedAt
        self.updatedAt = deletedAt
        self.originDeviceID = originDeviceID
    }
}
