import Foundation

public enum Direction: String, CaseIterable, Codable, Hashable, Sendable {
    case enToKo
    case koToEn
}

public enum TestMode: String, CaseIterable, Codable, Hashable, Sendable {
    case today
    case review
    case mixed
}

public enum Judgement: String, Codable, Hashable, Sendable {
    case correct
    case incorrect
    case unknown
}

public struct AcceptedAlias: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

public struct CoreMeaning: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var aliases: [AcceptedAlias]

    public init(id: UUID = UUID(), text: String, aliases: [AcceptedAlias] = []) {
        self.id = id
        self.text = text
        self.aliases = aliases
    }
}

public struct Word: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var spelling: String
    public var coreMeanings: [CoreMeaning]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        spelling: String,
        coreMeanings: [CoreMeaning],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.spelling = spelling
        self.coreMeanings = coreMeanings
        self.createdAt = createdAt
    }
}

public struct Attempt: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let wordID: UUID
    public var direction: Direction
    public var answer: String
    public var judgement: Judgement
    public var occurredAt: Date
    public var matchedMeaningID: UUID?
    public var suggestion: String?

    public init(
        id: UUID = UUID(),
        wordID: UUID,
        direction: Direction,
        answer: String,
        judgement: Judgement,
        occurredAt: Date = Date(),
        matchedMeaningID: UUID? = nil,
        suggestion: String? = nil
    ) {
        self.id = id
        self.wordID = wordID
        self.direction = direction
        self.answer = answer
        self.judgement = judgement
        self.occurredAt = occurredAt
        self.matchedMeaningID = matchedMeaningID
        self.suggestion = suggestion
    }
}

public struct ReviewState: Codable, Hashable, Sendable {
    public var failureCheck: Int
    public var activePriority: Int
    public var enToKoStreak: Int
    public var koToEnStreak: Int
    public var coreMeaningSuccessDays: [UUID: Set<String>]
    public var koToEnSuccessDays: Set<String>
    public var latestWrongDirection: Direction?
    public var latestWrongAt: Date?
    public var masteredOn: Date?
    public var lastAttemptAt: Date?

    public init(
        failureCheck: Int = 0,
        activePriority: Int = 0,
        enToKoStreak: Int = 0,
        koToEnStreak: Int = 0,
        coreMeaningSuccessDays: [UUID: Set<String>] = [:],
        koToEnSuccessDays: Set<String> = [],
        latestWrongDirection: Direction? = nil,
        latestWrongAt: Date? = nil,
        masteredOn: Date? = nil,
        lastAttemptAt: Date? = nil
    ) {
        self.failureCheck = failureCheck
        self.activePriority = activePriority
        self.enToKoStreak = enToKoStreak
        self.koToEnStreak = koToEnStreak
        self.coreMeaningSuccessDays = coreMeaningSuccessDays
        self.koToEnSuccessDays = koToEnSuccessDays
        self.latestWrongDirection = latestWrongDirection
        self.latestWrongAt = latestWrongAt
        self.masteredOn = masteredOn
        self.lastAttemptAt = lastAttemptAt
    }

    public var isMastered: Bool {
        masteredOn != nil
    }
}

public struct WordProgress: Identifiable, Codable, Hashable, Sendable {
    public var word: Word
    public var attempts: [Attempt]
    public var reviewState: ReviewState

    public var id: UUID {
        word.id
    }

    public init(
        word: Word,
        attempts: [Attempt] = [],
        reviewState: ReviewState = ReviewState()
    ) {
        self.word = word
        self.attempts = attempts
        self.reviewState = reviewState
    }
}

public struct AnswerEvaluation: Codable, Hashable, Sendable {
    public var judgement: Judgement
    public var matchedAnswer: String?
    public var matchedMeaningID: UUID?
    public var suggestion: String?

    public init(
        judgement: Judgement,
        matchedAnswer: String? = nil,
        matchedMeaningID: UUID? = nil,
        suggestion: String? = nil
    ) {
        self.judgement = judgement
        self.matchedAnswer = matchedAnswer
        self.matchedMeaningID = matchedMeaningID
        self.suggestion = suggestion
    }
}
