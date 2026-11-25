import CoreData
import SwiftData
import SwiftUI

/// Tabs mirror the Mac sidebar's learning section in name, symbol and order.
private enum VocabIOSTab: String, CaseIterable, Identifiable {
    case test = "테스트"
    case study = "학습 카드"
    case review = "복습"
    case settings = "설정"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .test:
            "checkmark.rectangle"
        case .study:
            "rectangle.stack"
        case .review:
            "arrow.clockwise.circle"
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
    @State private var claimStatus: VocabBootstrapServerClaimStatus = .unavailable("Mac 최초 동기화 상태를 아직 확인하지 않았습니다.")
    @State private var completedMetadataMissingSince: Date?
    @State private var isRefreshingConnection = false
    @State private var reconciliationWorker: VocabCloudReconciliationWorker?
    @State private var refreshQueue = VocabHydrationRefreshQueue()
    @State private var localContentIsUsable = VocabSyncRuntimeStateStore.persistedLocalContentIsUsable()
    @State private var maintenanceAuditTask: Task<Void, Never>?
    @State private var maintenanceAuditSlot = VocabMaintenanceTaskSlot()
    @State private var masteryCleanupTask: Task<Void, Never>?
    @State private var masteryCleanupRetryTask: Task<Void, Never>?
    @State private var masteryCleanupPending = false
    @State private var masteryCleanupRetryCount = 0
    @State private var backgroundActivityMessage: String?
    @State private var backgroundActivityIsRunning = false
    @State private var activityClearTask: Task<Void, Never>?
    @State private var storeRevision = 0

    var body: some View {
        TabView {
            ForEach(VocabIOSTab.allCases) { tab in
                NavigationStack {
                    content(for: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle(tab.rawValue)
                        .environment(\.vocabStoreRevision, storeRevision)
                        // A bottom banner keeps long status text readable instead of
                        // squeezing it into the navigation bar.
                        .safeAreaInset(edge: .bottom) {
                            if let backgroundActivityMessage {
                                VocabIOSActivityBanner(
                                    message: backgroundActivityMessage,
                                    isRunning: backgroundActivityIsRunning
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: backgroundActivityMessage)
                }
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.symbol)
                }
            }
        }
        .task {
            if localContentIsUsable {
                hydrationState = .ready
                if !VocabMutationAuthorityRuntime.restorePersistedAuthorization(
                    container: modelContext.container,
                    context: modelContext
                ) {
                    hydrationMessage = "저장된 검증 정보가 없어 다음 유휴 시점에 무결성을 확인합니다."
                    await VocabSyncRuntimeStateStore.shared.requestFullAudit()
                }
            } else {
                await requestConnectionRefresh(reason: .initial)
            }
            scheduleMasteryCleanupIfEligible()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                maintenanceAuditTask?.cancel()
                maintenanceAuditTask = nil
                maintenanceAuditSlot.cancel()
                VocabMutationAuthorityRuntime.noteForegroundReentry()
            case .inactive, .background:
                scheduleMaintenanceAuditIfEligible()
            @unknown default:
                break
            }
        }
        .task(id: ObjectIdentifier(modelContext.container)) {
            // Iterated on the main actor; see VocabStoreChangeMonitor.
            for await event in VocabStoreChangeMonitor.events(for: modelContext.container) {
                handle(event)
            }
        }
    }

    @MainActor
    private func handle(_ event: VocabStoreChangeEvent) {
        switch event {
        case .localSave, .remoteChange:
            storeRevision &+= 1
            Task { await VocabSyncWorkBarrier.shared.notePotentialStoreChange() }
        case .successfulImport:
            Task {
                await VocabSyncWorkBarrier.shared.notePotentialStoreChange()
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                await requestConnectionRefresh(reason: .successfulImport)
            }
        case .masteryCleanupRequested:
            scheduleMasteryCleanupIfEligible()
        }
    }

    @MainActor
    private func scheduleMasteryCleanupIfEligible() {
        masteryCleanupPending = true
        guard connectionError == nil,
              localContentIsUsable,
              masteryCleanupTask == nil else { return }
        if masteryCleanupRetryCount > 3 { masteryCleanupRetryCount = 0 }
        masteryCleanupRetryTask?.cancel()
        masteryCleanupRetryTask = nil
        let container = modelContext.container
        masteryCleanupTask = Task { @MainActor in
            let indicator = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                showBackgroundActivity("암기완료 정리 중", isRunning: true)
            }
            var shouldRunAgain = false
            var retryDelay: Duration?
            var waitsForIntegrity = false
            repeat {
                masteryCleanupPending = false
                do {
                    let worker = await VocabMasteryCleanupWorkerFactory.make(modelContainer: container)
                    let result = try await worker.run(syncMode: .cloudKitPrivate)
                    masteryCleanupRetryCount = 0
                    if result.retiredCount > 0 {
                        showBackgroundActivity(
                            "암기완료 \(result.retiredCount)개 정리 완료 · iCloud 반영 중",
                            isRunning: false
                        )
                        scheduleBackgroundActivityClear()
                    } else if result.normalizedLegacyCount > 0 {
                        showBackgroundActivity("기존 분류를 장기정착으로 전환함", isRunning: false)
                        scheduleBackgroundActivityClear()
                    } else if !masteryCleanupPending {
                        clearBackgroundActivity()
                    }
                } catch LearningError.mutationsBlockedForIntegrity {
                    showBackgroundActivity("동기화 검증이 끝나면 암기완료 정리를 이어갑니다", isRunning: false)
                    masteryCleanupPending = true
                    waitsForIntegrity = true
                    break
                } catch {
                    showBackgroundActivity("암기완료 정리를 다음 기회에 다시 시도합니다", isRunning: false)
                    masteryCleanupPending = true
                    masteryCleanupRetryCount += 1
                    if masteryCleanupRetryCount <= 3 {
                        retryDelay = .seconds(5 * (1 << (masteryCleanupRetryCount - 1)))
                    }
                    break
                }
            } while masteryCleanupPending
            indicator.cancel()
            masteryCleanupTask = nil
            shouldRunAgain = masteryCleanupPending
                && retryDelay == nil
                && masteryCleanupRetryCount == 0
                && !waitsForIntegrity
            if let retryDelay {
                scheduleBackgroundActivityClear()
                scheduleMasteryCleanupRetry(after: retryDelay)
            } else if shouldRunAgain {
                scheduleMasteryCleanupIfEligible()
            }
        }
    }

    @MainActor
    private func scheduleMasteryCleanupRetry(after delay: Duration) {
        guard masteryCleanupRetryTask == nil else { return }
        masteryCleanupRetryTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            masteryCleanupRetryTask = nil
            scheduleMasteryCleanupIfEligible()
        }
    }

    @MainActor
    private func showBackgroundActivity(_ message: String, isRunning: Bool) {
        activityClearTask?.cancel()
        activityClearTask = nil
        backgroundActivityMessage = message
        backgroundActivityIsRunning = isRunning
    }

    @MainActor
    private func clearBackgroundActivity() {
        activityClearTask?.cancel()
        activityClearTask = nil
        backgroundActivityMessage = nil
        backgroundActivityIsRunning = false
    }

    @MainActor
    private func scheduleBackgroundActivityClear() {
        activityClearTask?.cancel()
        activityClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            clearBackgroundActivity()
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
            case .test:
                VocabIOSTestSetupView()
            case .study:
                VocabIOSStudyDayListView()
            case .review:
                VocabIOSReviewListView()
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
                let result = try await worker.reconcileImportedChanges(
                    syncMode: .cloudKitPrivate,
                    source: .persistentHistory,
                    allowsFullAudit: !localContentIsUsable
                )
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
                let currentEpochRequiresAudit = (reason == .initial || reason == .manual)
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
                cloudKitState = VocabCloudKitStatusService.resolve(
                    accountState: await account,
                    claimStatus: fetchedClaim
                )
            }
            if hydrationState == .ready {
                localContentIsUsable = true
            }
            if let authority = VocabMutationAuthorityPolicy.authority(for: hydrationState) {
                VocabMutationAuthorityRuntime.set(authority)
            }
            await VocabSyncRuntimeStateStore.shared.markDiagnosticCompleted(state: hydrationState)
            if hydrationState == .ready {
                scheduleMasteryCleanupIfEligible()
            }
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

    @MainActor
    private func scheduleMaintenanceAuditIfEligible() {
        guard localContentIsUsable,
              maintenanceAuditTask == nil,
              let generation = maintenanceAuditSlot.begin() else { return }
        let container = modelContext.container
        maintenanceAuditTask = Task { @MainActor in
            defer {
                if maintenanceAuditSlot.complete(generation: generation) {
                    maintenanceAuditTask = nil
                }
            }
            guard await VocabSyncRuntimeStateStore.shared.shouldRunFullAudit(),
                  !Task.isCancelled else { return }
            do {
                let worker = await VocabCloudReconciliationWorkerFactory.make(modelContainer: container)
                let result = try await worker.auditAll(syncMode: .cloudKitPrivate)
                guard !Task.isCancelled else { return }
                hydrationState = result.state
                hydrationMessage = result.message
                await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted()
                if result.state == .ready, masteryCleanupPending {
                    scheduleMasteryCleanupIfEligible()
                }
            } catch is CancellationError {
                return
            } catch {
                hydrationMessage = "유휴 상태 무결성 점검을 다음 기회에 다시 시도합니다."
            }
        }
    }

    private var hydrationDescription: String {
        let base = "현재 상태: \(hydrationState.connectionTitle). iPhone은 Mac의 기존 데이터를 다시 업로드하지 않습니다."
        guard let hydrationMessage, !hydrationMessage.isEmpty else { return base }
        return base + "\n\n" + hydrationMessage
    }
}

private extension VocabHydrationState {
    var connectionTitle: String {
        switch self {
        case .localOnly: "이 기기에 저장됨"
        case .awaitingBootstrapMetadata: "최초 동기화 정보 대기 중"
        case .hydrating: "iCloud 데이터 받는 중"
        case .reconciling: "데이터 검증 중"
        case .ready: "사용 가능"
        case .failed: "확인 필요"
        }
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
                LabeledContent("저장 방식", value: "iCloud 자동 동기화")
                LabeledContent("계정 상태", value: cloudKitState.message)
                LabeledContent("Mac 최초 동기화", value: claimDescription)
                LabeledContent("데이터 준비", value: hydrationState.connectionTitle)
                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if let hydrationMessage, hydrationState == .failed {
                    Label(hydrationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if hydrationState == .ready {
                    Label("iCloud 단어장에 연결되었습니다. iPhone의 이전 로컬 사본은 자동으로 업로드하지 않습니다.", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                } else {
                    Label("필요한 단어장 데이터를 기다리고 있습니다. 준비가 끝날 때까지 변경 작업을 하지 않습니다.", systemImage: "icloud.and.arrow.down")
                        .foregroundStyle(.secondary)
                }
                Text("iCloud 다운로드는 시스템이 네트워크와 전원 상태를 고려해 수행합니다. 이 버튼은 전송을 강제하지 않고, 도착한 데이터와 현재 연결 상태를 다시 확인합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(isChecking ? "확인 중" : "동기화 상태 다시 확인") {
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

private struct VocabIOSActivityBanner: View {
    let message: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct VocabIOSStudyDayListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.vocabStoreRevision) private var storeRevision
    @State private var snapshot: StudyCardsSnapshot?
    @State private var loadError: String?

    var body: some View {
        let groups = snapshot?.groups ?? []
        List {
            Section {
                ForEach(groups) { group in
                    NavigationLink {
                        VocabIOSStudyDayDetailView(group: group)
                    } label: {
                        HStack {
                            Text(group.day)
                                .font(.headline.monospacedDigit())
                            Spacer()
                            Text("\(group.words.count)개")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                if let loadError {
                    Text(loadError)
                } else if let snapshot, !groups.isEmpty {
                    Text("최초 등록일별로 묶인 카드입니다. 등록일 \(groups.count)개 · 전체 \(snapshot.wordCount)단어")
                }
            }
        }
        .overlay {
            if snapshot == nil {
                PageLoadingView()
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "학습할 단어가 없습니다",
                    systemImage: "rectangle.stack",
                    description: Text("Mac 단어장이 iCloud로 동기화되면 여기서 볼 수 있습니다.")
                )
            }
        }
        // Grouping depends only on membership and the immutable creation date, so
        // it is rebuilt per store change, off the main actor, never per render.
        .task(id: storeRevision) {
            guard await PageReloadPolicy.shouldLoad(hasSnapshot: snapshot != nil) else { return }
            do {
                let loaded = try await VocabLibraryReadModel.studyCards(in: context.container)
                guard !Task.isCancelled else { return }
                snapshot = loaded
                loadError = nil
            } catch {
                guard !Task.isCancelled else { return }
                snapshot = snapshot ?? StudyCardsSnapshot(groups: [], wordCount: 0)
                loadError = error.localizedDescription
            }
        }
    }
}

private struct VocabIOSStudyDayDetailView: View {
    let group: RegistrationDayGroup
    @State private var faceStates: [UUID: Bool] = [:]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: VocabMetrics.cardGridColumns, spacing: VocabMetrics.cardGridSpacing) {
                ForEach(group.words) { word in
                    WordFlipCard(
                        word: word,
                        showsMeaning: Binding(
                            get: { faceStates[word.id] ?? false },
                            set: { faceStates[word.id] = $0 }
                        ),
                        height: 132
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle(group.day)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct VocabIOSReviewListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.vocabStoreRevision) private var storeRevision
    @State private var loadedCandidates: [WordSummary]?
    @State private var loadError: String?

    var body: some View {
        // Same candidates and order as the Mac review page, rebuilt per store
        // change off the main actor.
        let candidates = loadedCandidates ?? []
        ScrollView {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            LazyVGrid(columns: VocabMetrics.cardGridColumns, spacing: VocabMetrics.cardGridSpacing) {
                ForEach(candidates) { word in
                    ReviewWordCard(word: word)
                }
            }
            .padding(16)
        }
        .overlay {
            if loadedCandidates == nil {
                PageLoadingView()
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    "우선 복습할 단어가 없습니다",
                    systemImage: "checkmark.circle",
                    description: Text("테스트에서 틀리거나 모름으로 답한 단어가 여기에 모입니다.")
                )
            }
        }
        .task(id: storeRevision) {
            guard await PageReloadPolicy.shouldLoad(hasSnapshot: loadedCandidates != nil) else { return }
            do {
                let loaded = try await VocabLibraryReadModel.reviewCandidates(in: context.container)
                guard !Task.isCancelled else { return }
                loadedCandidates = loaded
                loadError = nil
            } catch {
                guard !Task.isCancelled else { return }
                loadedCandidates = loadedCandidates ?? []
                loadError = error.localizedDescription
            }
        }
    }
}

private struct VocabIOSTestSetupView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var mode: SessionMode = .mixed
    @State private var direction: PracticeDirection = .enToKo
    @State private var format: QuestionFormat = .typed
    @State private var activeRun: VocabIOSTestRun?
    @State private var error: String?
    @State private var isStarting = false

    var body: some View {
        List {
            Section {
                Picker("모드", selection: $mode) {
                    ForEach(SessionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("모드")
            } footer: {
                Text(mode.setupDescription)
            }

            Section {
                Picker("방향", selection: $direction) {
                    ForEach(PracticeDirection.allCases) { direction in
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
            } header: {
                Text("방향 · 시험 방식")
            } footer: {
                Text("\(format.setupDescription) 한 회차는 최대 20개의 고유 단어로 구성됩니다.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                // Prominent buttons stay text-only on both platforms: inside a List
                // row the symbol takes the accent tint and disappears into the fill.
                Button {
                    start()
                } label: {
                    Text(format.startButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isStarting || activeRun != nil)
                if isStarting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("테스트 문항을 준비하는 중")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .sheet(item: $activeRun) { run in
            NavigationStack {
                VocabIOSTestRunnerView(run: run)
            }
        }
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
                let result = try LearningCoordinator(
                    context: modelContext,
                    syncMode: .cloudKitPrivate
                ).generateSession(
                    mode: mode,
                    direction: direction,
                    format: format
                )
                activeRun = VocabIOSTestRun(session: result.0, questions: result.1)
            } catch {
                activeRun = nil
                self.error = error.localizedDescription
            }
            isStarting = false
        }
    }

}

private struct VocabIOSTestRun: Identifiable {
    let session: TestSessionRecord
    let questions: [SessionQuestion]
    var id: UUID { session.id }
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
    @State private var notice: String?
    @State private var tally = TestSessionTally()
    @State private var isCompleted = false
    @FocusState private var answerFocused: Bool

    private var question: SessionQuestion? {
        run.questions.indices.contains(index) ? run.questions[index] : nil
    }

    var body: some View {
        if isCompleted {
            TestCompletionView(modeTitle: run.session.modeRaw, tally: tally) { dismiss() }
                .navigationTitle("테스트")
                .navigationBarTitleDisplayMode(.inline)
        } else if let question {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TestProgressHeader(
                        modeTitle: run.session.modeRaw,
                        index: index,
                        total: run.questions.count,
                        reducedQuestionCount: run.session.wasReduced ? run.questions.count : nil
                    )
                    TestPromptCard(question: question)

                    if question.format == .multipleChoice {
                        multipleChoiceOptions(question)
                    } else {
                        TextField("답안을 입력하세요", text: $answer)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($answerFocused)
                            .submitLabel(.done)
                            .onSubmit(submitForJudgement)
                            .disabled(judgeResult != nil)
                    }

                    if let judgeResult {
                        resultPanel(judgeResult, question: question)
                    } else {
                        HStack(spacing: 12) {
                            if question.format == .typed {
                                Button(action: submitForJudgement) {
                                    Text("제출").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Button(action: markUnknown) {
                                Text("모름").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    }

                    if let notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("테스트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear { answerFocused = question.format == .typed }
        } else {
            ContentUnavailableView(
                "출제 문항이 없습니다",
                systemImage: "exclamationmark.triangle",
                description: Text("테스트할 단어가 동기화된 뒤 다시 시도하세요.")
            )
        }
    }

    @ViewBuilder
    private func multipleChoiceOptions(_ question: SessionQuestion) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(question.choices.enumerated()), id: \.element.id) { offset, option in
                ChoiceOptionButton(
                    number: offset + 1,
                    label: option.label,
                    appearance: .resolve(option: option, selectedAnswer: answer, isJudged: judgeResult != nil)
                ) {
                    selectChoice(option)
                }
                .disabled(judgeResult != nil)
            }
        }
    }

    @ViewBuilder
    private func resultPanel(_ result: JudgeResult, question: SessionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            JudgementBanner(result: result)

            if result.automaticResult != .unknown {
                AnswerComparisonView(question: question, submittedAnswer: displayedAnswer(for: question))
            }

            Divider()

            Picker("최종 판정", selection: Binding(get: { chosenResult ?? result.automaticResult }, set: { chosenResult = $0 })) {
                ForEach(FinalResult.judgementOrder, id: \.self) { judgement in
                    Text(judgement.title).tag(judgement)
                }
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
                Text("iPhone에서는 단어장 원본을 수정하지 않습니다. 이번 답안만 정답으로 기록합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button(action: commitAndAdvance) {
                Text(index + 1 == run.questions.count ? "완료" : "확정 후 다음")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VocabMetrics.panelCornerRadius, style: .continuous)
                .stroke((chosenResult ?? result.automaticResult).tint.opacity(0.35), lineWidth: 1)
        }
    }

    private func submitForJudgement() {
        guard let question, judgeResult == nil else { return }
        if question.format == .multipleChoice, answer.isEmpty {
            notice = "선택지를 먼저 고르세요."
            return
        }
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

    private func selectChoice(_ option: MultipleChoiceOption) {
        guard judgeResult == nil else { return }
        answer = option.id.uuidString
        notice = nil
        submitForJudgement()
    }

    private func displayedAnswer(for question: SessionQuestion) -> String {
        guard question.format == .multipleChoice else { return answer.isEmpty ? "(입력 없음)" : answer }
        return question.choices.first { $0.id.uuidString == answer }?.label ?? "(선택 없음)"
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
            let finalMeaningID = final == .correct && question.direction == .enToKo
                ? (judgeResult.matchedMeaningID ?? correctedMeaningID)
                : judgeResult.matchedMeaningID
            let coordinator = LearningCoordinator(context: modelContext, syncMode: .cloudKitPrivate)
            try coordinator.commit(
                answer: answer,
                result: final,
                automatic: judgeResult.automaticResult,
                matchedMeaningID: finalMeaningID,
                question: question,
                session: run.session,
                correction: final == judgeResult.automaticResult ? nil : "oneTimeCorrection"
            )
            tally.record(final, forQuestionAt: index)
            if index + 1 == run.questions.count {
                try coordinator.completeSession(run.session)
                answerFocused = false
                isCompleted = true
            } else {
                index += 1
                answer = ""
                self.judgeResult = nil
                chosenResult = nil
                correctedMeaningID = nil
                notice = nil
                let nextQuestion = run.questions.indices.contains(index) ? run.questions[index] : nil
                answerFocused = nextQuestion?.format == .typed
            }
        } catch {
            notice = error.localizedDescription
        }
    }
}
