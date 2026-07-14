import Foundation
import SwiftData

// Exact persisted model graph from the production schema immediately before sync metadata was added.
enum VocabSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            WordRecord.self,
            MeaningRecord.self,
            DailySetRecord.self,
            DailySetItemRecord.self,
            TestSessionRecord.self,
            AttemptRecord.self,
            ReviewStateRecord.self,
            AnonymousAggregateRecord.self,
            MemoryAidCacheRecord.self
        ]
    }

    @Model
    final class WordRecord {
        var id: UUID
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
            id = UUID()
            self.term = term
            normalizedTerm = TextNormalizer.normalizeEnglish(term)
            englishAliases = []
            self.createdAt = createdAt
            statusRaw = "active"
        }
    }

    @Model
    final class MeaningRecord {
        var id: UUID
        var text: String
        var normalizedText: String
        var isCore: Bool
        var aliases: [String]
        var successDays: [String]
        var word: WordRecord?

        init(text: String, isCore: Bool = true, aliases: [String] = []) {
            id = UUID()
            self.text = text
            normalizedText = TextNormalizer.normalizeKorean(text)
            self.isCore = isCore
            self.aliases = aliases
            successDays = []
        }
    }

    @Model
    final class DailySetRecord {
        var id: UUID
        var seoulDay: String
        var createdAt: Date
        var completedAt: Date?
        @Relationship(deleteRule: .cascade, inverse: \DailySetItemRecord.set) var items: [DailySetItemRecord] = []

        init(seoulDay: String, createdAt: Date = .now) {
            id = UUID()
            self.seoulDay = seoulDay
            self.createdAt = createdAt
        }

        var isComplete: Bool { items.count == 100 }
    }

    @Model
    final class DailySetItemRecord {
        var id: UUID
        var orderIndex: Int
        var entryKind: String
        var wordID: UUID
        var set: DailySetRecord?

        init(orderIndex: Int, entryKind: String, wordID: UUID) {
            id = UUID()
            self.orderIndex = orderIndex
            self.entryKind = entryKind
            self.wordID = wordID
        }
    }

    @Model
    final class AttemptRecord {
        var id: UUID
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

        init(
            directionRaw: String,
            modeRaw: String,
            sessionID: UUID,
            questionIndex: Int,
            seoulDay: String,
            prompt: String,
            submittedAnswer: String,
            automaticJudgementRaw: String,
            finalJudgementRaw: String,
            matchedMeaningID: UUID?,
            answeredAt: Date = .now
        ) {
            id = UUID()
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
        var id: UUID
        var directionRaw: String
        var modeRaw: String
        var seoulDay: String
        var startedAt: Date
        var completedAt: Date?
        var wordIDs: [UUID]
        var wasReduced: Bool

        init(
            id: UUID = UUID(),
            directionRaw: String,
            modeRaw: String,
            seoulDay: String,
            wordIDs: [UUID],
            wasReduced: Bool,
            startedAt: Date = .now
        ) {
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
        var id: UUID
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
        var word: WordRecord?

        init() {
            id = UUID()
            failureCheck = 0
            activePriority = 0
            enToKoStreak = 0
            koToEnStreak = 0
            koToEnSuccessDays = []
            presentationCount = 0
        }
    }

    @Model
    final class AnonymousAggregateRecord {
        var id: UUID
        var seoulDay: String
        var modeRaw: String
        var correctCount: Int
        var incorrectCount: Int
        var unknownCount: Int
        var deletedMasteredCount: Int

        init(seoulDay: String, modeRaw: String) {
            id = UUID()
            self.seoulDay = seoulDay
            self.modeRaw = modeRaw
            correctCount = 0
            incorrectCount = 0
            unknownCount = 0
            deletedMasteredCount = 0
        }
    }

    @Model
    final class MemoryAidCacheRecord {
        var id: UUID
        var wordID: UUID
        var modelRaw: String
        var promptVersion: Int
        var contentSignature: String
        var markdown: String
        var generatedAt: Date

        init(
            wordID: UUID,
            modelRaw: String,
            promptVersion: Int,
            contentSignature: String,
            markdown: String,
            generatedAt: Date = .now
        ) {
            id = UUID()
            self.wordID = wordID
            self.modelRaw = modelRaw
            self.promptVersion = promptVersion
            self.contentSignature = contentSignature
            self.markdown = markdown
            self.generatedAt = generatedAt
        }
    }
}

enum VocabSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        VocabModelContainerFactory.schemaModels
    }
}

enum VocabSchemaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [VocabSchemaV1.self, VocabSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: VocabSchemaV1.self, toVersion: VocabSchemaV2.self)]
    }
}
