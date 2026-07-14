import CloudKit
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
    let launchWarning: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var automaticSyncMessage: String?
    @State private var automaticSyncIsRunning = false
    @State private var automaticSyncPendingReason: String?
    @State private var automaticSyncDebounceTask: Task<Void, Never>?

    var body: some View {
        TabView {
            ForEach(VocabIOSTab.allCases) { tab in
                NavigationStack {
                    content(for: tab)
                        .navigationTitle(tab.rawValue)
                }
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.symbol)
                }
            }
        }
        .task {
            if automaticSyncMessage == nil, let launchWarning {
                automaticSyncMessage = launchWarning
            }
            await runAutomaticCloudSync(reason: "앱 실행")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await runAutomaticCloudSync(reason: "앱 활성화") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vocabLearningStoreDidChange)) { _ in
            scheduleAutomaticCloudSync(reason: "학습 데이터 변경")
        }
    }

    @ViewBuilder
    private func content(for tab: VocabIOSTab) -> some View {
        switch tab {
        case .sets:
            VocabIOSSetListView()
        case .review:
            VocabIOSReviewListView()
        case .test:
            VocabIOSTestSetupView()
        case .settings:
            VocabIOSSyncStatusView(
                automaticSyncMessage: automaticSyncMessage,
                automaticSyncIsRunning: automaticSyncIsRunning
            )
        }
    }

    private func scheduleAutomaticCloudSync(reason: String) {
        automaticSyncDebounceTask?.cancel()
        automaticSyncDebounceTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await runAutomaticCloudSync(reason: reason)
        }
    }

    private func runAutomaticCloudSync(reason: String) async {
        guard !ProcessInfo.processInfo.isRunningXCTestForVocabIOSRootView else { return }
        guard !automaticSyncIsRunning else {
            automaticSyncPendingReason = reason
            return
        }
        automaticSyncIsRunning = true
        automaticSyncMessage = "\(reason): iCloud 자동 동기화 조건을 확인하는 중입니다."
        defer {
            automaticSyncIsRunning = false
            if let pendingReason = automaticSyncPendingReason {
                automaticSyncPendingReason = nil
                scheduleAutomaticCloudSync(reason: pendingReason)
            }
        }

        let accountState = await VocabCloudKitStatusService().accountStatus()
        let conditions = await VocabCloudSyncNetworkMonitor.currentRuntimeConditions()
        let readiness = VocabCloudSyncReadinessPolicy.current(
            accountState: accountState,
            runtimeConditions: conditions
        )
        guard readiness.isReadyForBatchSync else {
            automaticSyncMessage = "\(reason): \(readiness.blockers.first?.message ?? "자동 동기화 조건이 충족되지 않았습니다.")"
            return
        }

        do {
            let result = try await VocabCloudSnapshotSyncService(
                localStoreCheckpointCreator: { now in
                    try VocabLocalStoreCheckpointStore.createDefaultStoreCheckpoint(now: now)
                }
            ).runBatchSyncIfReady(
                context: modelContext,
                readiness: readiness
            )
            automaticSyncMessage = "\(reason): \(batchSyncMessage(for: result))"
        } catch {
            automaticSyncMessage = "\(reason): \(userFacingSyncError(error))"
        }
    }

    private func batchSyncMessage(for result: VocabCloudBatchSyncResult) -> String {
        switch result.action {
        case .uploadLocalSnapshot:
            return "iPhone 학습 변경 사항을 iCloud에 업로드했습니다."
        case .downloadCloudSnapshot:
            if let checkpointDirectoryName = result.snapshotResult?.checkpointDirectoryName {
                return "iCloud 변경 사항을 이 iPhone에 반영했습니다. 보호 사본: \(checkpointDirectoryName)"
            }
            return "iCloud 변경 사항을 이 iPhone에 반영했습니다."
        case .alreadyInSync:
            let localCount = result.local.dailySetCount
            let cloudCount = result.cloud?.dailySetCount ?? localCount
            return "이미 최신 동기화 상태입니다. 이 iPhone \(localCount)개 세트 · iCloud \(cloudCount)개 세트"
        case .blocked:
            return "현재 조건에서는 자동 동기화를 실행하지 않았습니다."
        case .conflict:
            return "이 iPhone 또는 iCloud가 동기화 중 변경되어 자동 적용을 중단했습니다. 수동 확인이 필요합니다."
        }
    }

    private func userFacingSyncError(_ error: Error) -> String {
        if error is CKError {
            return "iCloud 요청을 완료하지 못했습니다. 네트워크, iCloud 로그인, 앱 권한을 확인하세요."
        }
        if error is VocabSyncSnapshotService.SnapshotValidationError {
            return "iCloud 단어장 데이터가 현재 앱에서 복원할 수 없는 형식입니다."
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "iCloud 자동 동기화 중 문제가 발생했습니다."
    }
}

private extension ProcessInfo {
    var isRunningXCTestForVocabIOSRootView: Bool {
        environment["XCTestConfigurationFilePath"] != nil
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
    @Query(sort: \DailySetRecord.createdAt, order: .reverse) private var sets: [DailySetRecord]
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
                            Text("\(set.items.count)개 단어")
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
        dailySet.items.sorted { lhs, rhs in
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
                ForEach(reviewStates.compactMap(\.word)) { word in
                    VocabIOSWordSummaryRow(word: word)
                }
            }
        }
    }
}

private struct VocabIOSTestSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var sets: [DailySetRecord]
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
            let result = try LearningCoordinator(context: modelContext).generateSession(
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

private struct VocabIOSSyncStatusView: View {
    @Environment(\.modelContext) private var modelContext
    let automaticSyncMessage: String?
    let automaticSyncIsRunning: Bool

    @State private var cloudKitState: VocabCloudKitAccountState = .unknown
    @State private var isChecking = false
    @State private var isInspectingSnapshot = false
    @State private var isImporting = false
    @State private var showImportConfirmation = false
    @State private var cloudSnapshotSummary: VocabCloudSnapshotSyncResult?
    @State private var syncMessage: String?
    @State private var syncMessageIsError = false

    var body: some View {
        List {
            Section {
                Text("Mac에서 올린 스냅샷을 iPhone에 가져와 기준점을 만든 뒤, 앱 실행/활성화 때 자동 동기화가 작동합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("동기화를 켜는 순서") {
                SyncStepRow(
                    index: 1,
                    title: "iCloud 상태 확인",
                    detail: cloudKitState.message,
                    systemImage: cloudKitState.isReadyForSync ? "checkmark.icloud" : "icloud"
                ) {
                    Button {
                        Task { await checkCloudKitStatus() }
                    } label: {
                        if isChecking {
                            Label("확인 중", systemImage: "icloud")
                        } else {
                            Text("iCloud 상태 확인")
                        }
                    }
                    .disabled(isChecking)
                }

                SyncStepRow(
                    index: 2,
                    title: "Mac 스냅샷 확인",
                    detail: "Mac에서 업로드한 단어장 스냅샷이 iCloud에 있는지 확인합니다.",
                    systemImage: "doc.text.magnifyingglass"
                ) {
                    Button {
                        Task { await inspectCloudSnapshot() }
                    } label: {
                        if isInspectingSnapshot {
                            Label("확인 중", systemImage: "doc.text.magnifyingglass")
                        } else {
                            Text("가져올 스냅샷 확인")
                        }
                    }
                    .disabled(!canInspectSnapshot)
                }

                SyncStepRow(
                    index: 3,
                    title: "iPhone에 가져오기",
                    detail: "확인한 스냅샷으로 이 iPhone의 Vocab 로컬 데이터를 교체합니다.",
                    systemImage: "icloud.and.arrow.down"
                ) {
                    Button {
                        showImportConfirmation = true
                    } label: {
                        if isImporting {
                            Label("가져오는 중", systemImage: "icloud.and.arrow.down")
                        } else {
                            Text("Mac 단어장 가져오기")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImportSnapshot)
                }

                SyncStepRow(
                    index: 4,
                    title: "기준점 생성 후 자동 sync",
                    detail: "가져오기가 완료되면 보호 사본과 기준점이 만들어지고 이후 안전 조건에서 자동 동기화합니다.",
                    systemImage: "arrow.triangle.2.circlepath.icloud"
                ) {
                    EmptyView()
                }
            }

            Section("스냅샷 및 진행 상태") {
                snapshotSummaryView

                if isInspectingSnapshot {
                    ProgressView("iCloud 스냅샷 정보를 확인하는 중입니다.")
                }

                if isImporting {
                    ProgressView("iCloud 스냅샷을 가져오는 중입니다.")
                }

                if let syncMessage {
                    Label(syncMessage, systemImage: syncMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(syncMessageIsError ? .red : .green)
                        .font(.footnote)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("가져오기는 이 iPhone의 Vocab 로컬 데이터를 iCloud 스냅샷으로 교체합니다. macOS 원본 단어장은 삭제하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let automaticSyncMessage {
                Section("자동 sync 상태") {
                    Label(automaticSyncMessage, systemImage: automaticSyncIsRunning ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("상세 상태") {
                LabeledContent("현재 모드", value: VocabSyncMode.current().displayName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CloudKit")
                        .font(.subheadline)
                    Text(VocabSyncMode.cloudKitContainerIdentifier)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DisclosureGroup("자동 iCloud batch 동기화 조건") {
                    Text("앱 실행 및 활성화 시점에 네트워크, 저전력 모드, iCloud 권한, 기준 스냅샷을 확인한 뒤 안전한 경우에만 자동 batch 동기화를 수행합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                    if readiness.blockers.isEmpty {
                        Label("자동 동기화 조건 충족", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }

                    ForEach(readiness.blockers) { blocker in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(blocker.title)
                                .font(.footnote.weight(.semibold))
                            Text(blocker.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .confirmationDialog(
            "이 iPhone의 Vocab 데이터를 교체할까요?",
            isPresented: $showImportConfirmation,
            titleVisibility: .visible
        ) {
            Button("교체하고 가져오기", role: .destructive) {
                Task { await importSnapshotFromCloud() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(importConfirmationMessage)
        }
    }

    @ViewBuilder
    private var snapshotSummaryView: some View {
        if let cloudSnapshotSummary {
            VStack(alignment: .leading, spacing: 4) {
                Text("가져올 스냅샷")
                    .font(.headline)
                Text("\(cloudSnapshotSummary.wordCount)개 단어 · \(cloudSnapshotSummary.dailySetCount)개 학습세트")
                Text("업로드 시각: \(cloudSnapshotSummary.exportedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.callout)
        } else {
            Text("먼저 iCloud 상태를 확인하고 Mac 스냅샷을 조회하세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private struct SyncStepRow<Action: View>: View {
        let index: Int
        let title: String
        let detail: String
        let systemImage: String
        @ViewBuilder var action: () -> Action

        init(
            index: Int,
            title: String,
            detail: String,
            systemImage: String,
            @ViewBuilder action: @escaping () -> Action
        ) {
            self.index = index
            self.title = title
            self.detail = detail
            self.systemImage = systemImage
            self.action = action
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.blue, in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(title)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: systemImage)
                        }
                        .font(.callout.weight(.semibold))

                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }

                action()
                    .controlSize(.small)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var readiness: VocabCloudSyncReadiness {
        VocabCloudSyncReadinessPolicy.current(accountState: cloudKitState)
    }

    private var canInspectSnapshot: Bool {
        cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.allowsCloudKitRequests()
            && !isInspectingSnapshot
            && !isImporting
    }

    private var canImportSnapshot: Bool {
        cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.allowsCloudKitRequests()
            && !isImporting
            && cloudSnapshotSummary != nil
    }

    private var importConfirmationMessage: String {
        guard let cloudSnapshotSummary else {
            return "먼저 가져올 스냅샷을 확인하세요."
        }
        return "\(cloudSnapshotSummary.wordCount)개 단어와 \(cloudSnapshotSummary.dailySetCount)개 학습세트로 이 iPhone의 Vocab 로컬 데이터를 교체합니다. 이 iPhone의 기존 Vocab 데이터는 되돌릴 수 없습니다."
    }

    private func checkCloudKitStatus() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        cloudKitState = await VocabCloudKitStatusService().accountStatus()
    }

    private func inspectCloudSnapshot() async {
        guard !isInspectingSnapshot else { return }
        isInspectingSnapshot = true
        syncMessage = nil
        syncMessageIsError = false
        defer { isInspectingSnapshot = false }

        do {
            guard let result = try await VocabCloudSnapshotSyncService().inspectCloudSnapshot() else {
                cloudSnapshotSummary = nil
                syncMessage = "iCloud에 아직 가져올 단어장 스냅샷이 없습니다. 먼저 Mac에서 업로드하세요."
                syncMessageIsError = true
                return
            }
            cloudSnapshotSummary = result
            syncMessage = "가져올 스냅샷을 확인했습니다."
        } catch {
            cloudSnapshotSummary = nil
            syncMessage = userFacingSyncError(error)
            syncMessageIsError = true
        }
    }

    private func importSnapshotFromCloud() async {
        guard !isImporting else { return }
        guard cloudSnapshotSummary != nil else {
            syncMessage = "먼저 가져올 스냅샷을 확인하세요."
            syncMessageIsError = true
            return
        }
        isImporting = true
        syncMessage = nil
        syncMessageIsError = false
        defer { isImporting = false }

        do {
            guard let result = try await VocabCloudSnapshotSyncService(
                localStoreCheckpointCreator: { now in
                    try VocabLocalStoreCheckpointStore.createDefaultStoreCheckpoint(now: now)
                }
            ).replaceLocalStoreFromCloud(context: modelContext) else {
                syncMessage = "iCloud에 아직 가져올 단어장 스냅샷이 없습니다. 먼저 Mac에서 업로드하세요."
                syncMessageIsError = true
                return
            }
            cloudSnapshotSummary = result
            if let checkpointDirectoryName = result.checkpointDirectoryName {
                syncMessage = "\(result.wordCount)개 단어와 \(result.dailySetCount)개 학습세트를 가져왔습니다. 보호 사본: \(checkpointDirectoryName)"
            } else {
                syncMessage = "\(result.wordCount)개 단어와 \(result.dailySetCount)개 학습세트를 가져왔습니다."
            }
        } catch {
            syncMessage = userFacingSyncError(error)
            syncMessageIsError = true
        }
    }

    private func userFacingSyncError(_ error: Error) -> String {
        if error is CKError {
            return "iCloud 요청을 완료하지 못했습니다. iCloud 로그인, 네트워크 상태, 앱의 iCloud 권한을 확인한 뒤 다시 시도하세요."
        }
        if error is VocabSyncSnapshotService.SnapshotValidationError {
            return "iCloud 단어장 데이터가 현재 앱에서 복원할 수 없는 형식입니다. Mac에서 다시 업로드한 뒤 시도하세요."
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "iCloud에서 단어장을 가져오는 중 문제가 발생했습니다. iCloud 로그인, 네트워크 상태, 앱 서명 권한을 확인한 뒤 다시 시도하세요."
    }
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
        word.meanings.map(\.text).joined(separator: ", ")
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
        word.meanings.map(\.text).joined(separator: ", ")
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
                    Text("등록 의미: \(question.word.meanings.map(\.text).joined(separator: ", "))")
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
        let result = LearningCoordinator(context: modelContext).judge(answer: answer, for: question)
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
                if question.direction == .enToKo, let meaning = question.word.meanings.first(where: { $0.id == correctedMeaningID }) {
                    meaning.aliases.append(answer)
                } else if question.direction == .koToEn {
                    question.word.englishAliases.append(answer)
                }
            }
            let finalMeaningID = final == .correct && question.direction == .enToKo
                ? (judgeResult.matchedMeaningID ?? correctedMeaningID)
                : judgeResult.matchedMeaningID
            try LearningCoordinator(context: modelContext).commit(
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
            Text(word.meanings.map(\.text).joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
