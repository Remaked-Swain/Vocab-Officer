import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TestSetupView: View {
    @Environment(\.modelContext) private var context
    @State private var mode: SessionMode = .mixed
    @State private var direction: PracticeDirection = .enToKo
    @State private var format: QuestionFormat = .typed
    @State private var activeRun: TestRun?
    @State private var isStarting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("한 회차는 최대 20개의 고유 단어로 구성됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Form {
                Section {
                    Picker("모드", selection: $mode) {
                        ForEach(SessionMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(mode.setupDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Picker("방향", selection: $direction) {
                        ForEach(PracticeDirection.allCases, id: \.self) { direction in
                            Text(direction.shortTitle).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("시험 방식", selection: $format) {
                        ForEach(QuestionFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(format.setupDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .controlSize(.large)
            .frame(maxWidth: 620)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                // Prominent Mac buttons stay text-only: a symbol inside them can take
                // the accent fill color and vanish while the button is enabled.
                Button(format.startButtonTitle, action: start)
                .keyboardShortcut(.return, modifiers: .command)
                .help("⌘Return")
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
        let format = format
        Task { @MainActor in
            await Task.yield()
            do {
                let result = try LearningCoordinator(context: context).generateSession(mode: mode, direction: direction, format: format)
                activeRun = TestRun(session: result.0, questions: result.1)
            } catch let caughtError {
                activeRun = nil
                self.error = caughtError.localizedDescription
            }
            isStarting = false
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
    var onClose: (() -> Void)?
    @State private var index = 0
    @State private var answer = ""
    @State private var judgeResult: JudgeResult?
    @State private var chosenResult: FinalResult?
    @State private var correctedMeaningID: UUID?
    @State private var addAlias = false
    @State private var notice: String?
    @State private var tally = TestSessionTally()
    @State private var isCompleted = false
    @FocusState private var focus: FocusTarget?

    private var question: SessionQuestion? {
        run.questions.indices.contains(index) ? run.questions[index] : nil
    }

    var body: some View {
        if isCompleted {
            TestCompletionView(modeTitle: run.session.modeRaw, tally: tally, onClose: closeRunner)
                .frame(minWidth: 760, minHeight: 640)
        } else if let question {
            content(question)
        } else {
            ContentUnavailableView("출제 문항이 없습니다", systemImage: "exclamationmark.triangle")
                .padding(30)
        }
    }

    private func content(_ question: SessionQuestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TestProgressHeader(
                    modeTitle: run.session.modeRaw,
                    index: index,
                    total: run.questions.count,
                    reducedQuestionCount: run.session.wasReduced ? run.questions.count : nil
                )
                TestPromptCard(question: question)

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
                    HStack(spacing: 12) {
                        if question.format == .typed {
                            Button("제출", action: submitForJudgement)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .keyboardShortcut(.defaultAction)
                        }
                        Button("모름") {
                            judgeResult = JudgeResult(automaticResult: .unknown, matchedMeaningID: nil, isTypoSuggestion: false)
                            chosenResult = .unknown
                            correctedMeaningID = question.direction == .enToKo
                                ? question.word.defaultCorrectionMeaningID
                                : nil
                            focus = .advance
                        }
                        .controlSize(.large)
                        Spacer()
                        Text(question.format == .multipleChoice ? "1–4 선택 · Return 확정" : "Return 제출")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notice {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
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
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(Array(question.choices.enumerated()), id: \.element.id) { offset, option in
                ChoiceOptionButton(
                    number: offset + 1,
                    label: option.label,
                    appearance: .resolve(option: option, selectedAnswer: answer, isJudged: judgeResult != nil)
                ) {
                    selectChoice(option)
                }
                .disabled(judgeResult != nil)
                .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [])
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ result: JudgeResult, question: SessionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            JudgementBanner(result: result)
            if result.automaticResult != .unknown {
                AnswerComparisonView(question: question, submittedAnswer: displayedAnswer(for: question))
            }
            Divider()
            HStack(spacing: 10) {
                Picker("최종 판정", selection: Binding(get: { chosenResult ?? result.automaticResult }, set: { chosenResult = $0 })) {
                    ForEach(FinalResult.judgementOrder, id: \.self) { judgement in
                        Text(judgement.title).tag(judgement)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                .focused($focus, equals: .finalJudgement)
                Button("판정 전환") {
                    _ = cycleFinalJudgement()
                }
                .keyboardShortcut(.tab, modifiers: [])
                .controlSize(.small)
                .help("Tab")
            }
            if (chosenResult ?? result.automaticResult) == .correct && result.automaticResult != .correct {
                if question.direction == .enToKo {
                    Picker("확인한 핵심 뜻", selection: $correctedMeaningID) {
                        ForEach(question.word.correctionCandidateMeanings) { meaning in
                            Text(meaning.text).tag(Optional(meaning.id))
                        }
                    }
                    .frame(maxWidth: 420)
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
            HStack(alignment: .center) {
                Text("Return 확정 · Tab 판정 전환")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(index + 1 == run.questions.count ? "완료" : "확정 후 다음", action: commitAndAdvance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .focused($focus, equals: .advance)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous)
                .stroke((chosenResult ?? result.automaticResult).tint.opacity(0.35), lineWidth: 1)
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

    private func displayedAnswer(for question: SessionQuestion) -> String {
        guard question.format == .multipleChoice else { return answer.isEmpty ? "(입력 없음)" : answer }
        return question.choices.first { $0.id.uuidString == answer }?.label ?? "(선택 없음)"
    }

    private func cycleFinalJudgement() -> Bool {
        guard let judgeResult else { return false }
        let order = FinalResult.judgementOrder
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
            tally.record(final, forQuestionAt: index)
            if index + 1 == run.questions.count {
                try LearningCoordinator(context: context).completeSession(run.session)
                isCompleted = true
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
        Task { @MainActor [weak nsView] in
            guard let nsView, isActive, nsView.window?.firstResponder !== nsView else { return }
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
