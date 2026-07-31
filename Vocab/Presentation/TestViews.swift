import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TestSetupView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<DailySetRecord> { $0.deletedAt == nil }) private var sets: [DailySetRecord]
    @State private var mode: SessionMode = .mixed
    @State private var direction: PracticeDirection = .enToKo
    @State private var format: QuestionFormat = .typed
    @State private var selectedSetID: UUID?
    @State private var activeRun: TestRun?
    @State private var isStarting = false
    @State private var error: String?

    private var orderedSets: [DailySetRecord] {
        sets.sorted(by: newestSetFirst)
    }

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
                Picker("시험 방식", selection: $format) {
                    ForEach(QuestionFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                if mode == .set {
                    Picker("테스트 대상 세트", selection: $selectedSetID) {
                        ForEach(Array(orderedSets.enumerated()), id: \.element.id) { offset, set in
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
            } else if mode == .loose {
                Text("일일 세트에 속하지 않은 낱개 단어만 최대 20개 출제합니다. 덜 출제된 단어를 우선하여 반복 테스트에서도 빈도를 고르게 유지합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if mode == .review {
                Text("복습은 미암기 단어 최대 14개와 직전 세트 최대 6개를 조합합니다. 자리가 남으면 나머지 복습 대상과 기준 세트로 채웁니다.")
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
            HStack(spacing: 12) {
                Button(format == .multipleChoice ? "4지선택형 테스트 시작" : "20문항 테스트 시작", action: start)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isStarting || activeRun != nil)
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                    Text("테스트 준비 중...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(32)
        .onAppear {
            if selectedSetID == nil {
                selectedSetID = orderedSets.first?.id
            }
        }
        #if os(macOS)
        .background(TestRunnerWindowPresenter(run: $activeRun, context: context))
        #else
        .sheet(item: $activeRun) { run in
            TestRunnerView(run: run, onClose: { activeRun = nil })
                .frame(minWidth: 720, minHeight: 560)
        }
        #endif
    }

    private func start() {
        guard !isStarting, activeRun == nil else { return }
        isStarting = true
        error = nil

        let mode = mode
        let direction = direction
        let selectedSetID = selectedSetID
        let format = format
        Task { @MainActor in
            await Task.yield()
            do {
                let result = try LearningCoordinator(context: context).generateSession(mode: mode, direction: direction, setID: selectedSetID, format: format)
                activeRun = TestRun(session: result.0, questions: result.1)
            } catch let caughtError {
                activeRun = nil
                self.error = caughtError.localizedDescription
            }
            isStarting = false
        }
    }

    private func newestSetFirst(_ lhs: DailySetRecord, _ rhs: DailySetRecord) -> Bool {
        if lhs.seoulDay != rhs.seoulDay {
            return lhs.seoulDay > rhs.seoulDay
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
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
    var onClose: (() -> Void)?
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
        ScrollView {
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
                Text(question.format.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(question.prompt)
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)

                if question.format == .multipleChoice {
                    multipleChoiceGrid(question)
                } else {
                    TextField("답안을 입력하세요", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .font(.title2)
                        .controlSize(.large)
                        .frame(minHeight: 48)
                        .focused($focus, equals: .answer)
                        .onSubmit(submitForJudgement)
                        .disabled(judgeResult != nil)
                }

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
                                ? question.word.defaultCorrectionMeaningID
                                : nil
                            focus = .advance
                        }
                        .controlSize(.large)
                    }
                }
                if let notice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(30)
        .frame(minWidth: 760, minHeight: 640)
        .defaultFocus($focus, .answer)
        #if os(macOS)
        .background(
            TestKeyCaptureView(
                isActive: question.format == .multipleChoice || judgeResult != nil,
                onTab: cycleFinalJudgement,
                onReturn: handleReturnKey,
                onDigit: { value in selectChoice(at: value - 1) }
            )
        )
        #endif
        .onAppear {
            updateKeyboardFocus(for: question)
        }
        .onChange(of: index) { _, _ in
            if let nextQuestion = self.question {
                updateKeyboardFocus(for: nextQuestion)
            }
        }
        .onKeyPress(.tab) {
            cycleFinalJudgement() ? .handled : .ignored
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let character = press.characters.first,
                  let value = Int(String(character)),
                  (1...4).contains(value) else { return .ignored }
            return selectChoice(at: value - 1) ? .handled : .ignored
        }
    }

    @ViewBuilder
    private func multipleChoiceGrid(_ question: SessionQuestion) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Array(question.choices.enumerated()), id: \.element.id) { offset, option in
                Button {
                    selectChoice(option)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(offset + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(option.label)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .padding(14)
                    .background(choiceBackground(option), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(judgeResult != nil)
                .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [])
            }
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
                        Text(question.word.activeMeanings.map(\.text).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("입력 답안") {
                        Text(displayedAnswer(for: question))
                    }
                    if question.format == .multipleChoice {
                        LabeledContent("정답") {
                            Text(question.choices.first(where: \.isCorrect)?.label ?? "")
                        }
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
                Button("판정 전환") {
                    _ = cycleFinalJudgement()
                }
                .keyboardShortcut(.tab, modifiers: [])
                .controlSize(.small)
                if (chosenResult ?? result.automaticResult) == .correct && result.automaticResult != .correct {
                    if question.direction == .enToKo {
                        Picker("확인한 핵심 뜻", selection: $correctedMeaningID) {
                            ForEach(question.word.correctionCandidateMeanings) { meaning in
                                Text(meaning.text).tag(Optional(meaning.id))
                            }
                        }
                        .focused($focus, equals: .correctedMeaning)
                    }
                    if question.format == .typed {
                        Toggle("이 답안을 이후 허용 답안으로 추가", isOn: $addAlias)
                            .focused($focus, equals: .addAlias)
                    } else {
                        Text("선택형 보정은 이번 답안의 최종 판정에만 반영합니다.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(question.format == .multipleChoice ? "1-4로 선택하고 Return으로 확정합니다. Tab으로 최종 판정을 전환할 수 있습니다." : "Return으로 제출·확정하고, Tab으로 최종 판정을 전환할 수 있습니다.")
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
        if question.format == .multipleChoice, answer.isEmpty {
            notice = "선택지를 먼저 고르세요."
            return
        }
        let result = LearningCoordinator(context: context).judge(answer: answer, for: question)
        judgeResult = result
        chosenResult = result.automaticResult
        correctedMeaningID = question.direction == .enToKo ? question.word.defaultCorrectionMeaningID : nil
        focus = nil
    }

    private func selectChoice(at offset: Int) -> Bool {
        guard let question,
              question.format == .multipleChoice,
              judgeResult == nil,
              question.choices.indices.contains(offset) else { return false }
        selectChoice(question.choices[offset])
        return true
    }

    private func selectChoice(_ option: MultipleChoiceOption) {
        answer = option.id.uuidString
        notice = nil
        submitForJudgement()
    }

    private func choiceBackground(_ option: MultipleChoiceOption) -> Color {
        guard answer == option.id.uuidString else { return Color.secondary.opacity(0.10) }
        return Color.accentColor.opacity(0.18)
    }

    private func displayedAnswer(for question: SessionQuestion) -> String {
        guard question.format == .multipleChoice else { return answer.isEmpty ? "(입력 없음)" : answer }
        return question.choices.first { $0.id.uuidString == answer }?.label ?? "(선택 없음)"
    }

    private func cycleFinalJudgement() -> Bool {
        guard let judgeResult else { return false }
        let order: [FinalResult] = [.correct, .incorrect, .unknown]
        let current = chosenResult ?? judgeResult.automaticResult
        guard let index = order.firstIndex(of: current) else { return false }
        chosenResult = order[(index + 1) % order.count]
        focus = nil
        notice = nil
        return true
    }

    private func handleReturnKey() -> Bool {
        if judgeResult != nil {
            commitAndAdvance()
            return true
        }
        guard question?.format == .multipleChoice else { return false }
        submitForJudgement()
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
                if question.direction == .enToKo, let meaning = question.word.activeMeanings.first(where: { $0.id == correctedMeaningID }) {
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
                try LearningCoordinator(context: context).completeSession(run.session)
                closeRunner()
            } else {
                index += 1
                answer = ""
                self.judgeResult = nil
                chosenResult = nil
                correctedMeaningID = nil
                addAlias = false
                notice = nil
                updateKeyboardFocus(for: run.questions[index])
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func closeRunner() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func updateKeyboardFocus(for question: SessionQuestion) {
        if question.format == .typed && judgeResult == nil {
            focus = .answer
        } else {
            focus = nil
        }
    }
}

#if os(macOS)
private struct TestRunnerWindowPresenter: NSViewRepresentable {
    @Binding var run: TestRun?
    let context: ModelContext

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(run: run, modelContext: self.context)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.closeWindow()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var parent: TestRunnerWindowPresenter
        private weak var window: NSWindow?
        private var presentedRunID: UUID?

        init(parent: TestRunnerWindowPresenter) {
            self.parent = parent
        }

        func update(run: TestRun?, modelContext: ModelContext) {
            guard let run else {
                closeWindow()
                return
            }
            if presentedRunID == run.id, window != nil {
                return
            }
            closeWindow()
            openWindow(for: run, modelContext: modelContext)
        }

        func closeWindow() {
            presentedRunID = nil
            let existing = window
            window = nil
            existing?.delegate = nil
            existing?.close()
        }

        func windowWillClose(_ notification: Notification) {
            presentedRunID = nil
            window = nil
            parent.run = nil
        }

        private func openWindow(for run: TestRun, modelContext: ModelContext) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 760),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Vocab 테스트"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 760, height: 640)
            window.contentViewController = NSHostingController(
                rootView: TestRunnerView(run: run) { [weak window] in
                    window?.close()
                }
                .modelContext(modelContext)
                .frame(minWidth: 760, idealWidth: 840, minHeight: 640, idealHeight: 760)
            )
            positionWindowAboveDock(window)
            window.makeKeyAndOrderFront(nil)

            self.window = window
            presentedRunID = run.id
        }

        private func positionWindowAboveDock(_ window: NSWindow) {
            guard let screen = NSScreen.main else {
                window.center()
                return
            }
            let visibleFrame = screen.visibleFrame
            let frame = window.frame
            let centeredX = visibleFrame.midX - frame.width / 2
            let raisedCenterY = visibleFrame.midY - frame.height / 2 + 90
            let maximumY = visibleFrame.maxY - frame.height - 24
            let minimumY = visibleFrame.minY + 80
            let originY = min(max(raisedCenterY, minimumY), maximumY)
            window.setFrameOrigin(NSPoint(x: centeredX, y: originY))
        }
    }
}

private struct TestKeyCaptureView: NSViewRepresentable {
    let isActive: Bool
    let onTab: () -> Bool
    let onReturn: () -> Bool
    let onDigit: (Int) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        KeyCaptureNSView()
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.isActive = isActive
        nsView.onTab = onTab
        nsView.onReturn = onReturn
        nsView.onDigit = onDigit
        DispatchQueue.main.async {
            guard isActive, nsView.window?.firstResponder !== nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class KeyCaptureNSView: NSView {
        var isActive = false
        var onTab: (() -> Bool)?
        var onReturn: (() -> Bool)?
        var onDigit: ((Int) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override var focusRingType: NSFocusRingType {
            get { .none }
            set {}
        }

        override func keyDown(with event: NSEvent) {
            guard isActive,
                  !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option) else {
                super.keyDown(with: event)
                return
            }
            if event.keyCode == 48, onTab?() == true {
                return
            }
            if [36, 76].contains(event.keyCode), onReturn?() == true {
                return
            }
            if let character = event.charactersIgnoringModifiers?.first,
               let value = Int(String(character)),
               (1...4).contains(value),
               onDigit?(value) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}
#endif
