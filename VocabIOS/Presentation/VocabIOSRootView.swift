import CoreData
import SwiftData
import SwiftUI

private enum VocabIOSTab: String, CaseIterable, Identifiable {
    case sets = "학습세트"
    case review = "복습"
    case test = "테스트"
    case settings = "설정"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sets:
            "rectangle.stack"
        case .review:
            "arrow.clockwise.circle"
        case .test:
            "checkmark.rectangle"
        case .settings:
            "gearshape"
        }
    }
}

struct VocabIOSRootView: View {
    let connectionError: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var hydrationState: VocabHydrationState = .awaitingBootstrapMetadata
    @State private var hydrationMessage: String?
    @State private var cloudKitState: VocabCloudKitAccountState = .unknown
    @State private var claimStatus: VocabBootstrapServerClaimStatus = .unavailable("bootstrap claim을 아직 확인하지 않았습니다.")
    @State private var completedMetadataMissingSince: Date?
    @State private var isRefreshingConnection = false
    @State private var reconciliationWorker: VocabCloudReconciliationWorker?
    @State private var refreshQueue = VocabHydrationRefreshQueue()
    @State private var localContentIsUsable = VocabSyncRuntimeStateStore.persistedLocalContentIsUsable()

    var body: some View {
        TabView {
            ForEach(VocabIOSTab.allCases) { tab in
                NavigationStack {
                    content(for: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(tab.rawValue)
                }
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.symbol)
                }
            }
        }
        .task { await requestConnectionRefresh(reason: .initial) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            VocabMutationAuthorityRuntime.beginValidationEpoch()
            Task { await requestConnectionRefresh(reason: .foreground) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            guard VocabHydrationDiagnosticPolicy.shouldRefresh(reason: .remoteStoreChange, state: hydrationState) else { return }
            VocabMutationAuthorityRuntime.invalidate()
            Task {
                await VocabSyncWorkBarrier.shared.notePotentialStoreChange()
                await requestConnectionRefresh(reason: .remoteStoreChange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { notification in
            guard let source = notification.object as? ModelContext,
                  source.container === modelContext.container else { return }
            let changes = VocabModelContextChangeEvent.changes(from: notification, context: source)
            Task {
                await VocabSyncWorkBarrier.shared.notePotentialStoreChange()
                await VocabImportedIdentifierBuffer.shared.capture(
                    changes.records,
                    requiresFullAudit: changes.requiresFullAudit
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { notification in
            guard VocabHydrationDiagnosticPolicy.isSuccessfulImportEvent(notification) else { return }
            VocabMutationAuthorityRuntime.invalidate()
            Task {
                await VocabSyncWorkBarrier.shared.notePotentialStoreChange()
                await requestConnectionRefresh(reason: .successfulImport)
            }
        }
    }

    @ViewBuilder
    private func content(for tab: VocabIOSTab) -> some View {
        if let connectionError, tab != .settings {
            ContentUnavailableView(
                "iCloud 연결 오류",
                systemImage: "icloud.slash",
                description: Text(connectionError + " 설정 탭에서 연결 상태를 확인하세요.")
            )
        } else if !localContentIsUsable, hydrationState != .ready, tab != .settings {
            ContentUnavailableView(
                "iCloud 연결 준비 중",
                systemImage: "icloud",
                description: Text(hydrationDescription)
            )
        } else {
            switch tab {
        case .sets:
            VocabIOSSetListView()
        case .review:
            VocabIOSReviewListView()
        case .test:
            VocabIOSTestSetupView()
        case .settings:
                VocabIOSConnectionStatusView(
                    connectionError: connectionError,
                    cloudKitState: cloudKitState,
                    claimStatus: claimStatus,
                    hydrationState: hydrationState,
                    hydrationMessage: hydrationMessage,
                    isChecking: isRefreshingConnection,
                    refresh: { await requestConnectionRefresh(reason: .manual) }
                )
            }
        }
    }

    @MainActor
    private func requestConnectionRefresh(reason: VocabHydrationRefreshReason) async {
        guard await VocabSyncRuntimeStateStore.shared.shouldRunDiagnostic(reason: reason) else { return }
        guard await refreshQueue.enqueue(reason) else { return }
        isRefreshingConnection = true
        defer { isRefreshingConnection = false }

        while let nextReason = await refreshQueue.dequeue() {
            await refreshConnectionStatus(reason: nextReason)
        }
    }

    @MainActor
    private func refreshConnectionStatus(reason: VocabHydrationRefreshReason) async {
        do {
            let worker = await ensureReconciliationWorker()
            if reason == .successfulImport {
                let result = try await worker.reconcileImportedChanges(syncMode: .cloudKitPrivate)
                hydrationState = result.state
                hydrationMessage = result.message
                completedMetadataMissingSince = nil
            } else {
                async let account = VocabCloudKitStatusService().accountStatus()
                async let serverClaim = VocabCloudKitBootstrapClaimService().fixedClaimStatus()
                let fetchedClaim = await serverClaim
                claimStatus = fetchedClaim
                let status = try await worker.hydrationStatus(syncMode: .cloudKitPrivate)
                let needsReconciliation = VocabHydrationDiagnosticPolicy.shouldReconcile(
                    reason: reason,
                    state: status.state
                )
                let fullAuditIsDue = await VocabSyncRuntimeStateStore.shared.shouldRunFullAudit()
                let currentEpochRequiresAudit = (reason == .initial || reason == .foreground)
                    && VocabMutationAuthorityRuntime.current == .integrityBlocked
                let scheduledAuditIsDue = status.state == .ready
                    && (fullAuditIsDue || currentEpochRequiresAudit)
                if needsReconciliation || scheduledAuditIsDue {
                    let result = try await worker.auditAll(syncMode: .cloudKitPrivate)
                    hydrationState = result.state
                    hydrationMessage = result.message
                    await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted()
                } else {
                let diagnosis = VocabHydrationDiagnosticPolicy.diagnose(
                    localStatus: status,
                    claimStatus: fetchedClaim,
                    completedMetadataMissingSince: completedMetadataMissingSince
                )
                completedMetadataMissingSince = diagnosis.completedMetadataMissingSince
                hydrationState = diagnosis.state
                hydrationMessage = diagnosis.message
                }
                cloudKitState = await account
            }
            if hydrationState == .ready {
                localContentIsUsable = true
            }
            if let authority = VocabMutationAuthorityPolicy.authority(for: hydrationState) {
                VocabMutationAuthorityRuntime.set(authority)
            }
            await VocabSyncRuntimeStateStore.shared.markDiagnosticCompleted(state: hydrationState)
        } catch {
            hydrationState = .failed
            hydrationMessage = error.localizedDescription
            if let authority = VocabMutationAuthorityPolicy.authority(for: error) {
                VocabMutationAuthorityRuntime.set(authority)
            }
        }
    }

    @MainActor
    private func ensureReconciliationWorker() async -> VocabCloudReconciliationWorker {
        if let reconciliationWorker { return reconciliationWorker }
        let worker = await VocabCloudReconciliationWorkerFactory.make(
            modelContainer: modelContext.container
        )
        reconciliationWorker = worker
        return worker
    }

    private var hydrationDescription: String {
        let base = "현재 상태: \(hydrationState.rawValue). iPhone은 bootstrap seed를 수행하지 않습니다."
        guard let hydrationMessage, !hydrationMessage.isEmpty else { return base }
        return base + "\n\n" + hydrationMessage
    }
}

private struct VocabIOSConnectionStatusView: View {
    let connectionError: String?
    let cloudKitState: VocabCloudKitAccountState
    let claimStatus: VocabBootstrapServerClaimStatus
    let hydrationState: VocabHydrationState
    let hydrationMessage: String?
    let isChecking: Bool
    let refresh: () async -> Void

    var body: some View {
        List {
            Section("iCloud 연결") {
                LabeledContent("저장 방식", value: "SwiftData per-record mirroring")
                LabeledContent("계정 상태", value: cloudKitState.message)
                LabeledContent("Mac bootstrap", value: claimDescription)
                LabeledContent("Hydration", value: hydrationState.rawValue)
                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let hydrationMessage, hydrationState == .failed {
                    Label(hydrationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if hydrationState == .ready {
                    Label("mirrored 저장소에 연결되었습니다. iPhone의 기존 로컬 snapshot은 iCloud로 올리지 않습니다.", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                } else {
                    Label("metadata와 예상 레코드를 기다리고 있습니다. 이 상태에서는 쓰기 작업을 하지 않습니다.", systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                Text("CloudKit 가져오기는 시스템이 네트워크와 전원 상태를 고려해 수행합니다. 이 버튼은 서버 전송을 강제하지 않고, 도착한 레코드와 현재 연결 상태를 즉시 다시 확인합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isChecking ? "확인 중" : "가져오기 상태 다시 확인") {
                    guard VocabHydrationDiagnosticPolicy.shouldRefresh(reason: .manual, state: hydrationState) else { return }
                    Task { await refresh() }
                }
                .disabled(isChecking)
            }
        }
    }

    private var claimDescription: String {
        switch claimStatus {
        case .missing:
            "Mac 최초 전환 필요"
        case .available(let claim) where claim.state == .claimed || claim.state == .seeding:
            "Mac 업로드 중"
        case .available(let claim) where claim.state == .completed:
            "Mac 업로드 완료"
        case .available:
            "확인 오류"
        case .unavailable:
            "확인 오류"
        }
    }
}

private struct CompactEmptyState: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
    }
}

private struct VocabIOSSetListView: View {
    @Query(
        filter: #Predicate<DailySetRecord> { $0.deletedAt == nil },
        sort: \DailySetRecord.createdAt,
        order: .reverse
    ) private var sets: [DailySetRecord]
    @Query(
        filter: #Predicate<WordRecord> { $0.deletedAt == nil },
        sort: \WordRecord.normalizedTerm
    ) private var words: [WordRecord]

    var body: some View {
        List {
            if sets.isEmpty {
                CompactEmptyState(
                    title: "학습세트 없음",
                    systemImage: "rectangle.stack",
                    description: "macOS 단어장이 iCloud로 동기화되면 여기서 볼 수 있습니다."
                )
            } else {
                ForEach(sets) { set in
                    NavigationLink {
                        VocabIOSSetDetailView(dailySet: set, wordsByID: wordsByID)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(set.seoulDay)
                                .font(.headline)
                            Text("\(set.allItems.filter { $0.deletedAt == nil }.count)개 단어")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var wordsByID: [UUID: WordRecord] {
        Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
    }
}

private struct VocabIOSSetDetailView: View {
    let dailySet: DailySetRecord
    let wordsByID: [UUID: WordRecord]
    @State private var faceStates: [UUID: Bool] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sortedItems) { item in
                    if let word = wordsByID[item.wordID] {
                        VocabIOSFlipWordCard(
                            word: word,
                            showsMeaning: Binding(
                                get: { faceStates[item.id] ?? false },
                                set: { faceStates[item.id] = $0 }
                            )
                        )
                    }
                }
            }
            .padding(12)
        }
        .navigationTitle(dailySet.seoulDay)
    }

    private var sortedItems: [DailySetItemRecord] {
        dailySet.allItems.filter { $0.deletedAt == nil }.sorted { lhs, rhs in
            lhs.orderIndex < rhs.orderIndex
        }
    }
}

private struct VocabIOSReviewListView: View {
    @Query(
        filter: #Predicate<ReviewStateRecord> { $0.activePriority > 0 },
        sort: \ReviewStateRecord.activePriority,
        order: .reverse
    ) private var reviewStates: [ReviewStateRecord]

    var body: some View {
        List {
            if reviewStates.isEmpty {
                CompactEmptyState(
                    title: "복습 대상 없음",
                    systemImage: "checkmark.circle",
                    description: "복습이 필요한 단어가 생기면 여기에 표시됩니다."
                )
            } else {
                ForEach(reviewStates.compactMap(\.word).filter { $0.deletedAt == nil }) { word in
                    VocabIOSWordSummaryRow(word: word)
                }
            }
        }
    }
}

private struct VocabIOSTestSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<DailySetRecord> { $0.deletedAt == nil }) private var sets: [DailySetRecord]
    @State private var mode: SessionMode = .mixed
    @State private var direction: PracticeDirection = .enToKo
    @State private var selectedSetID: UUID?
    @State private var activeRun: VocabIOSTestRun?
    @State private var error: String?

    private var orderedSets: [DailySetRecord] {
        sets.sorted(by: newestSetFirst)
    }

    var body: some View {
        List {
            Section {
                Text("Mac과 동일한 세션 생성, 자동 채점, 최종 보정, 복습 기록 갱신 규칙으로 20문항 테스트를 진행합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("테스트 설정") {
                Picker("모드", selection: $mode) {
                    ForEach(SessionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Picker("방향", selection: $direction) {
                    ForEach(PracticeDirection.allCases) { direction in
                        Text(direction.rawValue).tag(direction)
                    }
                }

                if mode == .set {
                    Picker("대상 세트", selection: $selectedSetID) {
                        ForEach(orderedSets) { set in
                            Text("\(set.seoulDay) 세트").tag(Optional(set.id))
                        }
                    }
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    start()
                } label: {
                    Label("테스트 시작", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onAppear {
            if selectedSetID == nil {
                selectedSetID = orderedSets.first?.id
            }
        }
        .sheet(item: $activeRun) { run in
            NavigationStack {
                VocabIOSTestRunnerView(run: run)
            }
        }
    }

    private func start() {
        do {
            let result = try LearningCoordinator(context: modelContext, syncMode: .cloudKitPrivate).generateSession(
                mode: mode,
                direction: direction,
                setID: selectedSetID
            )
            activeRun = VocabIOSTestRun(session: result.0, questions: result.1)
            error = nil
        } catch {
            activeRun = nil
            self.error = error.localizedDescription
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

private struct VocabIOSTestRun: Identifiable {
    let session: TestSessionRecord
    let questions: [SessionQuestion]
    var id: UUID { session.id }
}

private struct VocabIOSWordCard: View {
    let word: WordRecord
    var showsMeaning = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(word.term)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.72)
            if showsMeaning {
                Text(meaningsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("탭해서 의미 보기")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var meaningsText: String {
        word.activeMeanings.map(\.text).joined(separator: ", ")
    }
}

private struct VocabIOSFlipWordCard: View {
    let word: WordRecord
    @Binding var showsMeaning: Bool

    var body: some View {
        Button {
            withAnimation(.bouncy(duration: 0.42, extraBounce: 0.10)) {
                showsMeaning.toggle()
            }
        } label: {
            ZStack {
                cardFace(title: "English", value: word.term, isBack: false)
                    .opacity(showsMeaning ? 0 : 1)
                    .rotation3DEffect(.degrees(showsMeaning ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                cardFace(title: "의미", value: meaningsText, isBack: true)
                    .opacity(showsMeaning ? 1 : 0)
                    .rotation3DEffect(.degrees(showsMeaning ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
            }
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132)
            .shadow(color: showsMeaning ? .accentColor.opacity(0.16) : .black.opacity(0.06), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word.term)
        .accessibilityValue(showsMeaning ? meaningsText : "영단어 앞면")
        .accessibilityHint("눌러서 카드 앞뒤를 전환합니다")
    }

    private var meaningsText: String {
        word.activeMeanings.map(\.text).joined(separator: ", ")
    }

    private func cardFace(title: String, value: String, isBack: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(
                colors: isBack
                    ? [Color.accentColor.opacity(0.24), Color.green.opacity(0.10)]
                    : [Color.primary.opacity(0.06), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isBack ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.22), lineWidth: 1.2)
            }
            .overlay {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(isBack ? .callout.weight(.medium) : .title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                }
                .padding(14)
            }
    }
}

private struct VocabIOSTestRunnerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let run: VocabIOSTestRun

    @State private var index = 0
    @State private var answer = ""
    @State private var judgeResult: JudgeResult?
    @State private var chosenResult: FinalResult?
    @State private var correctedMeaningID: UUID?
    @State private var addAlias = false
    @State private var notice: String?
    @FocusState private var answerFocused: Bool

    private var question: SessionQuestion? {
        run.questions.indices.contains(index) ? run.questions[index] : nil
    }

    var body: some View {
        if let question {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(run.session.modeRaw)
                            .font(.headline)
                        Spacer()
                        Text("\(index + 1) / \(run.questions.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: Double(index), total: Double(run.questions.count))

                    Text(question.direction.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(question.prompt)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                        .padding()
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    TextField("답안을 입력하세요", text: $answer)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .focused($answerFocused)
                        .submitLabel(.done)
                        .onSubmit(submitForJudgement)
                        .disabled(judgeResult != nil)

                    if let judgeResult {
                        resultPanel(judgeResult, question: question)
                    } else {
                        HStack {
                            Button("제출", action: submitForJudgement)
                                .buttonStyle(.borderedProminent)
                            Button("모름", action: markUnknown)
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    }

                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("테스트")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { answerFocused = true }
        } else {
            CompactEmptyState(
                title: "출제 문항이 없습니다",
                systemImage: "exclamationmark.triangle",
                description: "테스트할 단어가 동기화된 뒤 다시 시도하세요."
            )
        }
    }

    @ViewBuilder
    private func resultPanel(_ result: JudgeResult, question: SessionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자동 판정: \(display(result.automaticResult))", systemImage: result.automaticResult == .correct ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(result.automaticResult == .correct ? .green : .orange)

            if result.automaticResult != .unknown {
                VStack(alignment: .leading, spacing: 6) {
                    Text("원문: \(question.word.term)")
                    Text("등록 의미: \(question.word.activeMeanings.map(\.text).joined(separator: ", "))")
                    Text("입력 답안: \(answer.isEmpty ? "(입력 없음)" : answer)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Picker("최종 판정", selection: Binding(get: { chosenResult ?? result.automaticResult }, set: { chosenResult = $0 })) {
                Text("정답").tag(FinalResult.correct)
                Text("오답").tag(FinalResult.incorrect)
                Text("모름").tag(FinalResult.unknown)
            }
            .pickerStyle(.segmented)

            if (chosenResult ?? result.automaticResult) == .correct && result.automaticResult != .correct {
                if question.direction == .enToKo {
                    Picker("확인한 핵심 뜻", selection: $correctedMeaningID) {
                        ForEach(question.word.correctionCandidateMeanings) { meaning in
                            Text(meaning.text).tag(Optional(meaning.id))
                        }
                    }
                }
                Toggle("이 답안을 허용 답안으로 추가", isOn: $addAlias)
            }

            Button(index + 1 == run.questions.count ? "완료" : "확정 후 다음", action: commitAndAdvance)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func submitForJudgement() {
        guard let question, judgeResult == nil else { return }
        let result = LearningCoordinator(context: modelContext, syncMode: .cloudKitPrivate).judge(answer: answer, for: question)
        judgeResult = result
        chosenResult = result.automaticResult
        correctedMeaningID = question.direction == .enToKo ? question.word.defaultCorrectionMeaningID : nil
    }

    private func markUnknown() {
        guard let question else { return }
        judgeResult = JudgeResult(automaticResult: .unknown, matchedMeaningID: nil, isTypoSuggestion: false)
        chosenResult = .unknown
        correctedMeaningID = question.direction == .enToKo ? question.word.defaultCorrectionMeaningID : nil
    }

    private func commitAndAdvance() {
        guard let judgeResult, let question else { return }
        let final = chosenResult ?? judgeResult.automaticResult
        if final == .correct,
           judgeResult.automaticResult != .correct,
           question.direction == .enToKo,
           correctedMeaningID == nil {
            notice = "정답으로 보정하려면 확인한 핵심 뜻을 선택하세요."
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
            try LearningCoordinator(context: modelContext, syncMode: .cloudKitPrivate).commit(
                answer: answer,
                result: final,
                automatic: judgeResult.automaticResult,
                matchedMeaningID: finalMeaningID,
                question: question,
                session: run.session,
                correction: final == judgeResult.automaticResult ? nil : (addAlias ? "acceptedAlias" : "oneTimeCorrection")
            )
            if index + 1 == run.questions.count {
                run.session.completedAt = .now
                try modelContext.save()
                NotificationCenter.default.post(name: .vocabLearningStoreDidChange, object: nil)
                dismiss()
            } else {
                index += 1
                answer = ""
                self.judgeResult = nil
                chosenResult = nil
                correctedMeaningID = nil
                addAlias = false
                notice = nil
                answerFocused = true
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func display(_ result: FinalResult) -> String {
        switch result {
        case .correct:
            "정답"
        case .incorrect:
            "오답"
        case .unknown:
            "모름"
        }
    }
}

private struct VocabIOSWordSummaryRow: View {
    let word: WordRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(word.term)
                .font(.headline)
            Text(word.activeMeanings.map(\.text).joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
