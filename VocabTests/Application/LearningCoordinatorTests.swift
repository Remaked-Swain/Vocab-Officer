import Foundation
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class LearningCoordinatorTests: XCTestCase {
    func testDailySetRejectsNinetyNineAndAcceptsExactlyOneHundredWords() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)

        XCTAssertThrowsError(try coordinator.saveDailySet(drafts(count: 99), date: testDate))

        try coordinator.saveDailySet(drafts(count: 100), date: testDate)

        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).count, 100)
        let set = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first)
        XCTAssertEqual(set.items.count, 100)
        XCTAssertTrue(set.isComplete)
    }

    func testTodaySessionPrioritizesWordsNotPreviouslyPresentedThatDay() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)

        let first = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate).0
        let second = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate).0

        XCTAssertEqual(first.wordIDs.count, 20)
        XCTAssertEqual(second.wordIDs.count, 20)
        XCTAssertTrue(Set(first.wordIDs).isDisjoint(with: Set(second.wordIDs)))
    }

    func testInvalidMeaningInCompleteSetDoesNotPartiallyInsertWords() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        var invalidDrafts = drafts(count: 100)
        invalidDrafts[99].meanings = "  "

        XCTAssertThrowsError(try coordinator.saveDailySet(invalidDrafts, date: testDate))

        XCTAssertTrue(try context.fetch(FetchDescriptor<WordRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailySetRecord>()).isEmpty)
    }

    func testCorrectedKoreanAnswerAdvancesOnlyConfirmedCoreMeaning() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let question = try XCTUnwrap(generated.1.first)
        let originalMeaningID = try XCTUnwrap(question.word.meanings.first?.id)
        let secondMeaning = MeaningRecord(text: "추가 뜻", isCore: true)
        secondMeaning.word = question.word
        question.word.meanings.append(secondMeaning)

        try coordinator.commit(answer: "사용자 보정", result: .correct, automatic: .incorrect, matchedMeaningID: secondMeaning.id, question: question, session: generated.0, correction: "oneTimeCorrection", date: testDate)

        XCTAssertTrue(secondMeaning.successDays.contains(SeoulCalendar.day(for: testDate)))
        XCTAssertTrue(try XCTUnwrap(question.word.meanings.first { $0.id == originalMeaningID }).successDays.isEmpty)
    }

    func testMasteredDeletionRemovesIdentifiableSessionAndDailySetLinks() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let session = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate).0
        let deletedID = try XCTUnwrap(session.wordIDs.first)
        let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first { $0.id == deletedID })
        word.statusRaw = "mastered"

        try coordinator.deleteMastered(word)

        XCTAssertFalse(try context.fetch(FetchDescriptor<WordRecord>()).contains { $0.id == deletedID })
        XCTAssertFalse(try context.fetch(FetchDescriptor<TestSessionRecord>()).flatMap(\.wordIDs).contains(deletedID))
        XCTAssertFalse(try context.fetch(FetchDescriptor<DailySetRecord>()).flatMap(\.items).contains { $0.wordID == deletedID })
        XCTAssertEqual(try context.fetch(FetchDescriptor<AnonymousAggregateRecord>()).reduce(0) { $0 + $1.deletedMasteredCount }, 1)
    }

    func testJSONRestoreReplacesWordsSessionsAttemptsAndDailySetData() async throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let firstQuestion = try XCTUnwrap(generated.1.first)
        let originalCreatedAt = firstQuestion.word.createdAt
        let originalMeaningID = firstQuestion.word.meanings[0].id
        try coordinator.commit(answer: firstQuestion.word.meanings[0].text, result: .correct, automatic: .correct, matchedMeaningID: firstQuestion.word.meanings[0].id, question: firstQuestion, session: generated.0, date: testDate)
        let service = BackupService(modelContainer: context.container)
        let data = try await service.externalExportData()

        let extra = WordRecord(term: "temporary")
        context.insert(extra)
        try context.save()
        try await service.restore(from: data)
        let verified = ModelContext(context.container)

        XCTAssertEqual(try verified.fetch(FetchDescriptor<WordRecord>()).count, 100)
        XCTAssertEqual(try verified.fetch(FetchDescriptor<DailySetRecord>()).count, 1)
        XCTAssertEqual(try verified.fetch(FetchDescriptor<TestSessionRecord>()).count, 1)
        let restoredAttempt = try XCTUnwrap(verified.fetch(FetchDescriptor<AttemptRecord>()).first)
        let restoredWord = try XCTUnwrap(restoredAttempt.word)
        XCTAssertEqual(restoredWord.createdAt, originalCreatedAt)
        XCTAssertEqual(restoredWord.meanings[0].id, originalMeaningID)
        XCTAssertEqual(restoredAttempt.matchedMeaningID, originalMeaningID)
        XCTAssertFalse(try verified.fetch(FetchDescriptor<WordRecord>()).contains { $0.term == "temporary" })
    }

    func testLegacySchemaOneBackupRestoresWithoutStaleMeaningReference() async throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let question = try XCTUnwrap(generated.1.first)
        try coordinator.commit(answer: question.word.meanings[0].text, result: .correct, automatic: .correct, matchedMeaningID: question.word.meanings[0].id, question: question, session: generated.0, date: testDate)
        let service = BackupService(modelContainer: context.container)
        let current = try await service.externalExportData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        json["schemaVersion"] = 1
        json["dailySets"] = nil
        json["sessions"] = nil
        json["words"] = (try XCTUnwrap(json["words"] as? [[String: Any]])).map { stored in
            var word = stored
            word["createdAt"] = nil
            word["meanings"] = ((word["meanings"] as? [[String: Any]]) ?? []).map { storedMeaning in
                var meaning = storedMeaning
                meaning["id"] = nil
                return meaning
            }
            return word
        }
        json["attempts"] = ((json["attempts"] as? [[String: Any]]) ?? []).map { storedAttempt in
            var attempt = storedAttempt
            attempt["id"] = nil
            attempt["sessionID"] = nil
            attempt["questionIndex"] = nil
            attempt["answeredAt"] = nil
            return attempt
        }

        try await service.restore(from: JSONSerialization.data(withJSONObject: json))
        let verified = ModelContext(context.container)
        let restoredAttempt = try XCTUnwrap(verified.fetch(FetchDescriptor<AttemptRecord>()).first)

        XCTAssertNil(restoredAttempt.matchedMeaningID)
        XCTAssertEqual(try verified.fetch(FetchDescriptor<WordRecord>()).count, 100)
    }

    private var testDate: Date {
        ISO8601DateFormatter().date(from: "2026-05-25T01:00:00Z")!
    }

    private func drafts(count: Int) -> [WordDraft] {
        (0..<count).map { WordDraft(term: "term-\($0)", meanings: "뜻-\($0)") }
    }

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            WordRecord.self,
            MeaningRecord.self,
            DailySetRecord.self,
            DailySetItemRecord.self,
            TestSessionRecord.self,
            AttemptRecord.self,
            ReviewStateRecord.self,
            AnonymousAggregateRecord.self,
            ManagedBackupRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }
}
