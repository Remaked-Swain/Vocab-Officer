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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var automaticSyncMessage: String?
    @State private var automaticSyncIsRunning = false

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
        .safeAreaInset(edge: .bottom) {
            if let automaticSyncMessage {
                HStack(spacing: 8) {
                    Image(systemName: automaticSyncIsRunning ? "arrow.triangle.2.circlepath.icloud" : "icloud")
                    Text(automaticSyncMessage)
                        .lineLimit(2)
                    Spacer()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .task {
            await runAutomaticCloudSync(reason: "앱 실행")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await runAutomaticCloudSync(reason: "앱 활성화") }
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
            VocabIOSSyncStatusView()
        }
    }

    private func runAutomaticCloudSync(reason: String) async {
        guard !ProcessInfo.processInfo.isRunningXCTestForVocabIOSRootView else { return }
        guard !automaticSyncIsRunning else { return }
        automaticSyncIsRunning = true
        automaticSyncMessage = "\(reason): iCloud 자동 동기화 조건을 확인하는 중입니다."
        defer { automaticSyncIsRunning = false }

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
            let result = try await VocabCloudSnapshotSyncService().runBatchSyncIfReady(
                context: modelContext,
                readiness: readiness
            )
            automaticSyncMessage = "\(reason): \(batchSyncMessage(for: result.action))"
        } catch {
            automaticSyncMessage = "\(reason): \(userFacingSyncError(error))"
        }
    }

    private func batchSyncMessage(for action: VocabCloudBatchSyncAction) -> String {
        switch action {
        case .uploadLocalSnapshot:
            return "iPhone 학습 변경 사항을 iCloud에 업로드했습니다."
        case .downloadCloudSnapshot:
            return "iCloud 변경 사항을 이 iPhone에 반영했습니다."
        case .alreadyInSync:
            return "이미 최신 동기화 상태입니다."
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

private struct VocabIOSSetListView: View {
    @Query(sort: \DailySetRecord.createdAt, order: .reverse) private var sets: [DailySetRecord]
    @Query(
        filter: #Predicate<WordRecord> { $0.deletedAt == nil },
        sort: \WordRecord.normalizedTerm
    ) private var words: [WordRecord]

    var body: some View {
        List {
            if sets.isEmpty {
                ContentUnavailableView("학습세트 없음", systemImage: "rectangle.stack", description: Text("macOS 단어장이 iCloud로 동기화되면 여기서 볼 수 있습니다."))
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sortedItems) { item in
                    if let word = wordsByID[item.wordID] {
                        VocabIOSWordCard(word: word)
                    }
                }
            }
            .padding(16)
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
                ContentUnavailableView("복습 대상 없음", systemImage: "checkmark.circle", description: Text("복습이 필요한 단어가 생기면 여기에 표시됩니다."))
            } else {
                ForEach(reviewStates.compactMap(\.word)) { word in
                    VocabIOSWordSummaryRow(word: word)
                }
            }
        }
    }
}

private struct VocabIOSTestSetupView: View {
    @Query(
        filter: #Predicate<WordRecord> { $0.deletedAt == nil },
        sort: \WordRecord.createdAt,
        order: .reverse
    ) private var words: [WordRecord]

    @State private var currentIndex = 0
    @State private var showMeaning = false

    var body: some View {
        VStack(spacing: 20) {
            if let word = currentWord {
                VocabIOSWordCard(word: word, showsMeaning: showMeaning)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                            showMeaning.toggle()
                        }
                    }

                HStack {
                    Button("이전") {
                        move(by: -1)
                    }
                    .disabled(currentIndex == 0)

                    Spacer()

                    Text("\(currentIndex + 1) / \(words.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("다음") {
                        move(by: 1)
                    }
                    .disabled(currentIndex >= words.count - 1)
                }
            } else {
                ContentUnavailableView("테스트할 단어 없음", systemImage: "checkmark.rectangle", description: Text("단어장이 동기화된 뒤 이동 중에도 카드 테스트를 볼 수 있습니다."))
            }
        }
        .padding(20)
    }

    private var currentWord: WordRecord? {
        guard words.indices.contains(currentIndex) else { return nil }
        return words[currentIndex]
    }

    private func move(by offset: Int) {
        currentIndex = min(max(currentIndex + offset, 0), max(words.count - 1, 0))
        showMeaning = false
    }
}

private struct VocabIOSSyncStatusView: View {
    @Environment(\.modelContext) private var modelContext
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
            Section("저장 상태") {
                LabeledContent("현재 모드", value: VocabSyncMode.current().displayName)
                LabeledContent("CloudKit", value: VocabSyncMode.cloudKitContainerIdentifier)
            }

            Section("iCloud 준비 상태") {
                Label(cloudKitState.title, systemImage: cloudKitState.isReadyForSync ? "checkmark.icloud" : "icloud")
                Text(cloudKitState.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await checkCloudKitStatus() }
                } label: {
                    if isChecking {
                        ProgressView()
                    } else {
                        Text("iCloud 상태 확인")
                    }
                }
                .disabled(isChecking)
            }

            Section("단어장 가져오기") {
                Button {
                    Task { await inspectCloudSnapshot() }
                } label: {
                    if isInspectingSnapshot {
                        Label("확인 중", systemImage: "doc.text.magnifyingglass")
                    } else {
                        Label("가져올 스냅샷 확인", systemImage: "doc.text.magnifyingglass")
                    }
                }
                .disabled(!canInspectSnapshot)

                Button {
                    showImportConfirmation = true
                } label: {
                    if isImporting {
                        Label("가져오는 중", systemImage: "icloud.and.arrow.down")
                    } else {
                        Label("iCloud에서 Mac 단어장 가져오기", systemImage: "icloud.and.arrow.down")
                    }
                }
                .disabled(!canImportSnapshot)

                if let cloudSnapshotSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("가져올 스냅샷")
                            .font(.headline)
                        Text("\(cloudSnapshotSummary.wordCount)개 단어 · \(cloudSnapshotSummary.dailySetCount)개 학습세트")
                        Text("업로드 시각: \(cloudSnapshotSummary.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.callout)
                }

                if isInspectingSnapshot {
                    ProgressView("iCloud 스냅샷 정보를 확인하는 중입니다.")
                }

                if isImporting {
                    ProgressView("iCloud 스냅샷을 가져오는 중입니다.")
                }

                Text("가져오기는 이 iPhone의 Vocab 로컬 데이터를 iCloud 스냅샷으로 교체합니다. iPhone 쪽 기존 Vocab 데이터는 되돌릴 수 없지만, macOS 원본 단어장은 삭제하지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let syncMessage {
                    Label(syncMessage, systemImage: syncMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(syncMessageIsError ? .red : .green)
                        .font(.callout)
                }
            }

            Section("자동 iCloud batch 동기화 조건") {
                ForEach(readiness.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(blocker.title)
                            .font(.headline)
                        Text(blocker.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Text("앱 실행 및 활성화 시점에 네트워크, 저전력 모드, iCloud 권한, 기준 스냅샷을 확인한 뒤 안전한 경우에만 자동 batch 동기화를 수행합니다. 위의 가져오기 버튼은 최초 기준점 생성 및 수동 복구용 스냅샷 가져오기입니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

    private var readiness: VocabCloudSyncReadiness {
        VocabCloudSyncReadinessPolicy.current(accountState: cloudKitState)
    }

    private var canInspectSnapshot: Bool {
        cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.hasRequiredCloudKitContainer()
            && !isInspectingSnapshot
            && !isImporting
    }

    private var canImportSnapshot: Bool {
        cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.hasRequiredCloudKitContainer()
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
            guard let result = try await VocabCloudSnapshotSyncService().replaceLocalStoreFromCloud(context: modelContext) else {
                syncMessage = "iCloud에 아직 가져올 단어장 스냅샷이 없습니다. 먼저 Mac에서 업로드하세요."
                syncMessageIsError = true
                return
            }
            cloudSnapshotSummary = result
            syncMessage = "\(result.wordCount)개 단어와 \(result.dailySetCount)개 학습세트를 가져왔습니다."
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
        VStack(alignment: .leading, spacing: 12) {
            Text(word.term)
                .font(.system(size: 34, weight: .bold, design: .rounded))
            if showsMeaning {
                Text(meaningsText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("탭해서 의미 보기")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var meaningsText: String {
        word.meanings.map(\.text).joined(separator: ", ")
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
