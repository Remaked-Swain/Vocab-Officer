import Foundation
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class VocabLibraryReadModelTests: XCTestCase {
    func testStudyCardsGroupNondeletedWordsWithActiveMeaningsByRegistrationDay() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-10T03:00:00Z"))
        let later = makeWord("later", meanings: ["나중"], createdAt: base.addingTimeInterval(60), in: context)
        let retiredMeaning = MeaningRecord(text: "지운 뜻")
        retiredMeaning.deletedAt = base
        later.appendMeaning(retiredMeaning)
        _ = makeWord("earlier", meanings: ["먼저", "앞"], createdAt: base, in: context)
        _ = makeWord("older", meanings: ["예전"], createdAt: base.addingTimeInterval(-86_400), in: context)
        let deleted = makeWord("deleted", meanings: ["삭제"], createdAt: base, in: context)
        deleted.deletedAt = base
        try context.save()

        let snapshot = try await VocabLibraryReadModel.studyCards(in: container)

        XCTAssertEqual(snapshot.wordCount, 3)
        XCTAssertEqual(snapshot.groups.map { $0.words.map(\.term) }, [["earlier", "later"], ["older"]])
        // A to-many relationship has no stored order, so compare meaning sets.
        XCTAssertEqual(snapshot.groups[0].words.map { Set($0.meanings) }, [["먼저", "앞"], ["나중"]])
    }

    func testConsolidatingWordsIncludeLegacyStatusesInHeadwordOrder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        makeWord("zeta", in: context).learningStatus = .consolidating
        makeWord("legacy", in: context).statusRaw = "mastered"
        makeWord("bridged", in: context).markLegacyMasteryAsConsolidating(at: .now)
        _ = makeWord("learning", in: context)
        makeWord("retired", in: context).learningStatus = .mastered
        let deleted = makeWord("deleted", in: context)
        deleted.learningStatus = .consolidating
        deleted.deletedAt = .now
        try context.save()

        let words = try await VocabLibraryReadModel.consolidatingWords(in: container)

        XCTAssertEqual(words.map(\.term), ["bridged", "legacy", "zeta"])
        XCTAssertTrue(words.allSatisfy { $0.status == .consolidating })
    }

    func testReviewCandidatesKeepSharedUrgencyOrderAndSkipInactiveWords() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        makeWord("calm", in: context).reviewState = makeState(priority: 1, failures: 0, in: context)
        makeWord("urgent", in: context).reviewState = makeState(priority: 3, failures: 1, in: context)
        makeWord("failing", in: context).reviewState = makeState(priority: 1, failures: 3, in: context)
        let settled = makeWord("settled", in: context)
        settled.reviewState = makeState(priority: 4, failures: 0, in: context)
        settled.learningStatus = .consolidating
        _ = makeWord("unreviewed", in: context)
        let removed = makeWord("removed", in: context)
        removed.reviewState = makeState(priority: 5, failures: 0, in: context)
        removed.deletedAt = .now
        try context.save()

        let candidates = try await VocabLibraryReadModel.reviewCandidates(in: container)

        XCTAssertEqual(candidates.map(\.term), ["urgent", "failing", "calm"])
        XCTAssertEqual(candidates.map(\.activePriority), [3, 1, 1])
    }

    func testLibraryPagesBrowseByHeadwordAndKeepSearchMatchOrder() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for term in ["delta", "alpha", "echo", "charlie", "bravo"] {
            _ = makeWord(term, meanings: ["공통 뜻"], in: context)
        }
        makeWord("ghost", meanings: ["공통 뜻"], in: context).deletedAt = .now
        try context.save()

        let browseIDs = try await VocabLibraryReadModel.librarySearchIDs(for: "  ", in: container)
        XCTAssertNil(browseIDs)
        let first = try await VocabLibraryReadModel.libraryWords(matching: nil, offset: 0, limit: 2, in: container)
        let last = try await VocabLibraryReadModel.libraryWords(matching: nil, offset: 4, limit: 2, in: container)
        XCTAssertEqual(first.map(\.term), ["alpha", "bravo"])
        XCTAssertEqual(last.map(\.term), ["echo"])

        let searchIDs = try await VocabLibraryReadModel.librarySearchIDs(for: "공통", in: container)
        let matches = try await VocabLibraryReadModel.libraryWords(
            matching: searchIDs,
            offset: 1,
            limit: 3,
            in: container
        )
        XCTAssertEqual(searchIDs?.count, 5)
        XCTAssertEqual(matches.map(\.term), ["bravo", "charlie", "delta"])
        let pastEnd = try await VocabLibraryReadModel.libraryWords(
            matching: searchIDs,
            offset: 5,
            limit: 3,
            in: container
        )
        XCTAssertTrue(pastEnd.isEmpty)
    }

    func testAttemptHistoryPagesNewestFirstAndCountsOnlyNondeletedAttempts() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            context.insert(makeAttempt(prompt: "p\(index)", answeredAt: base.addingTimeInterval(Double(index))))
        }
        let deleted = makeAttempt(prompt: "gone", answeredAt: base.addingTimeInterval(10))
        deleted.deletedAt = base
        context.insert(deleted)
        try context.save()

        let firstPage = try await VocabLibraryReadModel.attemptHistory(offset: 0, limit: 2, in: container)
        let secondPage = try await VocabLibraryReadModel.attemptHistory(offset: 2, limit: 2, in: container)

        XCTAssertEqual(firstPage.totalCount, 5)
        XCTAssertEqual(firstPage.attempts.map(\.prompt), ["p4", "p3"])
        XCTAssertEqual(secondPage.attempts.map(\.prompt), ["p2", "p1"])
    }

    func testEachLoadReadsChangesSavedAfterAnEarlierLoad() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let word = makeWord("apple", meanings: ["사과"], in: context)
        try context.save()
        let before = try await VocabLibraryReadModel.libraryWords(matching: nil, offset: 0, limit: 10, in: container)

        word.replaceMeanings(with: [MeaningRecord(text: "능금")])
        word.learningStatus = .consolidating
        try context.save()
        let after = try await VocabLibraryReadModel.libraryWords(matching: nil, offset: 0, limit: 10, in: container)

        XCTAssertEqual(before.map(\.meaningsText), ["사과"])
        XCTAssertEqual(after.map(\.meaningsText), ["능금"])
        XCTAssertEqual(after.map(\.status), [.consolidating])
    }

    func testActiveWordLookupSkipsDeletedWords() throws {
        let context = ModelContext(try makeContainer())
        let kept = makeWord("kept", in: context)
        let deleted = makeWord("deleted", in: context)
        deleted.deletedAt = .now
        try context.save()

        XCTAssertEqual(try context.activeWord(id: kept.id)?.term, "kept")
        XCTAssertNil(try context.activeWord(id: deleted.id))
    }

    @discardableResult
    private func makeWord(
        _ term: String,
        meanings: [String] = ["뜻"],
        createdAt: Date = .now,
        in context: ModelContext
    ) -> WordRecord {
        let word = WordRecord(term: term, createdAt: createdAt)
        context.insert(word)
        for meaning in meanings {
            word.appendMeaning(MeaningRecord(text: meaning))
        }
        return word
    }

    private func makeState(priority: Int, failures: Int, in context: ModelContext) -> ReviewStateRecord {
        let state = ReviewStateRecord()
        state.activePriority = priority
        state.failureCheck = failures
        context.insert(state)
        return state
    }

    private func makeAttempt(prompt: String, answeredAt: Date) -> AttemptRecord {
        AttemptRecord(
            directionRaw: PracticeDirection.enToKo.rawValue,
            modeRaw: SessionMode.review.rawValue,
            sessionID: UUID(),
            questionIndex: 0,
            seoulDay: SeoulCalendar.day(for: answeredAt),
            prompt: prompt,
            submittedAnswer: "",
            automaticJudgementRaw: FinalResult.correct.rawValue,
            finalJudgementRaw: FinalResult.correct.rawValue,
            matchedMeaningID: nil,
            answeredAt: answeredAt
        )
    }

    private func makeContainer() throws -> ModelContainer {
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
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
