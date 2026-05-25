import Foundation
import SwiftData

struct BackupSnapshot: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let datePolicy: String
    var words: [BackupWord]
    var dailySets: [BackupDailySet]
    var sessions: [BackupSession]
    var attempts: [BackupAttempt]
    var aggregates: [BackupAggregate]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, datePolicy, words, dailySets, sessions, attempts, aggregates
    }

    init(schemaVersion: Int, exportedAt: Date, datePolicy: String, words: [BackupWord], dailySets: [BackupDailySet], sessions: [BackupSession], attempts: [BackupAttempt], aggregates: [BackupAggregate]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.datePolicy = datePolicy
        self.words = words
        self.dailySets = dailySets
        self.sessions = sessions
        self.attempts = attempts
        self.aggregates = aggregates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exportedAt = try values.decodeIfPresent(Date.self, forKey: .exportedAt) ?? .distantPast
        datePolicy = try values.decodeIfPresent(String.self, forKey: .datePolicy) ?? "Asia/Seoul"
        words = try values.decodeIfPresent([BackupWord].self, forKey: .words) ?? []
        dailySets = try values.decodeIfPresent([BackupDailySet].self, forKey: .dailySets) ?? []
        sessions = try values.decodeIfPresent([BackupSession].self, forKey: .sessions) ?? []
        attempts = try values.decodeIfPresent([BackupAttempt].self, forKey: .attempts) ?? []
        aggregates = try values.decodeIfPresent([BackupAggregate].self, forKey: .aggregates) ?? []
    }
}

struct BackupWord: Codable {
    let id: UUID
    let term: String
    let status: String
    let englishAliases: [String]
    let createdAt: Date
    let meanings: [BackupMeaning]
    let failureCheck: Int
    let activePriority: Int
    let enToKoStreak: Int
    let koToEnStreak: Int
    let koToEnSuccessDays: [String]
    let latestWrongDirection: String?
    let latestWrongAt: Date?
    let lastTestedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, term, status, englishAliases, createdAt, meanings, failureCheck, activePriority
        case enToKoStreak, koToEnStreak, koToEnSuccessDays, latestWrongDirection, latestWrongAt, lastTestedAt
    }

    init(id: UUID, term: String, status: String, englishAliases: [String], createdAt: Date, meanings: [BackupMeaning], failureCheck: Int, activePriority: Int, enToKoStreak: Int, koToEnStreak: Int, koToEnSuccessDays: [String], latestWrongDirection: String?, latestWrongAt: Date?, lastTestedAt: Date?) {
        self.id = id
        self.term = term
        self.status = status
        self.englishAliases = englishAliases
        self.createdAt = createdAt
        self.meanings = meanings
        self.failureCheck = failureCheck
        self.activePriority = activePriority
        self.enToKoStreak = enToKoStreak
        self.koToEnStreak = koToEnStreak
        self.koToEnSuccessDays = koToEnSuccessDays
        self.latestWrongDirection = latestWrongDirection
        self.latestWrongAt = latestWrongAt
        self.lastTestedAt = lastTestedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        term = try values.decode(String.self, forKey: .term)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "active"
        englishAliases = try values.decodeIfPresent([String].self, forKey: .englishAliases) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        meanings = try values.decodeIfPresent([BackupMeaning].self, forKey: .meanings) ?? []
        failureCheck = try values.decodeIfPresent(Int.self, forKey: .failureCheck) ?? 0
        activePriority = try values.decodeIfPresent(Int.self, forKey: .activePriority) ?? 0
        enToKoStreak = try values.decodeIfPresent(Int.self, forKey: .enToKoStreak) ?? 0
        koToEnStreak = try values.decodeIfPresent(Int.self, forKey: .koToEnStreak) ?? 0
        koToEnSuccessDays = try values.decodeIfPresent([String].self, forKey: .koToEnSuccessDays) ?? []
        latestWrongDirection = try values.decodeIfPresent(String.self, forKey: .latestWrongDirection)
        latestWrongAt = try values.decodeIfPresent(Date.self, forKey: .latestWrongAt)
        lastTestedAt = try values.decodeIfPresent(Date.self, forKey: .lastTestedAt)
    }
}

struct BackupMeaning: Codable {
    let id: UUID
    let text: String
    let isCore: Bool
    let aliases: [String]
    let successDays: [String]

    private enum CodingKeys: String, CodingKey { case id, text, isCore, aliases, successDays }

    init(id: UUID, text: String, isCore: Bool, aliases: [String], successDays: [String]) {
        self.id = id
        self.text = text
        self.isCore = isCore
        self.aliases = aliases
        self.successDays = successDays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try values.decode(String.self, forKey: .text)
        isCore = try values.decodeIfPresent(Bool.self, forKey: .isCore) ?? true
        aliases = try values.decodeIfPresent([String].self, forKey: .aliases) ?? []
        successDays = try values.decodeIfPresent([String].self, forKey: .successDays) ?? []
    }
}

struct BackupAttempt: Codable {
    let id: UUID
    let wordID: UUID
    let direction: String
    let mode: String
    let sessionID: UUID
    let questionIndex: Int
    let day: String
    let prompt: String
    let answer: String
    let automaticResult: String
    let finalResult: String
    let correction: String?
    let matchedMeaningID: UUID?
    let answeredAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, wordID, direction, mode, sessionID, questionIndex, day, prompt, answer
        case automaticResult, finalResult, correction, matchedMeaningID, answeredAt
    }

    init(id: UUID, wordID: UUID, direction: String, mode: String, sessionID: UUID, questionIndex: Int, day: String, prompt: String, answer: String, automaticResult: String, finalResult: String, correction: String?, matchedMeaningID: UUID?, answeredAt: Date) {
        self.id = id
        self.wordID = wordID
        self.direction = direction
        self.mode = mode
        self.sessionID = sessionID
        self.questionIndex = questionIndex
        self.day = day
        self.prompt = prompt
        self.answer = answer
        self.automaticResult = automaticResult
        self.finalResult = finalResult
        self.correction = correction
        self.matchedMeaningID = matchedMeaningID
        self.answeredAt = answeredAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        wordID = try values.decode(UUID.self, forKey: .wordID)
        direction = try values.decode(String.self, forKey: .direction)
        mode = try values.decode(String.self, forKey: .mode)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID) ?? UUID()
        questionIndex = try values.decodeIfPresent(Int.self, forKey: .questionIndex) ?? 0
        day = try values.decode(String.self, forKey: .day)
        prompt = try values.decode(String.self, forKey: .prompt)
        answer = try values.decode(String.self, forKey: .answer)
        automaticResult = try values.decode(String.self, forKey: .automaticResult)
        finalResult = try values.decode(String.self, forKey: .finalResult)
        correction = try values.decodeIfPresent(String.self, forKey: .correction)
        matchedMeaningID = try values.decodeIfPresent(UUID.self, forKey: .matchedMeaningID)
        answeredAt = try values.decodeIfPresent(Date.self, forKey: .answeredAt) ?? .distantPast
    }
}

struct BackupDailySet: Codable {
    let id: UUID
    let day: String
    let createdAt: Date
    let completedAt: Date?
    let items: [BackupDailySetItem]
}

struct BackupDailySetItem: Codable {
    let id: UUID
    let orderIndex: Int
    let entryKind: String
    let wordID: UUID
}

struct BackupSession: Codable {
    let id: UUID
    let direction: String
    let mode: String
    let day: String
    let startedAt: Date
    let completedAt: Date?
    let wordIDs: [UUID]
    let wasReduced: Bool
}

struct BackupAggregate: Codable {
    let day: String
    let mode: String
    let correctCount: Int
    let incorrectCount: Int
    let unknownCount: Int
    let deletedMasteredCount: Int
}

@ModelActor
actor BackupService {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func createManagedBackup() throws -> URL {
        let directory = try backupDirectory()
        let url = directory.appendingPathComponent("Vocab-\(ISO8601DateFormatter().string(from: .now)).json")
        try encoder.encode(snapshot()).write(to: url, options: .atomic)
        modelContext.insert(ManagedBackupRecord(fileURL: url.path))
        try modelContext.save()
        return url
    }

    func externalExportData() throws -> Data {
        try encoder.encode(snapshot())
    }

    func restore(from data: Data) throws {
        let snapshot = try decoder.decode(BackupSnapshot.self, from: data)
        guard (1...2).contains(snapshot.schemaVersion) else { throw BackupError.unsupportedSchema }
        _ = try createManagedBackup()
        try clearLearningData()
        var wordsByID: [UUID: WordRecord] = [:]
        for item in snapshot.words {
            let word = WordRecord(term: item.term, createdAt: item.createdAt)
            word.id = item.id
            word.statusRaw = item.status
            word.englishAliases = item.englishAliases
            word.reviewState = ReviewStateRecord()
            word.reviewState?.failureCheck = item.failureCheck
            word.reviewState?.activePriority = item.activePriority
            word.reviewState?.enToKoStreak = item.enToKoStreak
            word.reviewState?.koToEnStreak = item.koToEnStreak
            word.reviewState?.koToEnSuccessDays = item.koToEnSuccessDays
            word.reviewState?.latestWrongDirection = item.latestWrongDirection
            word.reviewState?.latestWrongAt = item.latestWrongAt
            word.reviewState?.lastTestedAt = item.lastTestedAt
            for value in item.meanings {
                let meaning = MeaningRecord(text: value.text, isCore: value.isCore, aliases: value.aliases)
                meaning.id = value.id
                meaning.successDays = value.successDays
                meaning.word = word
                word.meanings.append(meaning)
            }
            modelContext.insert(word)
            wordsByID[item.id] = word
        }
        for value in snapshot.dailySets {
            let set = DailySetRecord(seoulDay: value.day, createdAt: value.createdAt)
            set.id = value.id
            set.completedAt = value.completedAt
            for storedItem in value.items {
                let item = DailySetItemRecord(orderIndex: storedItem.orderIndex, entryKind: storedItem.entryKind, wordID: storedItem.wordID)
                item.id = storedItem.id
                item.set = set
                set.items.append(item)
                modelContext.insert(item)
            }
            modelContext.insert(set)
        }
        for value in snapshot.sessions {
            let session = TestSessionRecord(id: value.id, directionRaw: value.direction, modeRaw: value.mode, seoulDay: value.day, wordIDs: value.wordIDs, wasReduced: value.wasReduced, startedAt: value.startedAt)
            session.completedAt = value.completedAt
            modelContext.insert(session)
        }
        for value in snapshot.attempts {
            guard let word = wordsByID[value.wordID] else { continue }
            let matchedMeaningID = snapshot.schemaVersion >= 2 ? value.matchedMeaningID : nil
            let attempt = AttemptRecord(directionRaw: value.direction, modeRaw: value.mode, sessionID: value.sessionID, questionIndex: value.questionIndex, seoulDay: value.day, prompt: value.prompt, submittedAnswer: value.answer, automaticJudgementRaw: value.automaticResult, finalJudgementRaw: value.finalResult, matchedMeaningID: matchedMeaningID, answeredAt: value.answeredAt)
            attempt.id = value.id
            attempt.correctionRaw = value.correction
            attempt.word = word
            modelContext.insert(attempt)
        }
        for value in snapshot.aggregates {
            let aggregate = AnonymousAggregateRecord(seoulDay: value.day, modeRaw: value.mode)
            aggregate.correctCount = value.correctCount
            aggregate.incorrectCount = value.incorrectCount
            aggregate.unknownCount = value.unknownCount
            aggregate.deletedMasteredCount = value.deletedMasteredCount
            modelContext.insert(aggregate)
        }
        try modelContext.save()
    }

    func scrubManagedBackups(removing wordID: UUID) throws {
        for backup in try modelContext.fetch(FetchDescriptor<ManagedBackupRecord>()) {
            let url = URL(fileURLWithPath: backup.fileURL)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var decoded = try decoder.decode(BackupSnapshot.self, from: Data(contentsOf: url))
            decoded.words.removeAll { $0.id == wordID }
            decoded.dailySets = decoded.dailySets.map { set in
                BackupDailySet(id: set.id, day: set.day, createdAt: set.createdAt, completedAt: set.completedAt, items: set.items.filter { $0.wordID != wordID })
            }
            decoded.sessions = decoded.sessions.map { session in
                BackupSession(id: session.id, direction: session.direction, mode: session.mode, day: session.day, startedAt: session.startedAt, completedAt: session.completedAt, wordIDs: session.wordIDs.filter { $0 != wordID }, wasReduced: session.wasReduced)
            }
            decoded.attempts.removeAll { $0.wordID == wordID }
            try encoder.encode(decoded).write(to: url, options: .atomic)
        }
    }

    private func snapshot() throws -> BackupSnapshot {
        let words = try modelContext.fetch(FetchDescriptor<WordRecord>()).filter { $0.deletedAt == nil }
        let dailySets = try modelContext.fetch(FetchDescriptor<DailySetRecord>())
        let sessions = try modelContext.fetch(FetchDescriptor<TestSessionRecord>())
        let attempts = try modelContext.fetch(FetchDescriptor<AttemptRecord>())
        let aggregates = try modelContext.fetch(FetchDescriptor<AnonymousAggregateRecord>())
        return BackupSnapshot(
            schemaVersion: 2,
            exportedAt: .now,
            datePolicy: "Asia/Seoul",
            words: words.map { word in
                BackupWord(
                    id: word.id,
                    term: word.term,
                    status: word.statusRaw,
                    englishAliases: word.englishAliases,
                    createdAt: word.createdAt,
                    meanings: word.meanings.map { BackupMeaning(id: $0.id, text: $0.text, isCore: $0.isCore, aliases: $0.aliases, successDays: $0.successDays) },
                    failureCheck: word.reviewState?.failureCheck ?? 0,
                    activePriority: word.reviewState?.activePriority ?? 0,
                    enToKoStreak: word.reviewState?.enToKoStreak ?? 0,
                    koToEnStreak: word.reviewState?.koToEnStreak ?? 0,
                    koToEnSuccessDays: word.reviewState?.koToEnSuccessDays ?? [],
                    latestWrongDirection: word.reviewState?.latestWrongDirection,
                    latestWrongAt: word.reviewState?.latestWrongAt,
                    lastTestedAt: word.reviewState?.lastTestedAt
                )
            },
            dailySets: dailySets.map { set in
                BackupDailySet(
                    id: set.id,
                    day: set.seoulDay,
                    createdAt: set.createdAt,
                    completedAt: set.completedAt,
                    items: set.items.map { BackupDailySetItem(id: $0.id, orderIndex: $0.orderIndex, entryKind: $0.entryKind, wordID: $0.wordID) }
                )
            },
            sessions: sessions.map {
                BackupSession(id: $0.id, direction: $0.directionRaw, mode: $0.modeRaw, day: $0.seoulDay, startedAt: $0.startedAt, completedAt: $0.completedAt, wordIDs: $0.wordIDs, wasReduced: $0.wasReduced)
            },
            attempts: attempts.compactMap { attempt in
                guard let wordID = attempt.word?.id else { return nil }
                return BackupAttempt(id: attempt.id, wordID: wordID, direction: attempt.directionRaw, mode: attempt.modeRaw, sessionID: attempt.sessionID, questionIndex: attempt.questionIndex, day: attempt.seoulDay, prompt: attempt.prompt, answer: attempt.submittedAnswer, automaticResult: attempt.automaticJudgementRaw, finalResult: attempt.finalJudgementRaw, correction: attempt.correctionRaw, matchedMeaningID: attempt.matchedMeaningID, answeredAt: attempt.answeredAt)
            },
            aggregates: aggregates.map { BackupAggregate(day: $0.seoulDay, mode: $0.modeRaw, correctCount: $0.correctCount, incorrectCount: $0.incorrectCount, unknownCount: $0.unknownCount, deletedMasteredCount: $0.deletedMasteredCount) }
        )
    }

    private func clearLearningData() throws {
        for value in try modelContext.fetch(FetchDescriptor<WordRecord>()) { modelContext.delete(value) }
        for value in try modelContext.fetch(FetchDescriptor<DailySetRecord>()) { modelContext.delete(value) }
        for value in try modelContext.fetch(FetchDescriptor<TestSessionRecord>()) { modelContext.delete(value) }
        for value in try modelContext.fetch(FetchDescriptor<AnonymousAggregateRecord>()) { modelContext.delete(value) }
    }

    private func backupDirectory() throws -> URL {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Vocab/ManagedBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum BackupError: LocalizedError {
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "지원하지 않는 백업 형식입니다."
        }
    }
}
