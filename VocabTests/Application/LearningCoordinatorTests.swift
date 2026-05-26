import Foundation
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class LearningCoordinatorTests: XCTestCase {
    func testPasteParserPreservesHyphenatedTermAndMultipleMeanings() throws {
        let drafts = try DailyIntakePasteParser.parse(
            """
            ```markdown
            0001-well-known-널리 알려진
            sample\t표본, 예시
            ```
            """
        )

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].term, "well-known")
        XCTAssertEqual(drafts[0].meanings, "널리 알려진")
        XCTAssertEqual(drafts[1].term, "sample")
        XCTAssertEqual(drafts[1].meanings, "표본, 예시")
    }

    func testPastedOneHundredWordsUseAtomicDailySetSave() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let input = (0..<100).map { index in
            String(format: "%04d-term%d-뜻%d, 추가뜻%d", index + 1, index, index, index)
        }.joined(separator: "\n")

        let drafts = try DailyIntakePasteParser.parse(input)
        try coordinator.saveDailySet(drafts, date: testDate)

        XCTAssertEqual(drafts.count, 100)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).count, 100)
        XCTAssertEqual(try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first).meanings.count, 2)
    }

    func testPasteParserRejectsMalformedRow() {
        XCTAssertThrowsError(try DailyIntakePasteParser.parse("형식이 없는 단어 행"))
    }

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

    func testOlderUntestedSetCanBeSelectedAfterNewerSetExists() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let nextDate = ISO8601DateFormatter().date(from: "2026-05-26T01:00:00Z")!
        let followingDate = ISO8601DateFormatter().date(from: "2026-05-27T01:00:00Z")!
        try coordinator.saveDailySet(drafts(count: 100, prefix: "older"), date: testDate)
        try coordinator.saveDailySet(drafts(count: 100, prefix: "newer"), date: nextDate)
        let olderSet = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first { $0.seoulDay == "2026-05-25" })

        let generated = try coordinator.generateSession(mode: .set, direction: .enToKo, setID: olderSet.id, date: nextDate)
        let second = try coordinator.generateSession(mode: .set, direction: .enToKo, setID: olderSet.id, date: followingDate)

        XCTAssertEqual(generated.1.count, 20)
        XCTAssertTrue(generated.1.allSatisfy { $0.word.term.hasPrefix("older-") })
        XCTAssertEqual(second.1.count, 20)
        XCTAssertTrue(Set(generated.1.map(\.word.id)).isDisjoint(with: Set(second.1.map(\.word.id))))
    }

    func testEmptyReviewPoolDoesNotPersistEmptySession() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)

        XCTAssertThrowsError(try coordinator.generateSession(mode: .review, direction: .enToKo, date: testDate))
        XCTAssertTrue(try context.fetch(FetchDescriptor<TestSessionRecord>()).isEmpty)
    }

    func testRuntimeJudgeAcceptsAnyStoredKoreanMeaning() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        var values = drafts(count: 100, prefix: "entry")
        values[0] = WordDraft(term: "example", meanings: "첫 의미, 둘째 의미, 셋째 의미")
        try coordinator.saveDailySet(values, date: testDate)
        let set = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first)
        let generated = try coordinator.generateSession(mode: .set, direction: .enToKo, setID: set.id, date: testDate)
        let question = try XCTUnwrap(generated.1.first { $0.word.term == "example" })

        let result = coordinator.judge(answer: "둘째 의미", for: question)

        XCTAssertEqual(result.automaticResult, .correct)
        XCTAssertEqual(result.matchedMeaningID, question.word.meanings.first { $0.text == "둘째 의미" }?.id)
    }

    func testDelimitedLegacyMeaningCannotEarnAutomaticOrCorrectedMasteryCredit() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let question = try XCTUnwrap(generated.1.first)
        let legacyMeaning = MeaningRecord(text: "첫 의미, 둘째 의미", isCore: true)
        legacyMeaning.word = question.word
        question.word.meanings.append(legacyMeaning)

        let result = coordinator.judge(answer: "첫 의미, 둘째 의미", for: question)
        XCTAssertEqual(result.automaticResult, .incorrect)

        try coordinator.commit(answer: "사용자 보정", result: .correct, automatic: .incorrect, matchedMeaningID: legacyMeaning.id, question: question, session: generated.0, correction: "oneTimeCorrection", date: testDate)

        XCTAssertTrue(legacyMeaning.successDays.isEmpty)
        XCTAssertEqual(question.word.statusRaw, "active")
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

    private var testDate: Date {
        ISO8601DateFormatter().date(from: "2026-05-25T01:00:00Z")!
    }

    private func drafts(count: Int, prefix: String = "term") -> [WordDraft] {
        (0..<count).map { WordDraft(term: "\(prefix)-\($0)", meanings: "뜻-\($0)") }
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
            AnonymousAggregateRecord.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }
}
