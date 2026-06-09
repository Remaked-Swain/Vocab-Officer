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
            0526-teenager-10대
            10001-long-term-장기간의
            sample\t표본, 예시
            ```
            """
        )

        XCTAssertEqual(drafts.count, 4)
        XCTAssertEqual(drafts[0].term, "well-known")
        XCTAssertEqual(drafts[0].meanings, "널리 알려진")
        XCTAssertEqual(drafts[1].term, "teenager")
        XCTAssertEqual(drafts[1].meanings, "10대")
        XCTAssertEqual(drafts[2].term, "long-term")
        XCTAssertEqual(drafts[2].meanings, "장기간의")
        XCTAssertEqual(drafts[3].term, "sample")
        XCTAssertEqual(drafts[3].meanings, "표본, 예시")
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

    func testRepeatedHeadwordsReuseSingleWordAndMergeNewMeanings() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let nextDate = ISO8601DateFormatter().date(from: "2026-05-26T01:00:00Z")!
        var firstDay = drafts(count: 100, prefix: "day1")
        firstDay[0] = WordDraft(term: "shared", meanings: "기존뜻")
        var secondDay = drafts(count: 100, prefix: "day2")
        secondDay[10] = WordDraft(term: "shared", meanings: "기존뜻, 새뜻")
        secondDay[11] = WordDraft(term: "SHARED", meanings: "또다른뜻")

        try coordinator.saveDailySet(firstDay, date: testDate)
        try coordinator.saveDailySet(secondDay, date: nextDate)

        let words = try context.fetch(FetchDescriptor<WordRecord>())
        let shared = try XCTUnwrap(words.first { $0.normalizedTerm == "shared" })
        XCTAssertEqual(words.count, 198)
        XCTAssertEqual(Set(shared.meanings.map(\.text)), ["기존뜻", "새뜻", "또다른뜻"])

        let secondSet = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first { $0.seoulDay == "2026-05-26" })
        XCTAssertEqual(secondSet.items.count, 100)
        XCTAssertEqual(secondSet.items.filter { $0.wordID == shared.id }.count, 2)

        let generated = try coordinator.generateSession(mode: .set, direction: .enToKo, setID: secondSet.id, date: nextDate)
        XCTAssertEqual(generated.1.count, 20)
        XCTAssertEqual(Set(generated.1.map(\.word.id)).count, generated.1.count)
    }

    func testLooseWordIsSavedOutsideDailySetOnSameDay() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let set = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first)

        let loose = try coordinator.addLooseWord(term: "bonus", meaningsText: "보충뜻", date: testDate)

        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).count, 101)
        XCTAssertEqual(set.items.count, 100)
        XCTAssertFalse(try context.fetch(FetchDescriptor<DailySetItemRecord>()).contains { $0.wordID == loose.id })
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        XCTAssertFalse(generated.1.contains { $0.word.id == loose.id })
    }

    func testLooseDuplicateHeadwordMergesMeaningsWithoutAddingSetItem() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let existing = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first { $0.term == "term-0" })
        let beforeItemCount = try context.fetch(FetchDescriptor<DailySetItemRecord>()).count

        let result = try coordinator.addLooseWord(term: "TERM-0", meaningsText: "뜻-0, 보충뜻", date: testDate)

        XCTAssertEqual(result.id, existing.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).count, 100)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailySetItemRecord>()).count, beforeItemCount)
        XCTAssertEqual(Set(existing.meanings.map(\.text)), ["뜻-0", "보충뜻"])
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

    func testReviewSessionPrefersLessPresentedWordsWithinSamePriority() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let words = try context.fetch(FetchDescriptor<WordRecord>())
        for word in words {
            let state = word.reviewState ?? ReviewStateRecord()
            state.failureCheck = 1
            state.activePriority = 1
            word.reviewState = state
        }
        let previouslyPresentedIDs = Array(words.prefix(20).map(\.id))
        context.insert(TestSessionRecord(directionRaw: PracticeDirection.enToKo.rawValue, modeRaw: SessionMode.review.rawValue, seoulDay: "2026-05-24", wordIDs: previouslyPresentedIDs, wasReduced: false, startedAt: testDate.addingTimeInterval(-86_400)))
        try context.save()

        let generated = try coordinator.generateSession(mode: .review, direction: .enToKo, date: testDate)

        XCTAssertEqual(generated.1.count, 20)
        XCTAssertTrue(Set(generated.1.map(\.word.id)).isDisjoint(with: Set(previouslyPresentedIDs)))
    }

    func testMixedSessionKeepsTodayMajorityAndIncludesHistoricalUntestedWords() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let nextDate = ISO8601DateFormatter().date(from: "2026-05-26T01:00:00Z")!
        try coordinator.saveDailySet(drafts(count: 100, prefix: "older"), date: testDate)
        try coordinator.saveDailySet(drafts(count: 100, prefix: "today"), date: nextDate)
        let words = try context.fetch(FetchDescriptor<WordRecord>())
        let todayIDs = Set(try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first { $0.seoulDay == "2026-05-26" }).items.map(\.wordID))
        for word in words.filter({ todayIDs.contains($0.id) }).prefix(8) {
            let state = word.reviewState ?? ReviewStateRecord()
            state.failureCheck = 1
            state.activePriority = 1
            word.reviewState = state
        }

        let generated = try coordinator.generateSession(mode: .mixed, direction: .enToKo, date: nextDate)
        let selectedIDs = Set(generated.1.map(\.word.id))

        XCTAssertEqual(generated.1.count, 20)
        XCTAssertGreaterThanOrEqual(generated.1.filter { $0.word.term.hasPrefix("today-") }.count, 12)
        XCTAssertGreaterThanOrEqual(generated.1.filter { $0.word.term.hasPrefix("older-") }.count, 1)
        XCTAssertEqual(selectedIDs.count, 20)
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

    func testEmptyReviewPoolFallsBackToLatestDailySet() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let olderDate = ISO8601DateFormatter().date(from: "2026-05-24T01:00:00Z")!
        try coordinator.saveDailySet(drafts(count: 100, prefix: "older"), date: olderDate)
        try coordinator.saveDailySet(drafts(count: 100, prefix: "latest"), date: testDate)

        let generated = try coordinator.generateSession(mode: .review, direction: .enToKo, date: testDate.addingTimeInterval(86_400))

        XCTAssertEqual(generated.1.count, 20)
        XCTAssertTrue(generated.1.allSatisfy { $0.word.term.hasPrefix("latest-") })
        XCTAssertEqual(try context.fetch(FetchDescriptor<TestSessionRecord>()).count, 1)
    }

    func testRuntimeJudgeAcceptsAnyStoredKoreanMeaning() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        var values = drafts(count: 100, prefix: "entry")
        values[0] = WordDraft(term: "example", meanings: "첫 의미, 둘째 의미, 셋째 의미")
        try coordinator.saveDailySet(values, date: testDate)
        let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first { $0.term == "example" })
        let question = SessionQuestion(word: word, direction: .enToKo, index: 0)

        let result = coordinator.judge(answer: "둘째 의미", for: question)

        XCTAssertEqual(result.automaticResult, .correct)
        XCTAssertEqual(result.matchedMeaningID, question.word.meanings.first { $0.text == "둘째 의미" }?.id)
    }

    func testEnglishToKoreanCorrectStreakRemovesWordFromReviewPool() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let question = try XCTUnwrap(generated.1.first)
        let meaningID = try XCTUnwrap(question.word.meanings.first?.id)

        try coordinator.commit(answer: "오답", result: .incorrect, automatic: .incorrect, matchedMeaningID: nil, question: question, session: generated.0, date: testDate)
        XCTAssertEqual(question.word.reviewState?.failureCheck, 1)
        XCTAssertEqual(question.word.reviewState?.activePriority, 1)

        for offset in 1...3 {
            let correctDate = testDate.addingTimeInterval(TimeInterval(offset * 60))
            try coordinator.commit(answer: "뜻-0", result: .correct, automatic: .correct, matchedMeaningID: meaningID, question: question, session: generated.0, date: correctDate)
        }

        XCTAssertEqual(question.word.reviewState?.failureCheck, 1)
        XCTAssertEqual(question.word.reviewState?.activePriority, 0)
        let review = try coordinator.generateSession(mode: .review, direction: .enToKo, date: testDate)
        XCTAssertFalse(review.1.contains { $0.word.id == question.word.id })
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

    func testDirectWordDeletionRemovesLinksAndAttempts() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: testDate)
        let question = try XCTUnwrap(generated.1.first)

        try coordinator.commit(answer: "오답", result: .incorrect, automatic: .incorrect, matchedMeaningID: nil, question: question, session: generated.0, date: testDate)
        try coordinator.deleteWords([question.word])

        XCTAssertFalse(try context.fetch(FetchDescriptor<WordRecord>()).contains { $0.id == question.word.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<DailySetRecord>()).flatMap(\.items).contains { $0.wordID == question.word.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<TestSessionRecord>()).flatMap(\.wordIDs).contains(question.word.id))
        XCTAssertTrue(try context.fetch(FetchDescriptor<AttemptRecord>()).isEmpty)
    }

    func testDiscardDailySetDeletesOnlyWordsUniqueToThatSet() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let nextDate = ISO8601DateFormatter().date(from: "2026-05-26T01:00:00Z")!
        var firstDay = drafts(count: 100, prefix: "day1")
        firstDay[0] = WordDraft(term: "shared", meanings: "공유뜻")
        var secondDay = drafts(count: 100, prefix: "day2")
        secondDay[0] = WordDraft(term: "shared", meanings: "공유뜻, 추가뜻")
        try coordinator.saveDailySet(firstDay, date: testDate)
        try coordinator.saveDailySet(secondDay, date: nextDate)
        let discardedSet = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetRecord>()).first { $0.seoulDay == "2026-05-26" })
        let shared = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first { $0.term == "shared" })

        try coordinator.discardDailySet(discardedSet)

        XCTAssertNil(try context.fetch(FetchDescriptor<DailySetRecord>()).first { $0.seoulDay == "2026-05-26" })
        XCTAssertNotNil(try context.fetch(FetchDescriptor<WordRecord>()).first { $0.id == shared.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<WordRecord>()).contains { $0.term.hasPrefix("day2-") })
        XCTAssertEqual(try context.fetch(FetchDescriptor<DailySetRecord>()).first?.items.count, 100)
    }


    func testTodaySessionFallsBackToLatestSetWhenTodaySetIsMissing() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        let olderDate = ISO8601DateFormatter().date(from: "2026-05-24T01:00:00Z")!
        let latestDate = ISO8601DateFormatter().date(from: "2026-05-26T01:00:00Z")!
        let targetDate = ISO8601DateFormatter().date(from: "2026-05-27T01:00:00Z")!
        try coordinator.saveDailySet(drafts(count: 100, prefix: "older"), date: olderDate)
        try coordinator.saveDailySet(drafts(count: 100, prefix: "latest"), date: latestDate)

        let generated = try coordinator.generateSession(mode: .today, direction: .enToKo, date: targetDate)

        XCTAssertEqual(generated.1.count, 20)
        XCTAssertTrue(generated.1.allSatisfy { $0.word.term.hasPrefix("latest-") })
    }

    func testSOTWordEditUpdatesCanonicalWordWithoutCreatingDuplicate() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100, prefix: "entry"), date: testDate)
        let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first { $0.term == "entry-0" })
        let originalID = word.id
        let linkedItem = try XCTUnwrap(context.fetch(FetchDescriptor<DailySetItemRecord>()).first { $0.wordID == originalID })
        let duplicateMeaning = MeaningRecord(text: "뜻-0")
        duplicateMeaning.word = word
        word.meanings.append(duplicateMeaning)
        try context.save()

        try coordinator.updateWord(word, term: "corrected", meaningsText: "수정뜻, 추가뜻")

        XCTAssertEqual(word.id, originalID)
        XCTAssertEqual(word.term, "corrected")
        XCTAssertEqual(word.normalizedTerm, "corrected")
        XCTAssertEqual(linkedItem.wordID, originalID)
        XCTAssertEqual(Set(word.meanings.map(\.text)), ["수정뜻", "추가뜻"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WordRecord>()).filter { $0.normalizedTerm == "corrected" }.count, 1)
    }

    func testCompactionEventuallyRemovesOldAttemptsAndSessions() throws {
        let context = try makeContext()
        let coordinator = LearningCoordinator(context: context)
        try coordinator.saveDailySet(drafts(count: 100), date: testDate)
        let word = try XCTUnwrap(context.fetch(FetchDescriptor<WordRecord>()).first)
        let now = ISO8601DateFormatter().date(from: "2027-06-01T01:00:00Z")!
        for index in 0..<45 {
            let answeredAt = now.addingTimeInterval(-Double(500 + index) * 86_400)
            let attempt = AttemptRecord(directionRaw: PracticeDirection.enToKo.rawValue, modeRaw: SessionMode.today.rawValue, sessionID: UUID(), questionIndex: index, seoulDay: SeoulCalendar.day(for: answeredAt), prompt: "old-correct-\(index)", submittedAnswer: "답", automaticJudgementRaw: FinalResult.correct.rawValue, finalJudgementRaw: FinalResult.correct.rawValue, matchedMeaningID: nil, answeredAt: answeredAt)
            attempt.word = word
            word.attempts.append(attempt)
            context.insert(attempt)
        }
        let failedAt = now.addingTimeInterval(-700 * 86_400)
        let oldFailure = AttemptRecord(directionRaw: PracticeDirection.enToKo.rawValue, modeRaw: SessionMode.today.rawValue, sessionID: UUID(), questionIndex: 99, seoulDay: SeoulCalendar.day(for: failedAt), prompt: "expired-failure", submittedAnswer: "오답", automaticJudgementRaw: FinalResult.incorrect.rawValue, finalJudgementRaw: FinalResult.incorrect.rawValue, matchedMeaningID: nil, answeredAt: failedAt)
        oldFailure.word = word
        word.attempts.append(oldFailure)
        context.insert(oldFailure)
        context.insert(TestSessionRecord(directionRaw: PracticeDirection.enToKo.rawValue, modeRaw: SessionMode.today.rawValue, seoulDay: "2026-01-01", wordIDs: [word.id], wasReduced: true, startedAt: now.addingTimeInterval(-220 * 86_400)))
        context.insert(TestSessionRecord(directionRaw: PracticeDirection.enToKo.rawValue, modeRaw: SessionMode.today.rawValue, seoulDay: "2027-05-01", wordIDs: [word.id], wasReduced: true, startedAt: now.addingTimeInterval(-30 * 86_400)))
        try context.save()

        try coordinator.compactLearningHistory(now: now)

        let attempts = try context.fetch(FetchDescriptor<AttemptRecord>())
        XCTAssertEqual(attempts.count, LearningHistoryRetentionPolicy.recentAttemptLimitPerWord)
        XCTAssertFalse(attempts.contains { $0.prompt == "expired-failure" })
        let sessions = try context.fetch(FetchDescriptor<TestSessionRecord>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.seoulDay, "2027-05-01")
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
