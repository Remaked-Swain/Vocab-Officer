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

    @AppStorage("memoryAidModel") private var modelRawValue = MemoryAidModel.defaultModel.rawValue
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var result: WordMemoryAid?
    @State private var errorMessage: String?
    @State private var progressStage: MemoryAidProgressStage?
    @State private var generationStartedAt: Date?
    @State private var elapsedSeconds = 0

    private var shouldShowProgress: Bool {
        isLoading && progressStage != nil
    }

    private var selectedModel: MemoryAidModel {
        MemoryAidModel(rawValue: modelRawValue) ?? .defaultModel
    }

    private var renderedMarkdown: AttributedString? {
        guard let markdown = result?.markdown else { return nil }
        return try? AttributedString(markdown: markdown)
    }

    private var parsedAid: MemoryAidQualityGate.ParsedMemoryAid? {
        guard let markdown = result?.markdown else { return nil }
        return MemoryAidQualityGate.parsed(markdown)
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
                    if shouldShowProgress, let progressStage {
                        MemoryAidGenerationProgressView(stage: progressStage, elapsedSeconds: elapsedSeconds)
                    } else if let parsedAid {
                        MemoryAidContentView(aid: parsedAid)
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
        .task(id: shouldShowProgress) {
            guard shouldShowProgress else { return }
            while !Task.isCancelled, shouldShowProgress {
                updateElapsedSeconds()
                try? await Task.sleep(for: .seconds(1))
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
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        progressStage = .preparing
        generationStartedAt = .now
        elapsedSeconds = 0
        defer {
            isLoading = false
            progressStage = nil
            generationStartedAt = nil
            elapsedSeconds = 0
        }

        do {
            result = try await MemoryAidService(context: context).generate(
                for: word,
                model: selectedModel,
                forceRefresh: forceRefresh
            ) { stage in
                progressStage = stage
                updateElapsedSeconds()
            }
        } catch {
            errorMessage = MemoryAidError.userFacingMessage(for: error)
        }
    }

    private func sourceMessage(for result: WordMemoryAid) -> String {
        let prefix = result.source == .cached ? "저장된 암기 도움" : "새로 생성한 암기 도움"
        return "\(prefix) · \(result.model.displayName) · \(result.generatedAt.formatted(date: .omitted, time: .standard))"
    }

    private func updateElapsedSeconds() {
        guard let generationStartedAt else {
            elapsedSeconds = 0
            return
        }
        elapsedSeconds = max(0, Int(Date().timeIntervalSince(generationStartedAt)))
    }
}

private struct MemoryAidGenerationProgressView: View {
    let stage: MemoryAidProgressStage
    let elapsedSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.title)
                        .font(.headline.weight(.semibold))
                    Text("경과 \(elapsedSeconds)초")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(stage.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title), 경과 \(elapsedSeconds)초, \(stage.detail)")
    }
}

private struct MemoryAidContentView: View {
    let aid: MemoryAidQualityGate.ParsedMemoryAid

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MemoryAidSectionCard(title: "한줄 기억", content: aid.hook, accent: .blue)
            MemoryAidSectionCard(title: "형태/어원", content: aid.etymology, accent: .orange)
            MemoryAidSectionCard(title: "연상 포인트", content: aid.association, accent: .purple)
            MemoryAidSectionCard(
                title: "예문",
                content: "EN: \(aid.exampleEnglish)\nKO: \(aid.exampleKorean)",
                accent: .green
            )
            MemoryAidSectionCard(title: "비교", content: aid.comparison, accent: .pink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryAidSectionCard: View {
    let title: String
    let content: String
    let accent: Color

    var bodyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(accent)
            Text(content)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }

    var body: some View {
        bodyView
            .accessibilityElement(children: .combine)
    }
}
