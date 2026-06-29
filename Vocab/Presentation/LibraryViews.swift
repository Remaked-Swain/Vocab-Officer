import SwiftData
import SwiftUI

struct StudyCardsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DailySetRecord.createdAt, order: .reverse) private var sets: [DailySetRecord]
    @State private var selectedSetID: UUID?
    @State private var selectedEntries: [StudyCardEntry] = []
    @State private var showingDiscardConfirmation = false
    @State private var editingWord: WordRecord?
    @State private var message: String?
    @State private var isError = false
    @State private var isLoadingCards = false

    private var selectedSet: DailySetRecord? {
        sets.first { $0.id == selectedSetID } ?? sets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("학습 카드")
                .font(.largeTitle.weight(.semibold))
            Text("입력한 세트별로 카드를 클릭하거나 Return 키를 눌러 원문과 의미를 뒤집어 확인하세요.")
                .font(.body)
                .foregroundStyle(.secondary)

            Picker("학습 세트", selection: Binding(
                get: { selectedSet?.id },
                set: { selectedSetID = $0 }
            )) {
                ForEach(sets) { set in
                    Text("\(set.seoulDay) 세트  (\(set.items.count)개)")
                        .tag(Optional(set.id))
                }
            }
            .pickerStyle(.menu)
            .controlSize(.large)
            .frame(maxWidth: 360, alignment: .leading)

            Text("보관된 학습 세트: \(sets.count)개")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("현재 보관된 학습 세트는 \(sets.count)개입니다.")

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isError ? .red : .green)
            }

            if isLoadingCards {
                ProgressView("카드를 불러오는 중...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedEntries.isEmpty {
                ContentUnavailableView("학습할 세트가 없습니다", systemImage: "rectangle.stack")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 16)], spacing: 16) {
                        ForEach(selectedEntries) { entry in
                            FlipWordCard(word: entry.word) {
                                editingWord = entry.word
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(28)
        .navigationTitle("학습 카드")
        .task(id: selectedSet?.id) {
            loadSelectedEntries()
        }
        .toolbar {
            ToolbarItem {
                Button("선택 세트 폐기", role: .destructive) {
                    showingDiscardConfirmation = true
                }
                .disabled(selectedSet == nil)
            }
        }
        .confirmationDialog(
            "선택한 단어 세트를 폐기할까요?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("세트 폐기", role: .destructive) {
                discardSelectedSet()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 세트에만 포함된 단어는 단어장과 기록에서 삭제됩니다. 다른 세트에도 포함된 단어는 해당 세트 연결만 제거됩니다.")
        }
        .sheet(item: $editingWord) { word in
            WordEditSheet(word: word) { message, isError in
                self.message = message
                self.isError = isError
            }
        }
    }

    private func discardSelectedSet() {
        guard let selectedSet else { return }
        do {
            try LearningCoordinator(context: context).discardDailySet(selectedSet)
            selectedSetID = sets.first { $0.id != selectedSet.id }?.id
            message = "\(selectedSet.seoulDay) 세트를 폐기했습니다."
            isError = false
        } catch {
            message = error.localizedDescription
            isError = true
        }
    }

    private func loadSelectedEntries() {
        guard let selectedSet else {
            selectedEntries = []
            return
        }
        isLoadingCards = true
        defer { isLoadingCards = false }

        let sortedItems = selectedSet.items.sorted { $0.orderIndex < $1.orderIndex }
        let ids = Array(Set(sortedItems.map(\.wordID)))
        guard !ids.isEmpty else {
            selectedEntries = []
            return
        }

        do {
            let descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { word in
                    ids.contains(word.id) && word.deletedAt == nil
                }
            )
            let fetchedWords = try context.fetch(descriptor)
            let wordsByID = Dictionary(uniqueKeysWithValues: fetchedWords.map { ($0.id, $0) })
            selectedEntries = sortedItems.compactMap { item in
                wordsByID[item.wordID].map { StudyCardEntry(item: item, word: $0) }
            }
        } catch {
            selectedEntries = []
            message = error.localizedDescription
            isError = true
        }
    }
}

private struct StudyCardEntry: Identifiable {
    let id: UUID
    let word: WordRecord

    init(item: DailySetItemRecord, word: WordRecord) {
        id = item.id
        self.word = word
    }
}

private struct FlipWordCard: View {
    let word: WordRecord
    let onEdit: () -> Void
    @State private var showsMeaning = false

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
                    cardFace(title: "의미", value: word.meanings.map(\.text).joined(separator: ", "), isBack: true)
                        .opacity(showsMeaning ? 1 : 0)
                        .rotation3DEffect(.degrees(showsMeaning ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                }
                .scaleEffect(showsMeaning ? 1.025 : 1.0)
                .shadow(color: showsMeaning ? .accentColor.opacity(0.24) : .black.opacity(0.08), radius: showsMeaning ? 18 : 8, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)

            Button("수정") { onEdit() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(8)
        }
        .frame(minHeight: 146)
        .accessibilityLabel(word.term)
        .accessibilityValue(showsMeaning ? word.meanings.map(\.text).joined(separator: ", ") : "영단어 앞면")
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
    }
}

struct ReviewView: View {
    @Query private var words: [WordRecord]

    var body: some View {
        let candidates = words
            .filter { $0.statusRaw == "active" && ($0.reviewState?.activePriority ?? 0) > 0 }
            .sorted { ($0.reviewState?.activePriority ?? 0) > ($1.reviewState?.activePriority ?? 0) }

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
}

private struct ReviewWordCard: View {
    let word: WordRecord

    private var meaning: String {
        word.meanings.map(\.text).joined(separator: ", ")
    }

    private var failureCheck: Int {
        word.reviewState?.failureCheck ?? 0
    }

    private var activePriority: Int {
        word.reviewState?.activePriority ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(word.term)
                .font(.title3.weight(.semibold))

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
    @State private var linkedWordIDs = Set<UUID>()
    @State private var selection = Set<UUID>()
    @State private var showingDeleteConfirmation = false
    @State private var showingAddWord = false
    @State private var editingWord: WordRecord?
    @State private var message: String?
    @State private var isError = false
    @State private var batch = 0
    @State private var canLoadMore = true
    @State private var isLoadingWords = false

    private let batchSize = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isError ? .red : .green)
                    .padding(.horizontal)
            }

            List(selection: $selection) {
                ForEach(displayedWords) { word in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(word.term).font(.title3.weight(.semibold))
                            Text(word.meanings.map(\.text).joined(separator: ", "))
                                .font(.body)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(word.statusRaw.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(word.statusRaw == "mastered" ? Color.green : Color.secondary)
                                if !linkedWordIDs.contains(word.id) {
                                    Text("낱개")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                        Spacer()
                        Button("수정") { editingWord = word }
                            .controlSize(.large)
                    }
                    .padding(.vertical, 5)
                    .tag(word.id)
                }

                libraryLoadingFooter
            }
        }
        .searchable(text: $searchText, prompt: "영단어 검색")
        .navigationTitle("단어장")
        .task {
            reloadWordList()
        }
        .onChange(of: searchText) {
            reloadWordList()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("낱개 단어 추가") {
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
            Text("선택한 단어와 뜻, 시도 기록, 세트 및 테스트 세션 연결이 삭제됩니다. 이 작업은 앱 안에서 되돌릴 수 없습니다.")
        }
        .sheet(item: $editingWord) { word in
            WordEditSheet(word: word) { message, isError in
                self.message = message
                self.isError = isError
                reloadWordList()
            }
        }
        .sheet(isPresented: $showingAddWord) {
            LooseWordAddSheet { message, isError in
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
        linkedWordIDs = []
        loadNextWordBatch()
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
            refreshLinkedWordIDs(for: displayedWords)
        } catch {
            message = error.localizedDescription
            isError = true
            canLoadMore = false
        }
    }

    private func fetchWordBatch(batch: Int) throws -> [WordRecord] {
        let normalizedSearch = TextNormalizer.normalizeEnglish(searchText)
        var descriptor: FetchDescriptor<WordRecord>
        if normalizedSearch.isEmpty {
            descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.normalizedTerm)]
            )
        } else {
            descriptor = FetchDescriptor<WordRecord>(
                predicate: #Predicate { word in
                    word.deletedAt == nil && word.normalizedTerm.contains(normalizedSearch)
                },
                sortBy: [SortDescriptor(\.normalizedTerm)]
            )
        }
        descriptor.fetchLimit = batchSize
        descriptor.fetchOffset = batch * batchSize
        return try context.fetch(descriptor)
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

    private func refreshLinkedWordIDs(for words: [WordRecord]) {
        let ids = Array(Set(words.map(\.id)))
        guard !ids.isEmpty else {
            linkedWordIDs = []
            return
        }
        do {
            let descriptor = FetchDescriptor<DailySetItemRecord>(
                predicate: #Predicate { item in
                    ids.contains(item.wordID)
                }
            )
            linkedWordIDs = Set(try context.fetch(descriptor).map(\.wordID))
        } catch {
            linkedWordIDs = []
        }
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AttemptRecord.answeredAt, order: .reverse) private var attempts: [AttemptRecord]
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("상세 로그는 학습 품질 계산용 요약 상태와 별개입니다. 최근 기록은 유지하고, 오래된 정답과 만료된 오답/모름은 정리해 앱 크기 증가를 제한합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
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
        _meaningsText = State(initialValue: word.meanings.map(\.text).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("단어 직접 수정")
                .font(.title.weight(.semibold))
            Text("OCR 오인식이나 오입력된 낱개 카드를 수정합니다. 이 값은 단어장의 단일 진실 공급원(SOT)을 직접 바꾸며, Mastered 단어를 수정하면 다시 활성 단어가 됩니다.")
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

private struct LooseWordAddSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onComplete: (String, Bool) -> Void
    @State private var term = ""
    @State private var meaningsText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("낱개 단어 추가")
                .font(.title.weight(.semibold))
            Text("일일 100개 세트에 포함하지 않고 단어장 SOT에만 저장합니다. 기존 표제어가 있으면 새 단어를 만들지 않고 뜻만 병합합니다.")
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
                Button("낱개 단어 저장") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meaningsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(minWidth: 460)
    }

    private func save() {
        do {
            let word = try LearningCoordinator(context: context).addLooseWord(term: term, meaningsText: meaningsText)
            onComplete("\(word.term)을 낱개 단어로 저장했습니다.", false)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            onComplete(error.localizedDescription, true)
        }
    }
}
