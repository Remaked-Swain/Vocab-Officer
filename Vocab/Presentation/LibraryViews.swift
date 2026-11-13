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
    @State private var selectedDay: String?
    @State private var editingWord: WordRecord?
    @State private var message: String?
    @State private var isError = false
    private var registrationGroups: [RegistrationDayGroup] {
        Dictionary(grouping: words, by: \.registrationDay)
            .map { day, words in RegistrationDayGroup(day: day, words: words) }
            .sorted { $0.day > $1.day }
    }

    private func effectiveSelectedDay(in groups: [RegistrationDayGroup]) -> String? {
        selectedDay.flatMap { day in
            groups.contains { $0.day == day } ? day : nil
        } ?? groups.first?.day
    }

    private func selectedCards(in groups: [RegistrationDayGroup], day: String?) -> [StudyCardEntry] {
        guard let day else { return [] }
        return (groups.first { $0.day == day }?.words ?? [])
            .sorted {
                if $0.word.createdAt != $1.word.createdAt { return $0.word.createdAt < $1.word.createdAt }
                return $0.word.normalizedTerm < $1.word.normalizedTerm
            }
    }

    var body: some View {
        let groups = registrationGroups
        let day = effectiveSelectedDay(in: groups)
        let cards = selectedCards(in: groups, day: day)
        VStack(alignment: .leading, spacing: 18) {
            Text("학습 카드")
                .font(.largeTitle.weight(.semibold))
            Text("같은 날 등록한 단어를 모아 봅니다. 카드를 클릭하거나 Return 키를 눌러 원문과 의미를 뒤집으세요.")
                .font(.body)
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

            Picker("등록일", selection: Binding(
                get: { day },
                set: { selectedDay = $0 }
            )) {
                ForEach(groups) { group in
                    Text("\(group.day)  (\(group.words.count)개)")
                        .tag(Optional(group.day))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(maxWidth: 360, alignment: .leading)

            Text("등록일 그룹: \(groups.count)개 · 전체 단어: \(words.count)개")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("등록일 그룹은 \(groups.count)개이며 전체 단어는 \(words.count)개입니다.")

            if cards.isEmpty {
                ContentUnavailableView("학습할 단어가 없습니다", systemImage: "rectangle.stack")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        ForEach(cards) { entry in
                            FlipWordCard(
                                word: entry.word,
                                showsMeaning: Binding(
                                    get: { faceStates[entry.id] ?? false },
                                    set: { faceStates[entry.id] = $0 }
                                )
                            ) {
                                editingWord = entry.word
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
        .navigationTitle("학습 카드")
        .sheet(item: $editingWord) { word in
            WordEditSheet(word: word) { message, isError in
                self.message = message
                self.isError = isError
            }
        }
    }

}

private struct StudyCardEntry: Identifiable {
    let id: UUID
    let word: WordRecord

    init(word: WordRecord) {
        id = word.id
        self.word = word
    }
}

private struct RegistrationDayGroup: Identifiable {
    let day: String
    let words: [StudyCardEntry]

    var id: String { day }

    init(day: String, words: [WordRecord]) {
        self.day = day
        self.words = words.map { StudyCardEntry(word: $0) }
    }
}

private struct FlipWordCard: View {
    let word: WordRecord
    @Binding var showsMeaning: Bool
    let onEdit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(.bouncy(duration: 0.45, extraBounce: 0.12)) {
                    showsMeaning.toggle()
                }
            } label: {
                ZStack {
                    cardFace(title: "English", value: word.term, isBack: false)
                        .opacity(showsMeaning ? 0 : 1)
                        .rotation3DEffect(.degrees(showsMeaning ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                    cardFace(title: "의미", value: word.activeMeanings.map(\.text).joined(separator: ", "), isBack: true)
                        .opacity(showsMeaning ? 1 : 0)
                        .rotation3DEffect(.degrees(showsMeaning ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                }
                .frame(maxWidth: .infinity, minHeight: 146, maxHeight: 146)
                .shadow(color: showsMeaning ? .accentColor.opacity(0.20) : .black.opacity(0.08), radius: 10, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                WordMemoryAidButton(word: word)

                Button {
                    WordPronouncer.shared.speak(headword: word.term, meanings: word.activeMeanings.map(\.text))
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("원문과 의미 읽기")
                .accessibilityLabel("\(word.term) 원문과 의미 읽기")

                Button("수정") { onEdit() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, minHeight: 146, maxHeight: 146)
        .accessibilityLabel(word.term)
        .accessibilityValue(showsMeaning ? word.activeMeanings.map(\.text).joined(separator: ", ") : "영단어 앞면")
        .accessibilityHint("눌러서 카드 앞뒤를 전환합니다")
    }

    private func cardFace(title: String, value: String, isBack: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(
                colors: isBack ? [Color.accentColor.opacity(0.24), Color.green.opacity(0.10)] : [Color.primary.opacity(0.06), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isBack ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22), lineWidth: 1.2)
            }
            .overlay {
                VStack(spacing: 10) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(isBack ? .body.weight(.medium) : .title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                }
                .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Query private var states: [ReviewStateRecord]

    private var candidates: [WordRecord] {
        states
            .compactMap(\.word)
            .filter { $0.deletedAt == nil && $0.statusRaw == "active" && ($0.reviewState?.activePriority ?? 0) > 0 }
            .sorted(by: reviewFirst)
    }

    var body: some View {
        Group {
            if candidates.isEmpty {
                ContentUnavailableView("우선 복습할 단어가 없습니다", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        ForEach(candidates) { word in
                            ReviewWordCard(word: word)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(28)
        .navigationTitle("복습")
    }

    private func reviewFirst(_ lhs: WordRecord, _ rhs: WordRecord) -> Bool {
        let lhsState = lhs.reviewState
        let rhsState = rhs.reviewState

        if (lhsState?.activePriority ?? 0) != (rhsState?.activePriority ?? 0) {
            return (lhsState?.activePriority ?? 0) > (rhsState?.activePriority ?? 0)
        }
        if (lhsState?.failureCheck ?? 0) != (rhsState?.failureCheck ?? 0) {
            return (lhsState?.failureCheck ?? 0) > (rhsState?.failureCheck ?? 0)
        }
        if (lhsState?.lastPresentedAt ?? .distantPast) != (rhsState?.lastPresentedAt ?? .distantPast) {
            return (lhsState?.lastPresentedAt ?? .distantPast) < (rhsState?.lastPresentedAt ?? .distantPast)
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.term.localizedCaseInsensitiveCompare(rhs.term) == .orderedAscending
    }
}

private struct ReviewWordCard: View {
    let word: WordRecord

    private var meaning: String {
        word.activeMeanings.map(\.text).joined(separator: ", ")
    }

    private var failureCheck: Int {
        word.reviewState?.failureCheck ?? 0
    }

    private var activePriority: Int {
        word.reviewState?.activePriority ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(word.term)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                WordMemoryAidButton(word: word)
            }

            Text(meaning)
                .font(.body)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("체크 \(failureCheck)", systemImage: "checkmark.circle")
                Label("우선도 \(activePriority)", systemImage: "arrow.clockwise.circle")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1.2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("원문 \(word.term), 의미 \(meaning), 체크 \(failureCheck), 우선도 \(activePriority)")
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
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                FeedbackPanel(items: [
                    FeedbackItem(
                        text: message,
                        systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle",
                        color: isError ? .red : .green
                    )
                ])
                .padding(.horizontal)
                .accessibilityLabel("단어장 상태 안내")
            }

            List(selection: $selection) {
                ForEach(displayedWords) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(word.term).font(.title3.weight(.semibold))
                            Text(word.activeMeanings.map(\.text).joined(separator: ", "))
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text(word.statusRaw.capitalized)
                                .font(.caption)
                                .foregroundStyle(word.statusRaw == "mastered" ? Color.green : Color.secondary)
                        }
                        Spacer()
                        WordMemoryAidButton(word: word)
                        Button("수정") { editingWord = word }
                            .controlSize(.large)
                    }
                    .padding(.vertical, 5)
                    .tag(word.id)
                }

                libraryLoadingFooter
            }
        }
        .searchable(text: $searchText, prompt: "영단어 또는 의미 검색")
        .navigationTitle("단어장")
        .task {
            reloadWordList()
        }
        .onChange(of: searchText) {
            reloadWordList()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("단어 등록") {
                    showingAddWord = true
                }
                .controlSize(.large)
                Button("선택 단어 삭제", role: .destructive) {
                    showingDeleteConfirmation = true
                }
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
                Text("표시할 단어가 없습니다.")
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("상세 로그는 학습 품질 계산용 요약 상태와 별개입니다. 최근 기록은 유지하고, 오래된 정답과 만료된 오답/모름은 정리해 앱 크기 증가를 제한합니다.")
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
            List(attempts) { attempt in
            HStack {
                VStack(alignment: .leading) {
                    Text(attempt.prompt)
                        .font(.body)
                    Text(attempt.directionRaw)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if attempt.automaticJudgementRaw != attempt.finalJudgementRaw {
                    Text("보정됨")
                        .foregroundStyle(.orange)
                }
                Text(attempt.finalJudgementRaw)
            }
            .padding(.vertical, 5)
        }
        }
        .navigationTitle("학습 기록")
        .toolbar {
            ToolbarItem {
                Button("오래된 기록 정리") { compactHistory() }
                    .controlSize(.large)
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
            Text("OCR 오인식이나 오입력된 단어를 수정합니다. 이 값은 단어장의 단일 진실 공급원(SOT)을 직접 바꾸며, Mastered 단어를 수정하면 다시 활성 단어가 됩니다.")
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
                Button("SOT 수정 저장") { save() }
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
            Text("단어장 SOT에 저장합니다. 기존 표제어에는 아직 없는 뜻만 병합합니다.")
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
                 : "한 줄에 한 단어씩 붙여넣으세요. 중복 표제어는 별도 단어를 만들지 않고 SOT에 병합됩니다.")
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
            let words = try LearningCoordinator(context: context).registerWords(drafts)
            let message = mode == .single
                ? "\(words[0].term)을 단어장에 저장했습니다."
                : "단어 \(words.count)개를 저장했습니다. 중복 표제어는 기존 SOT에 병합했습니다."
            onComplete(message, false)
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
