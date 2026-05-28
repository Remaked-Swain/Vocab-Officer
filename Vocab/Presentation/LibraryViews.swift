import SwiftData
import SwiftUI

struct StudyCardsView: View {
    @Query(sort: \DailySetRecord.createdAt, order: .reverse) private var sets: [DailySetRecord]
    @Query private var words: [WordRecord]
    @State private var selectedSetID: UUID?

    private var selectedSet: DailySetRecord? {
        sets.first { $0.id == selectedSetID } ?? sets.first
    }

    private var wordsByID: [UUID: WordRecord] {
        Dictionary(uniqueKeysWithValues: words.filter { $0.deletedAt == nil }.map { ($0.id, $0) })
    }

    private var selectedEntries: [StudyCardEntry] {
        selectedSet?.items
            .sorted { $0.orderIndex < $1.orderIndex }
            .compactMap { item in
                wordsByID[item.wordID].map { StudyCardEntry(item: item, word: $0) }
            } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("학습 카드")
                .font(.largeTitle.weight(.semibold))
            Text("입력한 세트별로 카드를 클릭하거나 Return 키를 눌러 원문과 의미를 뒤집어 확인하세요.")
                .font(.body)
                .foregroundStyle(.secondary)

            Picker("학습 세트", selection: Binding(
                get: { selectedSet?.id },
                set: { selectedSetID = $0 }
            )) {
                ForEach(sets) { set in
                    Text("\(set.seoulDay) 세트  (\(set.items.count)개)")
                        .tag(Optional(set.id))
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)

            if selectedEntries.isEmpty {
                ContentUnavailableView("학습할 세트가 없습니다", systemImage: "rectangle.stack")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        ForEach(selectedEntries) { entry in
                            FlipWordCard(word: entry.word)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(28)
        .navigationTitle("학습 카드")
    }
}

private struct StudyCardEntry: Identifiable {
    let id: UUID
    let word: WordRecord

    init(item: DailySetItemRecord, word: WordRecord) {
        id = item.id
        self.word = word
    }
}

private struct FlipWordCard: View {
    let word: WordRecord
    @State private var showsMeaning = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                showsMeaning.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.quaternary, lineWidth: 1)
                VStack(spacing: 10) {
                    Text(showsMeaning ? "의미" : "English")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(showsMeaning ? word.meanings.map(\.text).joined(separator: ", ") : word.term)
                        .font(showsMeaning ? .body : .title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
                .padding(16)
            }
            .frame(minHeight: 126)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word.term)
        .accessibilityValue(showsMeaning ? word.meanings.map(\.text).joined(separator: ", ") : "영단어 앞면")
        .accessibilityHint("눌러서 카드 앞뒤를 전환합니다")
    }
}

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
                    Text(word.term).font(.title3.weight(.semibold))
                    Text(word.meanings.map(\.text).joined(separator: ", "))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("체크 \(word.reviewState?.failureCheck ?? 0)")
                Text("우선도 \(word.reviewState?.activePriority ?? 0)")
            }
            .padding(.vertical, 5)
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
                Text(word.term).font(.title3.weight(.semibold))
                Text(word.meanings.map(\.text).joined(separator: ", "))
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(word.statusRaw.capitalized)
                    .font(.caption)
                    .foregroundStyle(word.statusRaw == "mastered" ? Color.green : Color.secondary)
            }
            .padding(.vertical, 5)
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
                        .font(.body)
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
            .padding(.vertical, 5)
        }
        .navigationTitle("학습 기록")
    }
}
