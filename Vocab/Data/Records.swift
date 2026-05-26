import Foundation
import SwiftData

@Model
final class WordRecord {
    @Attribute(.unique) var id: UUID
    var term: String
    var normalizedTerm: String
    var englishAliases: [String]
    var createdAt: Date
    var statusRaw: String
    var deletedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \MeaningRecord.word) var meanings: [MeaningRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \AttemptRecord.word) var attempts: [AttemptRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ReviewStateRecord.word) var reviewState: ReviewStateRecord?

    init(term: String, createdAt: Date = .now) {
        self.id = UUID()
        self.term = term
        self.normalizedTerm = TextNormalizer.normalizeEnglish(term)
        self.englishAliases = []
        self.createdAt = createdAt
        self.statusRaw = "active"
    }
}

@Model
final class MeaningRecord {
    @Attribute(.unique) var id: UUID
    var text: String
    var normalizedText: String
    var isCore: Bool
    var aliases: [String]
    var successDays: [String]
    var word: WordRecord?

    init(text: String, isCore: Bool = true, aliases: [String] = []) {
        self.id = UUID()
        self.text = text
        self.normalizedText = TextNormalizer.normalizeKorean(text)
        self.isCore = isCore
        self.aliases = aliases
        self.successDays = []
    }
}

@Model
final class DailySetRecord {
    @Attribute(.unique) var id: UUID
    var seoulDay: String
    var createdAt: Date
    var completedAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \DailySetItemRecord.set) var items: [DailySetItemRecord] = []

    init(seoulDay: String, createdAt: Date = .now) {
        self.id = UUID()
        self.seoulDay = seoulDay
        self.createdAt = createdAt
    }

    var isComplete: Bool { items.count == 100 }
}

@Model
final class DailySetItemRecord {
    @Attribute(.unique) var id: UUID
    var orderIndex: Int
    var entryKind: String
    var wordID: UUID
    var set: DailySetRecord?

    init(orderIndex: Int, entryKind: String, wordID: UUID) {
        self.id = UUID()
        self.orderIndex = orderIndex
        self.entryKind = entryKind
        self.wordID = wordID
    }
}

@Model
final class AttemptRecord {
    @Attribute(.unique) var id: UUID
    var directionRaw: String
    var modeRaw: String
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
    var word: WordRecord?

    init(directionRaw: String, modeRaw: String, sessionID: UUID, questionIndex: Int, seoulDay: String, prompt: String, submittedAnswer: String, automaticJudgementRaw: String, finalJudgementRaw: String, matchedMeaningID: UUID?, answeredAt: Date = .now) {
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
        self.matchedMeaningID = matchedMeaningID
        self.answeredAt = answeredAt
    }
}

@Model
final class TestSessionRecord {
    @Attribute(.unique) var id: UUID
    var directionRaw: String
    var modeRaw: String
    var seoulDay: String
    var startedAt: Date
    var completedAt: Date?
    var wordIDs: [UUID]
    var wasReduced: Bool

    init(id: UUID = UUID(), directionRaw: String, modeRaw: String, seoulDay: String, wordIDs: [UUID], wasReduced: Bool, startedAt: Date = .now) {
        self.id = id
        self.directionRaw = directionRaw
        self.modeRaw = modeRaw
        self.seoulDay = seoulDay
        self.startedAt = startedAt
        self.wordIDs = wordIDs
        self.wasReduced = wasReduced
    }
}

@Model
final class ReviewStateRecord {
    @Attribute(.unique) var id: UUID
    var failureCheck: Int
    var activePriority: Int
    var enToKoStreak: Int
    var koToEnStreak: Int
    var koToEnSuccessDays: [String]
    var latestWrongDirection: String?
    var latestWrongAt: Date?
    var lastTestedAt: Date?
    var word: WordRecord?

    init() {
        self.id = UUID()
        self.failureCheck = 0
        self.activePriority = 0
        self.enToKoStreak = 0
        self.koToEnStreak = 0
        self.koToEnSuccessDays = []
    }
}

@Model
final class AnonymousAggregateRecord {
    @Attribute(.unique) var id: UUID
    var seoulDay: String
    var modeRaw: String
    var correctCount: Int
    var incorrectCount: Int
    var unknownCount: Int
    var deletedMasteredCount: Int

    init(seoulDay: String, modeRaw: String) {
        self.id = UUID()
        self.seoulDay = seoulDay
        self.modeRaw = modeRaw
        self.correctCount = 0
        self.incorrectCount = 0
        self.unknownCount = 0
        self.deletedMasteredCount = 0
    }
}
