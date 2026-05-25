import SwiftData
import SwiftUI

struct ReviewView: View {
    @Query private var words: [WordRecord]

    private var candidates: [WordRecord] {
        words.filter { $0.statusRaw == "active" && ($0.reviewState?.activePriority ?? 0) > 0 }
            .sorted { ($0.reviewState?.activePriority ?? 0) > ($1.reviewState?.activePriority ?? 0) }
    }

    var body: some View {
        List(candidates) { word in
            HStack {
                VStack(alignment: .leading) {
                    Text(word.term).font(.headline)
                    Text(word.meanings.map(\.text).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("체크 \(word.reviewState?.failureCheck ?? 0)")
                Text("우선도 \(word.reviewState?.activePriority ?? 0)")
            }
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView("우선 복습할 단어가 없습니다", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("복습")
    }
}

struct LibraryView: View {
    @Query(sort: \WordRecord.normalizedTerm) private var words: [WordRecord]
    @State private var searchText = ""

    private var filtered: [WordRecord] {
        if searchText.isEmpty { return words.filter { $0.deletedAt == nil } }
        return words.filter { $0.deletedAt == nil && $0.normalizedTerm.contains(TextNormalizer.normalizeEnglish(searchText)) }
    }

    var body: some View {
        List(filtered) { word in
            VStack(alignment: .leading, spacing: 4) {
                Text(word.term).font(.headline)
                Text(word.meanings.map(\.text).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Text(word.statusRaw.capitalized)
                    .font(.caption)
                    .foregroundStyle(word.statusRaw == "mastered" ? Color.green : Color.secondary)
            }
        }
        .searchable(text: $searchText, prompt: "영단어 검색")
        .navigationTitle("단어장")
    }
}

struct HistoryView: View {
    @Query(sort: \AttemptRecord.answeredAt, order: .reverse) private var attempts: [AttemptRecord]

    var body: some View {
        List(attempts) { attempt in
            HStack {
                VStack(alignment: .leading) {
                    Text(attempt.prompt)
                    Text(attempt.directionRaw)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if attempt.automaticJudgementRaw != attempt.finalJudgementRaw {
                    Text("보정됨")
                        .foregroundStyle(.orange)
                }
                Text(attempt.finalJudgementRaw)
            }
        }
        .navigationTitle("학습 기록")
    }
}
