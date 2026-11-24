import SwiftData
import SwiftUI

struct MasteredView: View {
    @Query(filter: #Predicate<WordRecord> { $0.deletedAt == nil }) private var words: [WordRecord]

    private var consolidating: [WordRecord] {
        words.filter { $0.learningStatus == .consolidating }
    }

    var body: some View {
        let consolidating = consolidating
        // One List owns all scrolling: with a header stacked above the List in a
        // VStack, this page shifted the whole Mac window content upward.
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("서로 다른 날짜에 두 번 이상 맞힌 단어입니다. 일반 출제에서 잠시 빠지고, 간격을 두고 기억을 다시 확인합니다.", systemImage: "graduationcap")
                        .font(.body.weight(.medium))
                    Text("7·14·30일 간격 점검을 거쳐 서로 다른 5일에 맞히고, 첫 성공부터 45일 이상이면서 마지막 두 성공 사이가 30일 이상이면 암기완료로 자동 정리됩니다. 오답이나 모름이면 다시 학습 중으로 돌아갑니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if consolidating.isEmpty {
                // Inside the List, not an overlay, so it never covers the explanation.
                ContentUnavailableView(
                    "장기정착 단어가 없습니다",
                    systemImage: "graduationcap",
                    description: Text("서로 다른 날짜에 두 번 맞힌 단어가 여기로 옮겨집니다.")
                )
            } else {
                Section("장기정착 \(consolidating.count)단어") {
                    ForEach(consolidating) { word in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(word.term)
                                    .font(.title3.weight(.semibold))
                                Text(word.meaningsDisplayText)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(
                                title: VocabularyLearningStatus.consolidating.koreanTitle,
                                systemImage: "graduationcap",
                                tint: VocabularyLearningStatus.consolidating.tint
                            )
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}
