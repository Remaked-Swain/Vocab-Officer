import Foundation
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class SharedPresentationTests: XCTestCase {
    func testTallyCountsEachQuestionOnceAndRoundsCorrectPercentage() {
        var tally = TestSessionTally()
        XCTAssertEqual(tally.total, 0)
        XCTAssertEqual(tally.correctPercentage, 0)

        tally.record(.correct, forQuestionAt: 0)
        tally.record(.incorrect, forQuestionAt: 1)
        tally.record(.correct, forQuestionAt: 2)
        // A retried completion re-records the same question without double counting.
        tally.record(.correct, forQuestionAt: 2)

        XCTAssertEqual(tally.total, 3)
        XCTAssertEqual(tally.count(of: .correct), 2)
        XCTAssertEqual(tally.count(of: .incorrect), 1)
        XCTAssertEqual(tally.count(of: .unknown), 0)
        XCTAssertEqual(tally.correctPercentage, 67)
    }

    func testChoiceAppearanceRevealsCorrectAndSelectedWrongOnlyAfterJudgement() {
        let correct = MultipleChoiceOption(id: UUID(), label: "사과", isCorrect: true, matchedMeaningID: nil)
        let wrong = MultipleChoiceOption(id: UUID(), label: "배", isCorrect: false, matchedMeaningID: nil)
        let other = MultipleChoiceOption(id: UUID(), label: "포도", isCorrect: false, matchedMeaningID: nil)
        let selected = wrong.id.uuidString

        XCTAssertEqual(ChoiceOptionAppearance.resolve(option: correct, selectedAnswer: selected, isJudged: false), .idle)
        XCTAssertEqual(ChoiceOptionAppearance.resolve(option: wrong, selectedAnswer: selected, isJudged: false), .selected)

        XCTAssertEqual(ChoiceOptionAppearance.resolve(option: correct, selectedAnswer: selected, isJudged: true), .revealedCorrect)
        XCTAssertEqual(ChoiceOptionAppearance.resolve(option: wrong, selectedAnswer: selected, isJudged: true), .selectedIncorrect)
        XCTAssertEqual(ChoiceOptionAppearance.resolve(option: other, selectedAnswer: selected, isJudged: true), .dimmed)
    }

    func testJudgementOrderCoversEveryResultWithDistinctKoreanTitles() {
        XCTAssertEqual(FinalResult.judgementOrder, [.correct, .incorrect, .unknown])
        XCTAssertEqual(FinalResult.judgementOrder.map(\.title), ["정답", "오답", "모름"])
    }

    func testSidebarSectionsListEveryNavigationItemExactlyOnceInOrder() {
        let flattened = NavigationSection.allCases.flatMap(\.items)
        XCTAssertEqual(flattened, NavigationItem.allCases)
        XCTAssertEqual(NavigationSection.learning.items, [.test, .study, .review])
    }

    func testRegistrationGroupsAreNewestDayFirstWithWordsInRegistrationOrder() throws {
        let context = try makeContext()
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-10T03:00:00Z"))
        let later = makeWord(term: "later", createdAt: base.addingTimeInterval(60), context: context)
        let earlier = makeWord(term: "earlier", createdAt: base, context: context)
        let previousDay = makeWord(term: "older", createdAt: base.addingTimeInterval(-86_400), context: context)
        try context.save()

        let groups = RegistrationDayGroup.groups(from: [later, previousDay, earlier])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].words.map(\.term), ["earlier", "later"])
        XCTAssertEqual(groups[1].words.map(\.term), ["older"])
        XCTAssertGreaterThan(groups[0].day, groups[1].day)
    }

    func testReviewCandidatesExcludeNonActiveAndDeletedWordsAndSortByUrgency() throws {
        let context = try makeContext()
        let urgent = makeWord(term: "urgent", context: context, priority: 3, failures: 1)
        let failing = makeWord(term: "failing", context: context, priority: 1, failures: 3)
        let calm = makeWord(term: "calm", context: context, priority: 1, failures: 0)
        let settled = makeWord(term: "settled", context: context, priority: 2, failures: 0)
        settled.learningStatus = .consolidating
        let deleted = makeWord(term: "deleted", context: context, priority: 5, failures: 0)
        deleted.deletedAt = .now
        try context.save()

        let states = [calm, deleted, settled, failing, urgent].compactMap(\.reviewState)
        let candidates = ReviewCandidateList.words(from: states)

        XCTAssertEqual(candidates.map(\.term), ["urgent", "failing", "calm"])
    }

    private func makeWord(
        term: String,
        createdAt: Date = .now,
        context: ModelContext,
        priority: Int? = nil,
        failures: Int = 0
    ) -> WordRecord {
        let word = WordRecord(term: term, createdAt: createdAt)
        context.insert(word)
        if let priority {
            let state = ReviewStateRecord()
            state.activePriority = priority
            state.failureCheck = failures
            context.insert(state)
            word.reviewState = state
        }
        return word
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
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }
}
