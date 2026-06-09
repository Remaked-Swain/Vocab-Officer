import Foundation
import XCTest
@testable import Vocab

final class StudyPoliciesTests: XCTestCase {
    private let seoul = StudyCalendar()
    private let policy = ProgressPolicy()

    func testAnswerJudgeAcceptsNormalizedCoreMeaningAndRegisteredAlias() {
        let word = makeWord(
            spelling: "apple",
            meaning: CoreMeaning(
                text: "사과",
                aliases: [AcceptedAlias(text: " 사과 열매 ")]
            )
        )

        let answer = AnswerJudge().evaluate(
            answer: "  사과   열매. ",
            for: word,
            direction: .enToKo
        )

        XCTAssertEqual(answer.judgement, .correct)
        XCTAssertEqual(answer.matchedAnswer, " 사과 열매 ")
        XCTAssertEqual(answer.matchedMeaningID, word.coreMeanings[0].id)
        XCTAssertEqual(
            AnswerJudge().judge(answer: " APPLE ", for: word, direction: .koToEn),
            .correct
        )
    }

    func testAnswerJudgeMarksNearTypoUnknownWithSuggestion() {
        let word = makeWord(spelling: "necessary", meaning: CoreMeaning(text: "필요한"))

        let nearTypo = AnswerJudge().evaluate(
            answer: "necesary",
            for: word,
            direction: .koToEn
        )
        let wrong = AnswerJudge().evaluate(
            answer: "optional",
            for: word,
            direction: .koToEn
        )

        XCTAssertEqual(nearTypo.judgement, .unknown)
        XCTAssertEqual(nearTypo.suggestion, "necessary")
        XCTAssertEqual(wrong.judgement, .incorrect)
        XCTAssertNil(wrong.suggestion)
    }

    func testStudyCalendarChangesDayAtSeoulMidnight() {
        let beforeMidnight = date("2026-05-24T14:59:59Z")
        let afterMidnight = date("2026-05-24T15:00:00Z")

        XCTAssertEqual(seoul.dayKey(for: beforeMidnight), "2026-05-24")
        XCTAssertEqual(seoul.dayKey(for: afterMidnight), "2026-05-25")
        XCTAssertFalse(seoul.isSameDay(beforeMidnight, afterMidnight))
    }

    func testFailureCheckRemainsHistoricalAndPriorityRecoversAfterTwoCorrectAttempts() {
        let word = makeWord()
        let attempts = [
            attempt(word, .enToKo, .incorrect, "2026-05-25T00:00:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-25T00:01:00Z"),
            attempt(word, .koToEn, .correct, "2026-05-25T00:02:00Z"),
            attempt(word, .koToEn, .correct, "2026-05-25T00:03:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-25T00:04:00Z")
        ]

        let state = policy.state(for: word, attempts: attempts)

        XCTAssertEqual(state.failureCheck, 1)
        XCTAssertEqual(state.activePriority, 0)
        XCTAssertEqual(state.enToKoStreak, 0)
        XCTAssertEqual(state.koToEnStreak, 0)
        XCTAssertFalse(state.isMastered)
    }

    func testEnglishToKoreanOnlyRoutineCanReduceReviewPriority() {
        let word = makeWord()
        let attempts = [
            attempt(word, .enToKo, .incorrect, "2026-05-25T00:00:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-25T00:01:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .enToKo, .correct, "2026-05-25T00:02:00Z", matchedMeaningID: word.coreMeanings[0].id)
        ]

        let state = policy.state(for: word, attempts: attempts)

        XCTAssertEqual(state.failureCheck, 1)
        XCTAssertEqual(state.activePriority, 0)
        XCTAssertEqual(state.enToKoStreak, 0)
        XCTAssertEqual(state.koToEnStreak, 0)
    }

    func testMasteryRequiresSuccessOnThreeDistinctSeoulDaysForEachDirection() {
        let word = makeWord()
        let attempts = [
            attempt(word, .enToKo, .correct, "2026-05-22T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-22T00:01:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-23T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-23T00:01:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-24T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-24T00:01:00Z")
        ]

        let state = policy.state(for: word, attempts: attempts)

        XCTAssertTrue(state.isMastered)
        XCTAssertEqual(seoul.dayKey(for: state.masteredOn!), "2026-05-24")
        XCTAssertEqual(state.coreMeaningSuccessDays[word.coreMeanings[0].id]?.count, 3)
        XCTAssertEqual(state.koToEnSuccessDays.count, 3)
    }

    func testRecentFailureBlocksMasteryAndRaisesActivePriority() {
        let word = makeWord()
        let attempts = [
            attempt(word, .enToKo, .correct, "2026-05-22T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-22T00:01:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-23T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-23T00:01:00Z"),
            attempt(word, .enToKo, .correct, "2026-05-24T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
            attempt(word, .koToEn, .correct, "2026-05-24T00:01:00Z"),
            attempt(word, .enToKo, .incorrect, "2026-05-25T00:00:00Z")
        ]

        let state = policy.state(for: word, attempts: attempts, asOf: date("2026-05-25T01:00:00Z"))

        XCTAssertFalse(state.isMastered)
        XCTAssertNil(state.masteredOn)
        XCTAssertEqual(state.failureCheck, 1)
        XCTAssertEqual(state.activePriority, 1)
    }

    func testMixedSessionSelectsTenFromEachPoolWithoutDuplicates() {
        let targetDate = date("2026-05-25T01:00:00Z")
        let oldDate = date("2026-05-23T01:00:00Z")
        let today = (0..<12).map {
            WordProgress(word: makeWord(spelling: "today-\($0)", createdAt: targetDate))
        }
        let review = (0..<12).map { index -> WordProgress in
            let word = makeWord(spelling: "review-\(index)", createdAt: oldDate)
            return policy.progress(
                for: word,
                attempts: [attempt(word, .enToKo, .incorrect, "2026-05-24T01:00:00Z")]
            )
        }

        let selected = SessionPolicy().select(
            from: today + review,
            mode: .mixed,
            on: targetDate
        )

        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(Set(selected.map(\.id)).count, 20)
        XCTAssertEqual(selected.filter { seoul.isSameDay($0.word.createdAt, targetDate) }.count, 10)
        XCTAssertEqual(selected.filter { $0.reviewState.activePriority > 0 }.count, 10)
    }

    func testMixedSessionBackfillsMissingReviewSlotsWithTodayWords() {
        let targetDate = date("2026-05-25T01:00:00Z")
        let oldDate = date("2026-05-23T01:00:00Z")
        let today = (0..<18).map {
            WordProgress(word: makeWord(spelling: "today-\($0)", createdAt: targetDate))
        }
        let reviewedWord = makeWord(spelling: "review", createdAt: oldDate)
        let review = policy.progress(
            for: reviewedWord,
            attempts: [attempt(reviewedWord, .enToKo, .incorrect, "2026-05-24T01:00:00Z")]
        )

        let selected = SessionPolicy().select(
            from: today + [review, review],
            mode: .mixed,
            on: targetDate
        )

        XCTAssertEqual(selected.count, 19)
        XCTAssertEqual(Set(selected.map(\.id)).count, 19)
        XCTAssertEqual(selected.filter { $0.id == review.id }.count, 1)
    }

    func testMixedSessionReplacesOverlappingTodayReviewCandidatesBeforeBackfill() {
        let targetDate = date("2026-05-25T01:00:00Z")
        let oldDate = date("2026-05-23T01:00:00Z")
        let priorityToday = (0..<10).map { index -> WordProgress in
            let word = makeWord(spelling: "today-priority-\(index)", createdAt: targetDate)
            return policy.progress(
                for: word,
                attempts: [attempt(word, .enToKo, .incorrect, "2026-05-25T00:00:00Z")]
            )
        }
        let oldReview = (0..<10).map { index -> WordProgress in
            let word = makeWord(spelling: "old-review-\(index)", createdAt: oldDate)
            return policy.progress(
                for: word,
                attempts: [attempt(word, .enToKo, .incorrect, "2026-05-24T00:00:00Z")]
            )
        }

        let selected = SessionPolicy().select(
            from: priorityToday + oldReview,
            mode: .mixed,
            on: targetDate
        )

        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(Set(selected.map(\.id)).count, 20)
        XCTAssertTrue(Set(oldReview.map(\.id)).isSubset(of: Set(selected.map(\.id))))
    }

    func testReviewSessionExcludesMasteredWordEvenWhenHistoricalPriorityRemains() {
        let word = makeWord(createdAt: date("2026-05-01T00:00:00Z"))
        let wrongAttempts = (0..<3).map { index in
            attempt(word, .enToKo, .incorrect, "2026-05-01T00:0\(index):00Z")
        }
        let successAttempts = (0..<3).flatMap { index in
            let day = 2 + index
            return [
                attempt(word, .enToKo, .correct, "2026-05-0\(day)T00:00:00Z", matchedMeaningID: word.coreMeanings[0].id),
                attempt(word, .koToEn, .correct, "2026-05-0\(day)T00:01:00Z")
            ]
        }
        let progress = policy.progress(
            for: word,
            attempts: wrongAttempts + successAttempts,
            asOf: date("2026-05-25T00:00:00Z")
        )

        XCTAssertTrue(progress.reviewState.isMastered)
        XCTAssertGreaterThan(progress.reviewState.activePriority, 0)
        XCTAssertTrue(SessionPolicy().select(from: [progress], mode: .review).isEmpty)
    }

    private func makeWord(
        spelling: String = "apple",
        meaning: CoreMeaning = CoreMeaning(text: "사과"),
        createdAt: Date = Date()
    ) -> Word {
        Word(spelling: spelling, coreMeanings: [meaning], createdAt: createdAt)
    }

    private func attempt(
        _ word: Word,
        _ direction: Direction,
        _ judgement: Judgement,
        _ timestamp: String,
        matchedMeaningID: UUID? = nil
    ) -> Attempt {
        Attempt(
            wordID: word.id,
            direction: direction,
            answer: "",
            judgement: judgement,
            occurredAt: date(timestamp),
            matchedMeaningID: matchedMeaningID
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
