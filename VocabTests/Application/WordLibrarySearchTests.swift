import Foundation
import SwiftData
import XCTest
@testable import Vocab

@MainActor
final class WordLibrarySearchTests: XCTestCase {
    func testSearchMatchesEnglishTermAndKoreanMeaningWithoutDuplicates() throws {
        let context = try makeContext()

        let apple = makeWord(term: "apple", meanings: ["사과"], context: context)
        _ = makeWord(term: "banana", meanings: ["바나나"], context: context)
        try context.save()
        let search = WordLibrarySearch(context: context)

        let englishIDs = try XCTUnwrap(search.resolveWordIDs(for: "app"))
        XCTAssertEqual(englishIDs, [apple.id])

        let koreanIDs = try XCTUnwrap(search.resolveWordIDs(for: "사과"))
        XCTAssertEqual(koreanIDs, [apple.id])
    }

    func testMeaningSearchReturnsWordsSortedByNormalizedTerm() throws {
        let context = try makeContext()

        _ = makeWord(term: "zebra", meanings: ["공통 뜻"], context: context)
        let alpha = makeWord(term: "alpha", meanings: ["공통 뜻", "다른 뜻"], context: context)
        _ = makeWord(term: "middle", meanings: ["공통 뜻"], context: context)
        try context.save()
        let search = WordLibrarySearch(context: context)

        let ids = try XCTUnwrap(search.resolveWordIDs(for: "공통"))
        let words = try context.fetch(FetchDescriptor<WordRecord>(predicate: #Predicate { ids.contains($0.id) }))
        let wordsByID = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0.term) })

        XCTAssertEqual(ids.compactMap { wordsByID[$0] }, ["alpha", "middle", "zebra"])
        XCTAssertEqual(ids.filter { $0 == alpha.id }.count, 1)
    }

    func testBlankQueryReturnsNilInsteadOfScanningEverything() throws {
        let context = try makeContext()
        _ = makeWord(term: "apple", meanings: ["사과"], context: context)
        try context.save()
        let search = WordLibrarySearch(context: context)

        XCTAssertNil(try search.resolveWordIDs(for: "   "))
    }

    func testEnglishQueryDoesNotAccidentallyMatchKoreanMeaningOnlyRows() throws {
        let context = try makeContext()
        _ = makeWord(term: "pear", meanings: ["application only"], context: context)
        _ = makeWord(term: "banana", meanings: ["사과"], context: context)
        try context.save()
        let search = WordLibrarySearch(context: context)

        XCTAssertEqual(try search.resolveWordIDs(for: "app"), [])
    }

    private func makeWord(term: String, meanings: [String], context: ModelContext) -> WordRecord {
        let word = WordRecord(term: term)
        for value in meanings {
            let meaning = MeaningRecord(text: value)
            meaning.word = word
            word.meanings.append(meaning)
            context.insert(meaning)
        }
        context.insert(word)
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
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    }
}
