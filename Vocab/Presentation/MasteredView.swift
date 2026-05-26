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
