import SwiftData
import SwiftUI

struct TodayIntakeView: View {
    @Environment(\.modelContext) private var context
    @State private var drafts = (0..<100).map { _ in WordDraft() }
    @State private var message: String?
    @State private var isError = false

    var filledCount: Int {
        drafts.filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("오늘 입력")
                        .font(.largeTitle.weight(.semibold))
                    Text("PDF 단어장을 보며 신규 표제어 100개와 여러 한국어 뜻을 입력하세요.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(filledCount) / 100")
                    .font(.title3.monospacedDigit())
                    .accessibilityLabel("입력된 신규 단어 \(filledCount)개")
                Button("100개 세트 저장", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(filledCount != 100)
            }

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(isError ? .red : .green)
            }

            Table($drafts) {
                TableColumn("#") { draft in
                    if let index = drafts.firstIndex(where: { $0.id == draft.wrappedValue.id }) {
                        Text("\(index + 1)")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(42)
                TableColumn("English") { $draft in
                    TextField("headword", text: $draft.term)
                        .textFieldStyle(.plain)
                }
                .width(min: 180)
                TableColumn("한국어 뜻 (쉼표로 구분)") { $draft in
                    TextField("뜻1, 뜻2", text: $draft.meanings)
                        .textFieldStyle(.plain)
                }
            }
            .accessibilityLabel("오늘 신규 단어 입력 표")
        }
        .padding(20)
        .toolbar {
            ToolbarItem {
                Button("비우기") {
                    drafts = (0..<100).map { _ in WordDraft() }
                    message = nil
                }
            }
        }
    }

    private func save() {
        do {
            try LearningCoordinator(context: context).saveDailySet(drafts)
            message = "Asia/Seoul 기준 오늘의 신규 100단어 세트를 저장했습니다."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }
}

