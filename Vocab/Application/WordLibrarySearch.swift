import Foundation
import SwiftData

struct WordLibrarySearch {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func resolveWordIDs(for query: String) throws -> [UUID]? {
        let normalizedEnglish = TextNormalizer.normalizeEnglish(query)
        let normalizedMeaning = TextNormalizer.normalizeKorean(query)

        guard !normalizedEnglish.isEmpty || !normalizedMeaning.isEmpty else {
            return nil
        }

        var candidateIDs = Set<UUID>()

        if !normalizedEnglish.isEmpty {
            candidateIDs.formUnion(try fetchTermMatchedWordIDs(normalizedEnglish))
        }

        if Self.containsHangul(query), !normalizedMeaning.isEmpty {
            candidateIDs.formUnion(try fetchMeaningMatchedWordIDs(normalizedMeaning))
        }

        guard !candidateIDs.isEmpty else {
            return []
        }

        let ids = Array(candidateIDs)
        let descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                ids.contains(word.id) && word.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.normalizedTerm)]
        )
        return try context.fetch(descriptor).map(\.id)
    }

    private func fetchTermMatchedWordIDs(_ normalizedEnglish: String) throws -> [UUID] {
        let descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                word.deletedAt == nil && word.normalizedTerm.contains(normalizedEnglish)
            },
            sortBy: [SortDescriptor(\.normalizedTerm)]
        )
        return try context.fetch(descriptor).map(\.id)
    }

    private func fetchMeaningMatchedWordIDs(_ normalizedMeaning: String) throws -> [UUID] {
        let descriptor = FetchDescriptor<MeaningRecord>(
            predicate: #Predicate { meaning in
                meaning.normalizedText.contains(normalizedMeaning)
            }
        )
        return try context.fetch(descriptor).compactMap { $0.word?.id }
    }

    private static func containsHangul(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value)
        }
    }
}
