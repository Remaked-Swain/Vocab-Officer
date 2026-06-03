import SwiftData
import SwiftUI

struct MasteredView: View {
    @Environment(\.modelContext) private var context
    @Query private var words: [WordRecord]
    @State private var pendingDeletion: WordRecord?
    @State private var confirmationText = ""
    @State private var notice: String?

    private var mastered: [WordRecord] {
        words.filter { $0.statusRaw == "mastered" && $0.deletedAt == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Mastered란?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("충분히 검증되어 일반 테스트·복습 출제에서 제외된 단어 보관함입니다.")
                        .font(.body.weight(.medium))
                    Text("모든 핵심 뜻의 영→한 정답 이력과 한→영 정답 이력이 여러 날짜에 쌓이고, 최근 오답이 없을 때 자동 진입합니다. 삭제는 암기 완료 후 사용자가 명시적으로 실행하는 별도 동작입니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }
            .padding(.horizontal)

            List(mastered) { word in
                HStack {
                    VStack(alignment: .leading) {
                        Text(word.term).font(.title3.weight(.semibold))
                        Text(word.meanings.map(\.text).joined(separator: ", "))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("영구 삭제", role: .destructive) {
                        pendingDeletion = word
                    }
                    .controlSize(.large)
                }
                .padding(.vertical, 5)
            }
            .overlay {
                if mastered.isEmpty {
                    ContentUnavailableView("Mastered 단어가 없습니다", systemImage: "graduationcap")
                }
            }
        }
        .navigationTitle("Mastered")
        .alert("Mastered 단어 영구 삭제", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            TextField("DELETE 입력", text: $confirmationText)
                .font(.body)
            Button("취소", role: .cancel) {
                pendingDeletion = nil
                confirmationText = ""
            }
            Button("삭제", role: .destructive) {
                performDeletion()
            }
            .disabled(confirmationText != "DELETE")
        } message: {
            Text("이 단어와 식별 가능한 학습 이력을 앱 저장소에서 영구 삭제합니다.")
        }
        .safeAreaInset(edge: .bottom) {
            if let notice {
                Text(notice)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
    }

    private func performDeletion() {
        guard let word = pendingDeletion else { return }
        do {
            try LearningCoordinator(context: context).deleteMastered(word)
            notice = "식별 가능한 학습 이력을 앱 저장소에서 삭제했습니다."
        } catch {
            notice = error.localizedDescription
        }
        pendingDeletion = nil
        confirmationText = ""
    }
}
