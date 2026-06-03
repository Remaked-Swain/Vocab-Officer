import SwiftData
import SwiftUI

struct TestSetupView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DailySetRecord.createdAt, order: .reverse) private var sets: [DailySetRecord]
    @State private var mode: SessionMode = .mixed
    @State private var direction: PracticeDirection = .enToKo
    @State private var selectedSetID: UUID?
    @State private var activeRun: TestRun?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("테스트")
                .font(.largeTitle.weight(.semibold))
            Text("한 회차는 최대 20개의 고유 단어로 구성됩니다. 오늘 입력 세트가 없으면 가장 최근 세트를 오늘 기준 풀처럼 사용합니다.")
                .font(.body)
                .foregroundStyle(.secondary)

            Form {
                Picker("모드", selection: $mode) {
                    ForEach(SessionMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Picker("방향", selection: $direction) {
                    ForEach(PracticeDirection.allCases, id: \.self) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                if mode == .set {
                    Picker("테스트 대상 세트", selection: $selectedSetID) {
                        ForEach(Array(sets.enumerated()), id: \.element.id) { offset, set in
                            Text("\(set.seoulDay) 세트")
                                .tag(Optional(set.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .controlSize(.large)
            .frame(maxWidth: 620)

            if mode == .set {
                Text("아직 시험하지 않은 과거 세트도 선택하여 20문항씩 학습할 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if mode == .review {
                Text("복습 대상이 20개보다 적으면 가장 최근 세트에서 문항을 보충합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if mode == .mixed {
                Text("혼합은 최근 기준 세트 12개를 우선하고 복습·미검증 과거 세트로 보충합니다. 오늘 세트가 없으면 가장 최근 세트를 기준으로 삼습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            Button("20문항 테스트 시작", action: start)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Spacer()
        }
        .padding(32)
        .onAppear {
            if selectedSetID == nil {
                selectedSetID = sets.first?.id
            }
        }
        .sheet(item: $activeRun) { run in
            TestRunnerView(run: run)
                .frame(minWidth: 720, minHeight: 560)
        }
    }

    private func start() {
        do {
            let result = try LearningCoordinator(context: context).generateSession(mode: mode, direction: direction, setID: selectedSetID)
            activeRun = TestRun(session: result.0, questions: result.1)
            error = nil
        } catch let caughtError {
            activeRun = nil
            self.error = caughtError.localizedDescription
        }
    }
}

struct TestRun: Identifiable {
    let session: TestSessionRecord
    let questions: [SessionQuestion]
    var id: UUID { session.id }
}

struct TestRunnerView: View {
    private enum FocusTarget: Hashable {
        case answer
        case finalJudgement
        case correctedMeaning
        case addAlias
        case advance
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let run: TestRun
    @State private var index = 0
    @State private var answer = ""
    @State private var judgeResult: JudgeResult?
    @State private var chosenResult: FinalResult?
    @State private var correctedMeaningID: UUID?
    @State private var addAlias = false
    @State private var notice: String?
    @FocusState private var focus: FocusTarget?

    private var question: SessionQuestion? {
        run.questions.indices.contains(index) ? run.questions[index] : nil
    }

    var body: some View {
        if let question {
            content(question)
        } else {
            ContentUnavailableView("출제 문항이 없습니다", systemImage: "exclamationmark.triangle")
                .padding(30)
        }
    }

    private func content(_ question: SessionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(run.session.modeRaw)
                    .font(.headline)
                if run.session.wasReduced {
                    Label("축소 세션: \(run.questions.count)문항", systemImage: "info.circle")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(index + 1) / \(run.questions.count)")
                    .monospacedDigit()
            }
            ProgressView(value: Double(index), total: Double(run.questions.count))
            Text(question.direction.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(question.prompt)
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)

            TextField("답안을 입력하세요", text: $answer)
                .textFieldStyle(.roundedBorder)
                .font(.title2)
                .controlSize(.large)
                .frame(minHeight: 48)
                .focused($focus, equals: .answer)
                .onSubmit(submitForJudgement)
                .disabled(judgeResult != nil)

            if let judgeResult {
                resultPanel(judgeResult, question: question)
            } else {
                HStack {
                    Button("제출", action: submitForJudgement)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Button("모름") {
                        judgeResult = JudgeResult(automaticResult: .unknown, matchedMeaningID: nil, isTypoSuggestion: false)
                        chosenResult = .unknown
                        correctedMeaningID = question.direction == .enToKo
                            ? question.word.meanings.first(where: \.isTrackableCoreMeaning)?.id
                            : nil
                        focus = .advance
                    }
                    .controlSize(.large)
                }
            }
            if let notice {
                Text(notice).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(30)
        .defaultFocus($focus, .answer)
        .onAppear {
            focus = .answer
        }
        .onKeyPress(.tab) {
            cycleFinalJudgement() ? .handled : .ignored
        }
    }

    @ViewBuilder
    private func resultPanel(_ result: JudgeResult, question: SessionQuestion) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("자동 판정: \(result.automaticResult.rawValue)", systemImage: result.automaticResult == .correct ? "checkmark.circle" : "exclamationmark.circle")
                if result.automaticResult != .unknown {
                    LabeledContent("원문") {
                        Text(question.word.term).fontWeight(.semibold)
                    }
                    LabeledContent("등록 의미") {
                        Text(question.word.meanings.map(\.text).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("입력 답안") {
                        Text(answer.isEmpty ? "(입력 없음)" : answer)
                    }
                }
                if result.isTypoSuggestion {
                    Text("근접 오타일 수 있습니다. 자동 정답 처리하지 않으며 직접 보정해야 합니다.")
                        .foregroundStyle(.orange)
                }
                if result.automaticResult == .incorrect {
                    Text("자동 오답은 원문과 등록 의미를 확인한 뒤 확정하거나 정답으로 보정하세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Picker("최종 판정", selection: Binding(get: { chosenResult ?? result.automaticResult }, set: { chosenResult = $0 })) {
                    Text("정답").tag(FinalResult.correct)
                    Text("오답").tag(FinalResult.incorrect)
                    Text("모름").tag(FinalResult.unknown)
                }
                .pickerStyle(.segmented)
                .focused($focus, equals: .finalJudgement)
                if (chosenResult ?? result.automaticResult) == .correct && result.automaticResult != .correct {
                    if question.direction == .enToKo {
                        Picker("확인한 핵심 뜻", selection: $correctedMeaningID) {
                            ForEach(question.word.meanings.filter(\.isTrackableCoreMeaning)) { meaning in
                                Text(meaning.text).tag(Optional(meaning.id))
                            }
                        }
                        .focused($focus, equals: .correctedMeaning)
                    }
                    Toggle("이 답안을 이후 허용 답안으로 추가", isOn: $addAlias)
                        .focused($focus, equals: .addAlias)
                }
                Text("Return으로 제출·확정하고, Tab으로 최종 판정을 전환할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(index + 1 == run.questions.count ? "완료" : "확정 후 다음", action: commitAndAdvance)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .focused($focus, equals: .advance)
            }
            .padding(8)
        }
    }

    private func submitForJudgement() {
        guard let question else { return }
        let result = LearningCoordinator(context: context).judge(answer: answer, for: question)
        judgeResult = result
        chosenResult = result.automaticResult
        correctedMeaningID = question.direction == .enToKo ? question.word.meanings.first(where: \.isTrackableCoreMeaning)?.id : nil
        focus = result.automaticResult == .incorrect ? .finalJudgement : .advance
    }

    private func cycleFinalJudgement() -> Bool {
        guard let judgeResult else { return false }
        let order: [FinalResult] = [.correct, .incorrect, .unknown]
        let current = chosenResult ?? judgeResult.automaticResult
        guard let index = order.firstIndex(of: current) else { return false }
        chosenResult = order[(index + 1) % order.count]
        focus = .finalJudgement
        notice = nil
        return true
    }

    private func commitAndAdvance() {
        guard let judgeResult, let question else { return }
        let final = chosenResult ?? judgeResult.automaticResult
        if final == .correct,
           judgeResult.automaticResult != .correct,
           question.direction == .enToKo,
           correctedMeaningID == nil {
            notice = "정답으로 보정하려면 확인한 핵심 뜻을 선택하세요."
            focus = .correctedMeaning
            return
        }
        do {
            if addAlias, final == .correct {
                if question.direction == .enToKo, let meaning = question.word.meanings.first(where: { $0.id == correctedMeaningID }) {
                    meaning.aliases.append(answer)
                } else if question.direction == .koToEn {
                    question.word.englishAliases.append(answer)
                }
            }
            let finalMeaningID = final == .correct && question.direction == .enToKo
                ? (judgeResult.matchedMeaningID ?? correctedMeaningID)
                : judgeResult.matchedMeaningID
            try LearningCoordinator(context: context).commit(answer: answer, result: final, automatic: judgeResult.automaticResult, matchedMeaningID: finalMeaningID, question: question, session: run.session, correction: final == judgeResult.automaticResult ? nil : (addAlias ? "acceptedAlias" : "oneTimeCorrection"))
            if index + 1 == run.questions.count {
                run.session.completedAt = .now
                try context.save()
                dismiss()
            } else {
                index += 1
                answer = ""
                self.judgeResult = nil
                chosenResult = nil
                correctedMeaningID = nil
                addAlias = false
                notice = nil
                focus = .answer
            }
        } catch {
            notice = error.localizedDescription
        }
    }
}
