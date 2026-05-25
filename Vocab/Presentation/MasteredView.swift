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
                    Text(word.term).font(.headline)
                    Text(word.meanings.map(\.text).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("영구 삭제", role: .destructive) {
                    pendingDeletion = word
                }
            }
        }
        .overlay {
            if mastered.isEmpty {
                ContentUnavailableView("Mastered 단어가 없습니다", systemImage: "graduationcap")
            }
        }
        .navigationTitle("Mastered")
        .alert("Mastered 단어 영구 삭제", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            TextField("DELETE 입력", text: $confirmationText)
            Button("취소", role: .cancel) {
                pendingDeletion = nil
                confirmationText = ""
            }
            Button("삭제", role: .destructive) {
                performDeletion()
            }
            .disabled(confirmationText != "DELETE")
        } message: {
            Text("앱 데이터와 앱이 관리하는 백업에서 식별 가능한 학습 이력을 제거합니다. 외부로 복사한 JSON 파일은 앱이 찾거나 삭제할 수 없습니다.")
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
        let container = context.container
        let wordID = word.id
        Task {
            do {
                let backup = BackupService(modelContainer: container)
                _ = try await backup.createManagedBackup()
                try await backup.scrubManagedBackups(removing: wordID)
                try LearningCoordinator(context: context).deleteMastered(word)
                notice = "식별 데이터 삭제와 앱 관리 백업 scrub을 완료했습니다."
            } catch {
                notice = error.localizedDescription
            }
        }
        pendingDeletion = nil
        confirmationText = ""
    }
}
