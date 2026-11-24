import AVFoundation
import SwiftData
import SwiftUI

struct StudyCardsView: View {
    @Query(
        filter: #Predicate<WordRecord> { $0.deletedAt == nil },
        sort: \WordRecord.createdAt,
        order: .reverse
    ) private var words: [WordRecord]
    @Binding var faceStates: [UUID: Bool]
    @State private var groups: [RegistrationDayGroup] = []
    @State private var selectedDay: String?
    @State private var editingWord: WordRecord?
    @State private var message: String?
    @State private var isError = false

    private var effectiveSelectedDay: String? {
        selectedDay.flatMap { day in
            groups.contains { $0.day == day } ? day : nil
        } ?? groups.first?.day
    }

    var body: some View {
        let day = effectiveSelectedDay
        let cards = groups.first { $0.day == day }?.words ?? []
        VStack(alignment: .leading, spacing: 16) {
            Text("최초 등록일별로 묶인 카드입니다. 카드를 클릭하면 원문과 의미가 뒤집히며, 학습 진도에는 영향을 주지 않습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let message {
                FeedbackPanel(items: [
                    FeedbackItem(
                        text: message,
                        systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle",
                        color: isError ? .red : .green
                    )
                ])
                .accessibilityLabel("학습 카드 상태 안내")
            }

            HStack(spacing: 12) {
                Picker("등록일", selection: Binding(
                    get: { day },
                    set: { selectedDay = $0 }
                )) {
                    ForEach(groups) { group in
                        Text("\(group.day)  ·  \(group.words.count)개")
                            .tag(Optional(group.day))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(maxWidth: 320, alignment: .leading)

                Spacer()

                Text("등록일 \(groups.count)개 · 전체 \(words.count)단어")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("등록일 그룹은 \(groups.count)개이며 전체 단어는 \(words.count)개입니다.")
            }

            if cards.isEmpty {
                ContentUnavailableView(
                    "학습할 단어가 없습니다",
                    systemImage: "rectangle.stack",
                    description: Text("오늘 입력에서 단어를 등록하면 등록일별 카드가 만들어집니다.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: VocabMetrics.cardGridColumns, spacing: VocabMetrics.cardGridSpacing) {
                        ForEach(cards) { word in
                            WordFlipCard(
                                word: word,
                                showsMeaning: Binding(
                                    get: { faceStates[word.id] ?? false },
                                    set: { faceStates[word.id] = $0 }
                                )
                            ) {
                                StudyCardActions(word: word) {
                                    editingWord = word
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(28)
        .onChange(of: words, initial: true) { _, newWords in
            groups = RegistrationDayGroup.groups(from: newWords)
        }
        .sheet(item: $editingWord) { word in
            WordEditSheet(word: word) { message, isError in
                self.message = message
                self.isError = isError
            }
        }
    }

}

/// Memory aid, pronunciation and edit actions shown on a Mac learning card.
private struct StudyCardActions: View {
    let word: WordRecord
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            WordMemoryAidButton(word: word)

            Button {
                WordPronouncer.shared.speak(headword: word.term, meanings: word.activeMeanings.map(\.text))
            } label: {
                Image(systemName: "speaker.wave.2.fill")
            }
            .help("원문과 의미 읽기")
            .accessibilityLabel("\(word.term) 원문과 의미 읽기")

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .help("단어 수정")
            .accessibilityLabel("\(word.term) 수정")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

@MainActor
private final class WordPronouncer {
    static let shared = WordPronouncer()

    private let synthesizer = AVSpeechSynthesizer()

    private init() {}

    func speak(headword: String, meanings: [String]) {
        let normalizedHeadword = headword.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMeaning = meanings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !normalizedHeadword.isEmpty || !normalizedMeaning.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        if !normalizedHeadword.isEmpty {
            let headwordUtterance = AVSpeechUtterance(string: normalizedHeadword)
            headwordUtterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            headwordUtterance.rate = 0.42
            headwordUtterance.pitchMultiplier = 1.0
            headwordUtterance.volume = 1.0
            headwordUtterance.postUtteranceDelay = normalizedMeaning.isEmpty ? 0 : 0.18
            synthesizer.speak(headwordUtterance)
        }

        if !normalizedMeaning.isEmpty {
            let meaningUtterance = AVSpeechUtterance(string: normalizedMeaning)
            meaningUtterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
            meaningUtterance.rate = 0.4
            meaningUtterance.pitchMultiplier = 1.0
            meaningUtterance.volume = 1.0
            synthesizer.speak(meaningUtterance)
        }
    }
}

struct ReviewView: View {
    @Query(filter: #Predicate<ReviewStateRecord> { $0.activePriority > 0 })
    private var states: [ReviewStateRecord]

    var body: some View {
        // Ordering reads mutable review fields, so it is derived per render from the
        // already-filtered priority query rather than cached by membership.
        let candidates = ReviewCandidateList.words(from: states)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("복습 우선도가 높은 단어부터 보여 줍니다. 테스트의 복습·혼합 모드가 이 단어들을 먼저 출제합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if !candidates.isEmpty {
                    Text("\(candidates.count)단어")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if candidates.isEmpty {
                ContentUnavailableView(
                    "우선 복습할 단어가 없습니다",
                    systemImage: "checkmark.circle",
                    description: Text("테스트에서 틀리거나 모름으로 답한 단어가 여기에 모입니다.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: VocabMetrics.cardGridColumns, spacing: VocabMetrics.cardGridSpacing) {
                        ForEach(candidates) { word in
                            ReviewWordCard(word: word) {
                                WordMemoryAidButton(word: word)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(28)
    }
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @State private var searchText = ""
    @State private var displayedWords: [WordRecord] = []
    @State private var selection = Set<UUID>()
    @State private var showingDeleteConfirmation = false
    @State private var showingAddWord = false
    @State private var editingWord: WordRecord?
    @State private var message: String?
    @State private var isError = false
    @State private var batch = 0
    @State private var canLoadMore = true
    @State private var isLoadingWords = false
    @State private var matchedSearchWordIDs: [UUID]?

    private let batchSize = 150

    var body: some View {
        List(selection: $selection) {
            ForEach(displayedWords) { word in
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(word.term)
                                .font(.title3.weight(.semibold))
                            StatusBadge(title: word.learningStatusTitle, tint: word.learningStatus.tint)
                        }
                        Text(word.meaningsDisplayText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    WordMemoryAidButton(word: word)
                    Button {
                        editingWord = word
                    } label: {
                        Label("수정", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 5)
                .tag(word.id)
                .contextMenu {
                    Button("수정", systemImage: "pencil") { editingWord = word }
                }
            }

            libraryLoadingFooter
        }
        // The status panel rides above the list instead of sharing a VStack with
        // it, so the List alone sizes to the window.
        .safeAreaInset(edge: .top) {
            if let message {
                FeedbackPanel(items: [
                    FeedbackItem(
                        text: message,
                        systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle",
                        color: isError ? .red : .green
                    )
                ])
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityLabel("단어장 상태 안내")
            }
        }
        .searchable(text: $searchText, prompt: "영단어 또는 의미 검색")
        .overlay {
            if displayedWords.isEmpty, !canLoadMore, !isLoadingWords {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "등록된 단어가 없습니다",
                        systemImage: "books.vertical",
                        description: Text("오늘 입력 또는 단어 등록으로 단어를 추가하세요.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .task {
            reloadWordList()
        }
        .onChange(of: searchText) {
            reloadWordList()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingAddWord = true
                } label: {
                    Label("단어 등록", systemImage: "plus")
                }
                .help("단어 등록")
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(selection.isEmpty ? "선택 단어 삭제" : "\(selection.count)개 삭제", systemImage: "trash")
                }
                .help("선택한 단어 삭제")
                .disabled(selection.isEmpty)
            }
        }
        .confirmationDialog(
            "선택한 단어를 삭제할까요?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("\(selection.count)개 단어 삭제", role: .destructive) {
                deleteSelection()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("선택한 단어와 뜻, 시도 기록 및 테스트 세션 연결이 삭제됩니다. 이 작업은 앱 안에서 되돌릴 수 없습니다.")
        }
        .sheet(item: $editingWord) { word in
            WordEditSheet(word: word) { message, isError in
                self.message = message
                self.isError = isError
                reloadWordList()
            }
        }
        .sheet(isPresented: $showingAddWord) {
            VocabularyRegistrationSheet { message, isError in
                self.message = message
                self.isError = isError
                reloadWordList()
            }
        }
    }

    private var libraryLoadingFooter: some View {
        HStack {
            Spacer()
            if isLoadingWords {
                ProgressView()
                    .controlSize(.small)
            } else if canLoadMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("더 불러오는 중...")
                        .foregroundStyle(.secondary)
                }
                .onAppear {
                    loadNextWordBatch()
                }
            } else if displayedWords.isEmpty {
                EmptyView()
            } else {
                Text("표시된 단어 \(displayedWords.count)개")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.vertical, 10)
    }

    private func deleteSelection() {
        let ids = selection
        let targets: [WordRecord]
        do {
            targets = try fetchWords(ids: ids)
        } catch {
            message = error.localizedDescription
            isError = true
            return
        }
        do {
            try LearningCoordinator(context: context).deleteWords(targets)
            selection.removeAll()
            message = "\(targets.count)개 단어를 삭제했습니다."
            isError = false
            reloadWordList()
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func reloadWordList() {
        batch = 0
        canLoadMore = true
        selection.removeAll()
        displayedWords = []
        do {
            matchedSearchWordIDs = try WordLibrarySearch(context: context).resolveWordIDs(for: searchText)
            loadNextWordBatch()
        } catch {
            matchedSearchWordIDs = []
            canLoadMore = false
            message = error.localizedDescription
            isError = true
        }
    }

    private func loadNextWordBatch() {
        guard !isLoadingWords, canLoadMore else { return }
        isLoadingWords = true
        defer { isLoadingWords = false }

        do {
            let fetched = try fetchWordBatch(batch: batch)
            if fetched.count < batchSize {
                canLoadMore = false
            }
            batch += 1
            displayedWords.append(contentsOf: fetched)
        } catch {
            message = error.localizedDescription
            isError = true
            canLoadMore = false
        }
    }

    private func fetchWordBatch(batch: Int) throws -> [WordRecord] {
        if let matchedSearchWordIDs {
            let start = batch * batchSize
            guard start < matchedSearchWordIDs.count else { return [] }

            let end = min(start + batchSize, matchedSearchWordIDs.count)
            let batchIDs = Array(matchedSearchWordIDs[start..<end])
            let descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { word in
                    batchIDs.contains(word.id) && word.deletedAt == nil
                }
            )
            let fetched = try context.fetch(descriptor)
            let wordsByID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            return batchIDs.compactMap { wordsByID[$0] }
        } else {
            var descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.normalizedTerm)]
            )
            descriptor.fetchLimit = batchSize
            descriptor.fetchOffset = batch * batchSize
            return try context.fetch(descriptor)
        }
    }

    private func fetchWords(ids: Set<UUID>) throws -> [WordRecord] {
        let ids = Array(ids)
        let descriptor = FetchDescriptor<WordRecord>(
            predicate: #Predicate { word in
                ids.contains(word.id) && word.deletedAt == nil
            }
        )
        return try context.fetch(descriptor)
    }

}

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(
        filter: #Predicate<AttemptRecord> { $0.deletedAt == nil },
        sort: \AttemptRecord.answeredAt,
        order: .reverse
    ) private var attempts: [AttemptRecord]
    @State private var notice: String?

    var body: some View {
        // One List owns all scrolling, as in MasteredView.
        List {
            Section {
                Text("최근 답안 기록입니다. 학습 상태 계산은 별도 요약으로 유지되므로, 오래된 기록을 정리해도 진도는 바뀌지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let notice {
                    FeedbackPanel(items: [
                        FeedbackItem(
                            text: notice,
                            systemImage: "checkmark.circle",
                            color: .secondary
                        )
                    ])
                    .accessibilityLabel("학습 기록 상태 안내")
                }
            }
            if attempts.isEmpty {
                ContentUnavailableView(
                    "학습 기록이 없습니다",
                    systemImage: "chart.bar",
                    description: Text("테스트에서 답안을 확정하면 기록이 쌓입니다.")
                )
            } else {
                Section("\(attempts.count)건") {
                    ForEach(attempts) { attempt in
                        HistoryAttemptRow(attempt: attempt)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    compactHistory()
                } label: {
                    Label("오래된 기록 정리", systemImage: "archivebox")
                }
                .help("오래된 정답과 만료된 오답·모름 기록 정리")
            }
        }
    }

    private func compactHistory() {
        do {
            try LearningCoordinator(context: context).compactLearningHistory()
            notice = "오래된 상세 로그를 정리했습니다."
        } catch {
            notice = error.localizedDescription
        }
    }
}

private struct HistoryAttemptRow: View {
    let attempt: AttemptRecord

    var body: some View {
        let finalResult = FinalResult(rawValue: attempt.finalJudgementRaw)
        let direction = PracticeDirection(rawValue: attempt.directionRaw)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(attempt.prompt)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(direction?.shortTitle ?? attempt.directionRaw)
                    if !attempt.submittedAnswer.isEmpty,
                       attempt.questionFormatRaw == QuestionFormat.typed.rawValue {
                        Text("·")
                        Text("답안 \(attempt.submittedAnswer)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(attempt.answeredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if attempt.automaticJudgementRaw != attempt.finalJudgementRaw {
                StatusBadge(title: "보정됨", systemImage: "pencil", tint: .orange)
            }
            if let finalResult {
                StatusBadge(title: finalResult.title, systemImage: finalResult.systemImage, tint: finalResult.tint)
            } else {
                Text(attempt.finalJudgementRaw)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct WordEditSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let word: WordRecord
    let onComplete: (String, Bool) -> Void
    @State private var term: String
    @State private var meaningsText: String
    @State private var error: String?

    init(word: WordRecord, onComplete: @escaping (String, Bool) -> Void) {
        self.word = word
        self.onComplete = onComplete
        _term = State(initialValue: word.term)
        _meaningsText = State(initialValue: word.activeMeanings.map(\.text).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("단어 직접 수정")
                .font(.title.weight(.semibold))
            Text("OCR 오인식이나 오입력을 바로잡습니다. 단어장 원본이 바뀌며, 장기정착 단어를 수정하면 다시 학습 중으로 돌아갑니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("영단어", text: $term)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .controlSize(.large)
            Text("한국어 뜻")
                .font(.headline)
            TextEditor(text: $meaningsText)
                .font(.body)
                .frame(minHeight: 130)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
            Text("쉼표, 슬래시 또는 줄바꿈으로 여러 뜻을 구분합니다. 괄호 안 쉼표는 뜻의 일부로 보존합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .controlSize(.large)
                Button("수정 저장") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(28)
        .frame(minWidth: 460)
    }

    private func save() {
        do {
            try LearningCoordinator(context: context).updateWord(word, term: term, meaningsText: meaningsText)
            onComplete("\(word.term)을 수정했습니다.", false)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            onComplete(error.localizedDescription, true)
        }
    }
}

private struct VocabularyRegistrationSheet: View {
    private enum AddMode: String, CaseIterable, Identifiable {
        case single = "한 개"
        case batch = "여러 개"

        var id: String { rawValue }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onComplete: (String, Bool) -> Void
    @State private var mode: AddMode = .single
    @State private var term = ""
    @State private var meaningsText = ""
    @State private var batchInput = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("단어 등록")
                .font(.title.weight(.semibold))
            Text("단어장에 저장합니다. 이미 있는 표제어에는 새 뜻만 합쳐집니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("추가 방식", selection: $mode) {
                ForEach(AddMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)

            if mode == .single {
                TextField("영단어", text: $term)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .controlSize(.large)
                Text("한국어 뜻")
                    .font(.headline)
                TextEditor(text: $meaningsText)
                    .font(.body)
                    .frame(minHeight: 130)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
            } else {
                Text("형식: 0001-word-뜻 또는 word<TAB>뜻")
                    .font(.headline)
                TextEditor(text: $batchInput)
                    .font(.system(.title3, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary) }
            }
            Text(mode == .single
                 ? "쉼표 또는 슬래시로 여러 의미를 구분합니다. 괄호 안 쉼표는 한 의미로 보존됩니다."
                 : "한 줄에 한 단어씩 붙여넣으세요. 중복 표제어는 별도 단어를 만들지 않고 기존 단어에 합쳐집니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .controlSize(.large)
                Button(mode == .single ? "단어 저장" : "단어 일괄 저장") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
        }
        .padding(28)
        .frame(minWidth: 460)
    }

    private func save() {
        do {
            let drafts: [WordDraft]
            switch mode {
            case .single:
                drafts = [WordDraft(term: term, meanings: meaningsText)]
            case .batch:
                drafts = try DailyIntakePasteParser.parse(batchInput)
            }
            let result = try LearningCoordinator(context: context).registerWordsWithSummary(drafts)
            onComplete(VocabularyRegistrationFeedback.successMessage(for: result), false)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            onComplete(error.localizedDescription, true)
        }
    }

    private var canSave: Bool {
        switch mode {
        case .single:
            !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !meaningsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .batch:
            !batchInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
