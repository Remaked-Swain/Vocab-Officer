import SwiftData
import SwiftUI

struct MasteredView: View {
    @Query(filter: #Predicate<WordRecord> { $0.deletedAt == nil }) private var words: [WordRecord]

    private var consolidating: [WordRecord] {
        words.filter { $0.learningStatus == .consolidating }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("장기정착이란?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("서로 다른 날짜에 두 번 이상 맞혀 일반 출제에서 잠시 제외되고, 장기 기억 여부를 간격을 두고 다시 확인하는 단어입니다.")
                        .font(.body.weight(.medium))
                    Text("7일, 14일, 30일 간격의 점검을 거쳐 서로 다른 5일에 맞히고, 첫 성공부터 45일 이상이면서 마지막 두 성공 사이가 30일 이상이면 암기완료로 판정되어 자동 정리됩니다. 오답이나 모름이면 다시 학습 중으로 돌아갑니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .padding(.horizontal)

            List(consolidating) { word in
                HStack {
                    VStack(alignment: .leading) {
                        Text(word.term).font(.title3.weight(.semibold))
                        Text(word.activeMeanings.map(\.text).joined(separator: ", "))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("장기정착")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 5)
            }
            .overlay {
                if consolidating.isEmpty {
                    ContentUnavailableView("장기정착 단어가 없습니다", systemImage: "graduationcap")
                }
            }
        }
        .navigationTitle("장기정착")
    }
}
