import SwiftUI

/// Final judgements committed during one test run, used only for the completion
/// summary. Grading and persistence stay in `LearningCoordinator`.
struct TestSessionTally: Equatable {
    /// Keyed by question index so retrying a failed completion never counts an
    /// answer twice.
    private var results: [Int: FinalResult] = [:]

    var total: Int { results.count }

    func count(of result: FinalResult) -> Int {
        results.values.reduce(0) { $1 == result ? $0 + 1 : $0 }
    }

    /// Whole-percent share of correct answers; zero before any commit.
    var correctPercentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(count(of: .correct)) / Double(total) * 100).rounded())
    }

    mutating func record(_ result: FinalResult, forQuestionAt index: Int) {
        results[index] = result
    }
}

/// How a multiple-choice option is drawn before and after judgement.
enum ChoiceOptionAppearance: Equatable {
    case idle
    case selected
    case revealedCorrect
    case selectedIncorrect
    case dimmed

    static func resolve(option: MultipleChoiceOption, selectedAnswer: String, isJudged: Bool) -> ChoiceOptionAppearance {
        let isSelected = selectedAnswer == option.id.uuidString
        guard isJudged else { return isSelected ? .selected : .idle }
        if option.isCorrect { return .revealedCorrect }
        return isSelected ? .selectedIncorrect : .dimmed
    }

    var background: Color {
        switch self {
        case .idle, .dimmed: Color.secondary.opacity(0.10)
        case .selected: Color.accentColor.opacity(0.18)
        case .revealedCorrect: Color.green.opacity(0.18)
        case .selectedIncorrect: Color.red.opacity(0.16)
        }
    }

    var stroke: Color {
        switch self {
        case .idle, .dimmed: .clear
        case .selected: .accentColor.opacity(0.55)
        case .revealedCorrect: .green.opacity(0.60)
        case .selectedIncorrect: .red.opacity(0.55)
        }
    }

    var systemImage: String? {
        switch self {
        case .revealedCorrect: "checkmark.circle.fill"
        case .selectedIncorrect: "xmark.circle.fill"
        case .idle, .selected, .dimmed: nil
        }
    }
}

struct TestProgressHeader: View {
    let modeTitle: String
    let index: Int
    let total: Int
    var reducedQuestionCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(modeTitle)
                    .font(.headline)
                if let reducedQuestionCount {
                    StatusBadge(title: "축소 세션 \(reducedQuestionCount)문항", systemImage: "info.circle", tint: .orange)
                }
                Spacer()
                Text("\(index + 1) / \(total)")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(total)문항 중 \(index + 1)번째")
            }
            ProgressView(value: Double(index), total: Double(max(total, 1)))
                .accessibilityHidden(true)
        }
    }
}

struct TestPromptCard: View {
    let question: SessionQuestion

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                StatusBadge(title: question.direction.shortTitle, systemImage: "arrow.left.arrow.right", tint: .secondary)
                StatusBadge(title: question.format.title, tint: .secondary)
                Spacer(minLength: 0)
            }
            Text(question.prompt)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 88)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: VocabMetrics.cardCornerRadius, style: .continuous))
    }
}

struct ChoiceOptionButton: View {
    let number: Int
    let label: String
    let appearance: ChoiceOptionAppearance
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(label)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let systemImage = appearance.systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(appearance == .revealedCorrect ? Color.green : Color.red)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(14)
            .background(appearance.background, in: RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous)
                    .stroke(appearance.stroke, lineWidth: 1.5)
            }
            .opacity(appearance == .dimmed ? 0.6 : 1)
            .contentShape(RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number)번, \(label)")
    }
}

/// The automatic judgement headline at the top of the acknowledgement panel.
struct JudgementBanner: View {
    let result: JudgeResult

    var body: some View {
        let automatic = result.automaticResult
        HStack(spacing: 10) {
            Image(systemName: automatic.systemImage)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("자동 판정: \(automatic.title)")
                    .font(.headline)
                if result.isTypoSuggestion {
                    Text("근접 오타일 수 있습니다. 자동 정답 처리하지 않으니 필요하면 직접 보정하세요.")
                        .font(.callout)
                } else if automatic == .incorrect {
                    Text("원문과 등록 의미를 확인한 뒤 확정하거나 정답으로 보정하세요.")
                        .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(automatic.tint)
        .accessibilityElement(children: .combine)
    }
}

/// Headword, every meaning and the submitted answer, shown before confirmation.
struct AnswerComparisonView: View {
    let question: SessionQuestion
    let submittedAnswer: String

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("원문", question.word.term, emphasized: true)
            row("등록 의미", question.word.meaningsDisplayText, emphasized: false)
            row("입력 답안", submittedAnswer, emphasized: false)
            if question.format == .multipleChoice,
               let correct = question.choices.first(where: \.isCorrect) {
                row("정답", correct.label, emphasized: true)
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ title: String, _ value: String, emphasized: Bool) -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(emphasized ? .body.weight(.semibold) : .body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TestCompletionView: View {
    let modeTitle: String
    let tally: TestSessionTally
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("테스트 완료")
                    .font(.title.weight(.bold))
                Text("\(modeTitle) · \(tally.total)문항 · 정답률 \(tally.correctPercentage)%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(FinalResult.judgementOrder, id: \.self) { result in
                    VStack(spacing: 6) {
                        Image(systemName: result.systemImage)
                            .foregroundStyle(result.tint)
                        Text("\(tally.count(of: result))")
                            .font(.title2.monospacedDigit().weight(.semibold))
                        Text(result.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: 420)
            Text("결과는 학습 기록과 복습 상태에 이미 반영되었습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: onClose) {
                Text("닫기")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
