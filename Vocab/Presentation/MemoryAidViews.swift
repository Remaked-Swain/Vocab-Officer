import SwiftUI

struct WordMemoryAidButton: View {
    let word: WordRecord

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "sparkles")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("암기 도움 보기")
        .accessibilityLabel("\(word.term) 암기 도움 보기")
        .sheet(isPresented: $isPresented) {
            WordMemoryAidSheet(word: word)
        }
    }
}

private struct WordMemoryAidSheet: View {
    @Environment(\.modelContext) private var context
    let word: WordRecord

    @AppStorage("memoryAidModel") private var modelRawValue = MemoryAidModel.gemini35Flash.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var result: WordMemoryAid?
    @State private var errorMessage: String?

    private var selectedModel: MemoryAidModel {
        MemoryAidModel(rawValue: modelRawValue) ?? .gemini35Flash
    }

    private var renderedMarkdown: AttributedString? {
        guard let markdown = result?.markdown else { return nil }
        return try? AttributedString(markdown: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("암기 도움")
                        .font(.title.weight(.semibold))
                    Text(word.term)
                        .font(.title2.weight(.bold))
                    Text(word.meanings.map(\.text).joined(separator: ", "))
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }
                    .controlSize(.large)
            }

            FeedbackPanel(items: feedbackItems)
                .accessibilityLabel("암기 도움 상태 안내")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isLoading {
                        ProgressView("암기 도움을 생성하는 중...")
                            .controlSize(.regular)
                    } else if let renderedMarkdown {
                        Text(renderedMarkdown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ContentUnavailableView(
                            "아직 생성된 암기 도움이 없습니다",
                            systemImage: "sparkles.rectangle.stack"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Text("모델: \(selectedModel.displayName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("다시 생성") {
                    Task { await generate(forceRefresh: true) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLoading)
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 520)
        .task {
            if result == nil, !isLoading {
                await generate(forceRefresh: false)
            }
        }
    }

    private var feedbackItems: [FeedbackItem] {
        if let errorMessage {
            return [
                FeedbackItem(
                    text: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    color: .red
                )
            ]
        }

        var items = [
            FeedbackItem(
                text: "Gemini 무료 티어에서는 요청 내용이 제품 개선에 사용될 수 있습니다. 민감한 정보는 보내지 마세요.",
                systemImage: "info.circle",
                color: .secondary
            )
        ]

        if let result {
            items.insert(
                FeedbackItem(
                    text: sourceMessage(for: result),
                    systemImage: "checkmark.circle",
                    color: .green
                ),
                at: 0
            )
        }

        return items
    }

    private func generate(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            result = try await MemoryAidService(context: context).generate(
                for: word,
                model: selectedModel,
                forceRefresh: forceRefresh
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sourceMessage(for result: WordMemoryAid) -> String {
        let prefix = result.source == .cached ? "저장된 암기 도움" : "새로 생성한 암기 도움"
        return "\(prefix) · \(selectedModel.displayName) · \(result.generatedAt.formatted(date: .omitted, time: .standard))"
    }
}
