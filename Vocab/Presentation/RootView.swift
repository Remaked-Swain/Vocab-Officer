import AppKit
import CloudKit
import CoreData
import SwiftData
import SwiftUI

enum NavigationItem: String, CaseIterable, Identifiable {
    case intake = "오늘 입력"
    case test = "테스트"
    case study = "학습 카드"
    case review = "복습"
    case mastered = "Mastered"
    case library = "단어장"
    case history = "기록"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .intake: "square.and.pencil"
        case .test: "checkmark.rectangle"
        case .study: "rectangle.stack"
        case .review: "arrow.clockwise.circle"
        case .mastered: "graduationcap"
        case .library: "books.vertical"
        case .history: "chart.bar"
        }
    }
}

struct RootView: View {
    let connectionError: String?
    let syncMode: VocabSyncMode
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: NavigationItem? = .intake
    @State private var studyCardFaceStates: [UUID: Bool] = [:]
    @State private var hydrationState: VocabHydrationState = .localOnly
    @State private var hydrationMessage: String?
    @State private var isRecoveringBootstrap = false
    @State private var bootstrapRecoveryMessage = ""
    @State private var showBootstrapRestart = false
    @State private var hydrationRefreshTask: Task<Void, Never>?
    @State private var hasPendingHydrationRefresh = false
    @State private var pendingRefreshReason: VocabHydrationRefreshReason = .initial
    @State private var reconciliationWorker: VocabCloudReconciliationWorker?
    @State private var localContentIsUsable = false
    @State private var recoveryReplicaTask: Task<Void, Never>?
    @State private var maintenanceAuditTask: Task<Void, Never>?
    @State private var maintenanceAuditSlot = VocabMaintenanceTaskSlot()

    var body: some View {
        NavigationSplitView {
            List(NavigationItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .font(.body)
                    .padding(.vertical, 5)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationTitle("Vocab")
        } detail: {
            if let connectionError {
                ContentUnavailableView(
                    "저장소 연결 오류",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(connectionError + " 설정에서 저장 모드와 복구 정보를 확인하세요.")
                )
            } else if isRecoveringBootstrap {
                ContentUnavailableView(
                    "iCloud 전환 복구 중",
                    systemImage: "icloud.and.arrow.up",
                    description: Text("검증된 기존 bootstrap 작업을 중단 지점부터 재개하고 있습니다. 단어장을 안전하게 유지하기 위해 완료 전에는 편집할 수 없습니다.")
                )
            } else if !localContentIsUsable && hydrationState != .localOnly && hydrationState != .ready {
                ContentUnavailableView(
                    "iCloud 연결 준비 중",
                    systemImage: "icloud",
                    description: Text(hydrationDescription)
                )
            } else {
                switch selection ?? .intake {
                case .intake: TodayIntakeView()
                case .test: TestSetupView()
                case .study: StudyCardsView(faceStates: $studyCardFaceStates)
                case .review: ReviewView()
                case .mastered: MasteredView()
                case .library: LibraryView()
                case .history: HistoryView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            localContentIsUsable = syncMode == .localOnly
                || VocabSyncRuntimeStateStore.persistedLocalContentIsUsable()
            if localContentIsUsable {
                hydrationState = syncMode == .localOnly ? .localOnly : .ready
                if syncMode == .cloudKitPrivate,
                   !VocabMutationAuthorityRuntime.restorePersistedAuthorization(
                    container: modelContext.container,
                    context: modelContext
                   ) {
                    hydrationMessage = "저장된 검증 정보가 없어 다음 유휴 시점에 무결성을 확인합니다."
                    await VocabSyncRuntimeStateStore.shared.requestFullAudit()
                }
            } else {
                scheduleHydrationRefresh(reason: .initial)
            }
            await resumeBootstrapIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                maintenanceAuditTask?.cancel()
                maintenanceAuditTask = nil
                maintenanceAuditSlot.cancel()
                if syncMode == .cloudKitPrivate {
                    VocabMutationAuthorityRuntime.noteForegroundReentry()
                }
            case .inactive:
                scheduleMaintenanceAuditIfEligible()
                scheduleRecoveryReplicaIfEligible(trigger: .inactive)
            case .background:
                scheduleMaintenanceAuditIfEligible()
                scheduleRecoveryReplicaIfEligible(trigger: .background)
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            Task { await VocabSyncWorkBarrier.shared.notePotentialStoreChange() }
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
            Task { await VocabSyncWorkBarrier.shared.notePotentialStoreChange() }
            scheduleHydrationRefresh(reason: .successfulImport)
        }
        .alert("iCloud 전환 완료", isPresented: $showBootstrapRestart) {
            Button("지금 다시 시작") { relaunchApplication() }
            Button("나중에", role: .cancel) {}
        } message: {
            Text(bootstrapRecoveryMessage)
        }
    }

    @MainActor
    private func scheduleHydrationRefresh(reason: VocabHydrationRefreshReason) {
        hasPendingHydrationRefresh = true
        pendingRefreshReason = mergedRefreshReason(pendingRefreshReason, reason)
        guard hydrationRefreshTask == nil else { return }
        hydrationRefreshTask = Task { @MainActor in
            // SwiftData can coalesce several remote notifications for one CloudKit transaction.
            let delay: Duration = reason == .successfulImport ? .milliseconds(750) : .milliseconds(300)
            try? await Task.sleep(for: delay)
            while hasPendingHydrationRefresh, !Task.isCancelled {
                hasPendingHydrationRefresh = false
                let reason = pendingRefreshReason
                pendingRefreshReason = .remoteStoreChange
                await refreshHydration(reason: reason)
            }
            hydrationRefreshTask = nil
        }
    }

    @MainActor
    private func scheduleRecoveryReplicaIfEligible(trigger: VocabRecoveryReplicaRefreshTrigger) {
        guard VocabRecoveryReplicaScheduler.automaticRefreshIsEligible(
            trigger: trigger,
            syncMode: syncMode,
            hydrationState: hydrationState,
            localContentIsUsable: localContentIsUsable,
            hasRunningTask: recoveryReplicaTask != nil
        ) else { return }
        let container = modelContext.container
        recoveryReplicaTask = Task {
            defer { recoveryReplicaTask = nil }
            _ = try? await VocabRecoveryReplicaScheduler.refresh(
                modelContainer: container,
                syncMode: syncMode
            )
        }
    }

    @MainActor
    private func scheduleMaintenanceAuditIfEligible() {
        guard syncMode == .cloudKitPrivate,
              localContentIsUsable,
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
                let result = try await worker.auditAll(syncMode: syncMode)
                guard !Task.isCancelled else { return }
                hydrationState = result.state
                hydrationMessage = result.message
                await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted()
            } catch is CancellationError {
                return
            } catch {
                hydrationMessage = "유휴 상태 무결성 점검을 다음 기회에 다시 시도합니다."
            }
        }
    }

    @MainActor
    private func refreshHydration(reason: VocabHydrationRefreshReason) async {
        guard await VocabSyncRuntimeStateStore.shared.shouldRunDiagnostic(reason: reason) else { return }
        do {
            let worker = await ensureReconciliationWorker()
            if reason == .successfulImport {
                let result = try await worker.reconcileImportedChanges(
                    syncMode: syncMode,
                    source: .trustedLocalIdentifiers,
                    allowsFullAudit: !localContentIsUsable
                )
                hydrationState = result.state
                hydrationMessage = result.message
            } else {
                let status = try await worker.hydrationStatus(syncMode: syncMode)
                let needsReconciliation = VocabHydrationDiagnosticPolicy.shouldReconcile(
                    reason: reason,
                    state: status.state
                )
                let fullAuditIsDue = await VocabSyncRuntimeStateStore.shared.shouldRunFullAudit()
                let currentEpochRequiresAudit = syncMode == .cloudKitPrivate
                    && (reason == .initial || reason == .manual)
                    && VocabMutationAuthorityRuntime.current == .integrityBlocked
                let scheduledAuditIsDue = status.state == .ready
                    && (fullAuditIsDue || currentEpochRequiresAudit)
                if needsReconciliation || scheduledAuditIsDue {
                    let result = try await worker.auditAll(syncMode: syncMode)
                    hydrationState = result.state
                    hydrationMessage = result.message
                    await VocabSyncRuntimeStateStore.shared.markFullAuditCompleted()
                } else {
                    hydrationState = status.state
                    hydrationMessage = status.message
                }
            }
            if hydrationState == .ready || hydrationState == .localOnly {
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

    private func mergedRefreshReason(
        _ existing: VocabHydrationRefreshReason,
        _ incoming: VocabHydrationRefreshReason
    ) -> VocabHydrationRefreshReason {
        if existing == .successfulImport || incoming == .successfulImport { return .successfulImport }
        if existing == .manual || incoming == .manual { return .manual }
        if existing == .initial || incoming == .initial { return .initial }
        if existing == .foreground || incoming == .foreground { return .foreground }
        return incoming
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
        let base = "현재 상태: \(hydrationState.rawValue). metadata와 예상 레코드가 모두 도착하기 전에는 학습 데이터를 변경하지 않습니다."
        guard let hydrationMessage, !hydrationMessage.isEmpty else { return base }
        return base + "\n\n" + hydrationMessage
    }

    @MainActor
    private func resumeBootstrapIfNeeded() async {
        guard syncMode == .localOnly,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        isRecoveringBootstrap = true
        defer { isRecoveringBootstrap = false }
        do {
            let outcome = try await VocabBootstrapActivationService.activate(
                localContext: modelContext,
                allowsNewClaim: false
            )
            guard outcome.disposition == .restartRequired else { return }
            UserDefaults.standard.removeObject(forKey: "vocabBootstrapAutoRecoveryLastError")
            bootstrapRecoveryMessage = outcome.message
            showBootstrapRestart = true
        } catch {
            UserDefaults.standard.set(
                userFacingBootstrapRecoveryError(error),
                forKey: "vocabBootstrapAutoRecoveryLastError"
            )
        }
    }

    private func userFacingBootstrapRecoveryError(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "자동 복구를 완료하지 못했습니다. 설정에서 iCloud 상태를 다시 확인하세요."
    }

    private func relaunchApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("reviewDefaultMode") private var reviewDefaultMode = "mixed"
    @AppStorage("showTypoSuggestions") private var showTypoSuggestions = true
    @AppStorage("memoryAidModel") private var memoryAidModel = MemoryAidModel.defaultModel.rawValue
    @State private var apiKey = ""
    @State private var apiKeyLoaded = false
    @State private var apiKeyMessage: String?
    @State private var apiKeyError = false
    @State private var cloudKitState: VocabCloudKitAccountState = .unknown
    @State private var isCheckingCloudKit = false
    @State private var isUploadingSnapshot = false
    @State private var isMigratingToMirroredStore = false
    @State private var showUploadConfirmation = false
    @State private var showMirroringConfirmation = false
    @State private var syncMessage: String?
    @State private var syncMessageIsError = false
    @State private var hydrationState: VocabHydrationState = .localOnly
    @State private var hydrationMessage: String?
    @State private var recoveryReplicaDescription = "검증된 복구 replica가 아직 없습니다."
    @State private var serverClaimStatus: VocabBootstrapServerClaimStatus = .unavailable("아직 확인하지 않았습니다.")
    @AppStorage("vocabBootstrapAutoRecoveryLastError") private var bootstrapAutoRecoveryLastError = ""

    var body: some View {
        ScrollView {
            Form {
            Picker("기본 테스트 모드", selection: $reviewDefaultMode) {
                Text("오늘 신규").tag("today")
                Text("복습").tag("review")
                Text("혼합").tag("mixed")
            }
            Toggle("근접 오타 후보 제시", isOn: $showTypoSuggestions)
            LabeledContent("학습 날짜 기준", value: "Asia/Seoul")

            Section("iPhone / iCloud 동기화") {
                LabeledContent("현재 저장 방식", value: VocabSyncMode.current(allowsCloudKit: true).displayName)
                LabeledContent("CloudKit 컨테이너", value: VocabSyncMode.cloudKitContainerIdentifier)
                LabeledContent("Hydration", value: hydrationState.rawValue)
                LabeledContent("Mac 복구 replica", value: recoveryReplicaDescription)
                claimStatusView
                if !bootstrapAutoRecoveryLastError.isEmpty {
                    LabeledContent("마지막 자동 복구 진단") {
                        Text(bootstrapAutoRecoveryLastError)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let hydrationMessage {
                    Label(hydrationMessage, systemImage: hydrationState == .failed ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(hydrationState == .failed ? .red : .secondary)
                }
                FeedbackPanel(items: cloudKitFeedbackItems)
                Label("mirrored 모드에서는 snapshot batch 자동 동기화를 실행하지 않습니다.", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        cloudStatusButton
                        if isCheckingCloudKit { ProgressView().controlSize(.small) }
                    }
                    VStack(alignment: .leading) {
                        cloudStatusButton
                        if isCheckingCloudKit { ProgressView().controlSize(.small) }
                    }
                }

                Button {
                    showUploadConfirmation = true
                } label: {
                    if isUploadingSnapshot {
                        Label("업로드 중", systemImage: "icloud.and.arrow.up")
                    } else {
                        Label("수동 복구 snapshot 업로드", systemImage: "icloud.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUploadSnapshot)

                if isUploadingSnapshot {
                    ProgressView("단어장 스냅샷을 iCloud에 업로드하는 중입니다.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Per-record CloudKit mirroring")
                        .font(.headline)
                    Text("현재 로컬 단어장을 별도 mirrored store로 복사 검증한 뒤, 다음 실행부터 SwiftData CloudKit mirroring 저장소를 사용합니다. 기존 `Vocab.store`는 삭제하지 않으며, mirrored store에 기존 데이터가 있으면 삭제 전파를 막기 위해 전환을 중단합니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { mirroringButton; localModeButton }
                        VStack(alignment: .leading) { mirroringButton; localModeButton }
                    }
                    if isMigratingToMirroredStore {
                        ProgressView("mirrored store 이관 후 CloudKit export 성공을 확인하는 중입니다. 완료될 때까지 Mac 앱을 종료하지 마세요.")
                    }
                }

                if let syncMessage {
                    Label(syncMessage, systemImage: syncMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(syncMessageIsError ? .red : .green)
                        .font(.callout)
                }

                Text("snapshot은 자동 동기화에 사용하지 않으며, local 모드에서 운영자가 명시적으로 실행하는 복구 사본으로만 남겨 둡니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(localStoreDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("암기 도움 API") {
                Picker("기본 모델", selection: $memoryAidModel) {
                    ForEach(MemoryAidModel.allCases) { model in
                        Text("\(model.displayName) · \(model.summary)")
                            .tag(model.rawValue)
                    }
                }

                SecureField("Gemini API 키", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("API 키 저장") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("API 키 삭제", role: .destructive) {
                        deleteAPIKey()
                    }
                    .disabled(apiKey.isEmpty && apiKeyLoaded)
                }

                Text("Google AI Studio에서 발급한 Gemini API 키를 사용합니다. 무료 티어에서는 요청 내용이 제품 개선에 사용될 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("이 키는 macOS 키체인에 저장되며, 앱 재설치 후에도 사용자가 직접 삭제하기 전까지 유지될 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let apiKeyMessage {
                    Label(apiKeyMessage, systemImage: apiKeyError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(apiKeyError ? .red : .green)
                }
            }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .lineLimit(nil)
        .textSelection(.enabled)
        .controlSize(.large)
        .contentMargins(24, for: .scrollContent)
        .frame(minWidth: 600, idealWidth: 820, minHeight: 480, idealHeight: 760)
        .task {
            await loadAPIKey()
            await refreshHydrationStatus(runFullAudit: false)
            refreshRecoveryReplicaDescription()
        }
        .confirmationDialog(
            "현재 Mac 단어장을 iCloud에 업로드할까요?",
            isPresented: $showUploadConfirmation,
            titleVisibility: .visible
        ) {
            Button("체크포인트 생성 후 업로드") {
                Task { await uploadSnapshotToCloud() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("업로드 전에 현재 로컬 저장소 체크포인트를 생성합니다. 이 snapshot은 자동으로 적용되지 않는 수동 복구 사본입니다.")
        }
        .confirmationDialog(
            "per-record iCloud mirrored store로 전환할까요?",
            isPresented: $showMirroringConfirmation,
            titleVisibility: .visible
        ) {
            Button("체크포인트 생성 후 mirrored store 준비") {
                Task { await prepareAndMigrateToMirroredStore() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 로컬 Vocab.store는 삭제하지 않습니다. mirrored store가 비어 있고 이관 검증이 성공한 경우에만 다음 앱 실행부터 적용됩니다.")
        }
    }

    @ViewBuilder
    private var claimStatusView: some View {
        let presentation = VocabBootstrapClaimSettingsPresentation(status: serverClaimStatus)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("서버 bootstrap claim", value: presentation.summary)
            if let details = presentation.details {
                Text(details)
                    .font(.caption.monospaced())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private var cloudStatusButton: some View {
        Button { Task { await checkCloudKitStatus() } } label: {
            Label(isCheckingCloudKit ? "확인 중" : "iCloud 상태 확인", systemImage: "icloud")
        }
        .disabled(isCheckingCloudKit)
    }

    private var mirroringButton: some View {
        Button { showMirroringConfirmation = true } label: {
            Label(
                isMigratingToMirroredStore ? "전환 준비 중" : "per-record iCloud 저장소로 전환 준비",
                systemImage: isMigratingToMirroredStore ? "icloud.and.arrow.up" : "point.3.connected.trianglepath.dotted"
            )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canMigrateToMirroredStore)
    }

    private var localModeButton: some View {
        Button("로컬 저장 모드로 되돌리기") {
            UserDefaults.standard.set(VocabSyncMode.localOnly.rawValue, forKey: VocabSyncMode.userDefaultsKey)
            syncMessage = "다음 실행부터 기존 로컬 저장소를 사용합니다. mirrored store는 삭제하지 않았습니다."
            syncMessageIsError = false
        }
        .disabled(isMigratingToMirroredStore)
    }

    private var cloudKitFeedbackItems: [FeedbackItem] {
        let color: Color = cloudSyncReadiness.isReadyToEnable ? .green : .orange
        let symbol = cloudSyncReadiness.isReadyToEnable ? "checkmark.icloud" : "exclamationmark.icloud"
        return [
            FeedbackItem(
                text: "\(cloudKitState.title): \(cloudKitState.message)",
                systemImage: symbol,
                color: color
            ),
            FeedbackItem(
                text: cloudSyncReadiness.isReadyToEnable ? "iCloud 동기화를 켤 수 있습니다." : "현재는 안전 조건 미충족으로 iCloud 동기화를 켤 수 없습니다.",
                systemImage: cloudSyncReadiness.isReadyToEnable ? "checkmark.shield" : "lock.shield",
                color: cloudSyncReadiness.isReadyToEnable ? .green : .secondary
            )
        ]
    }

    private var cloudSyncReadiness: VocabCloudSyncReadiness {
        VocabCloudSyncReadinessPolicy.current(accountState: cloudKitState)
    }

    private var canUploadSnapshot: Bool {
        VocabSyncMode.current(allowsCloudKit: true) == .localOnly
            && cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.allowsCloudKitRequests()
            && !isUploadingSnapshot
    }

    private var canMigrateToMirroredStore: Bool {
        VocabSyncMode.current(allowsCloudKit: true) == .localOnly
            && cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.allowsCloudKitRequests()
            && !isMigratingToMirroredStore
    }

    private func checkCloudKitStatus() async {
        guard !isCheckingCloudKit else { return }
        isCheckingCloudKit = true
        defer { isCheckingCloudKit = false }
        cloudKitState = await VocabCloudKitStatusService().accountStatus()
        serverClaimStatus = await VocabCloudKitBootstrapClaimService().fixedClaimStatus()
        await refreshHydrationStatus(runFullAudit: true)
        refreshRecoveryReplicaDescription()
    }

    private func refreshHydrationStatus(runFullAudit: Bool) async {
        let mode = VocabSyncMode.current(allowsCloudKit: true)
        do {
            let worker = await VocabCloudReconciliationWorkerFactory.make(
                modelContainer: modelContext.container
            )
            let status = if runFullAudit && mode == .cloudKitPrivate {
                try await worker.auditAll(syncMode: mode)
            } else {
                try await worker.hydrationStatus(syncMode: mode)
            }
            hydrationState = status.state
            hydrationMessage = status.message
            if let authority = VocabMutationAuthorityPolicy.authority(for: status.state) {
                VocabMutationAuthorityRuntime.set(authority)
            }
        } catch {
            hydrationState = .failed
            hydrationMessage = error.localizedDescription
            if let authority = VocabMutationAuthorityPolicy.authority(for: error) {
                VocabMutationAuthorityRuntime.set(authority)
            }
        }
    }

    private func refreshRecoveryReplicaDescription() {
        do {
            let root = try VocabRecoveryReplicaManifestStore.rootURL()
            guard let manifest = try VocabRecoveryReplicaManifestStore.load(root: root),
                  let generation = manifest.generations.first(where: { $0.id == manifest.currentGenerationID }) else {
                recoveryReplicaDescription = "검증된 복구 replica가 아직 없습니다."
                return
            }
            recoveryReplicaDescription = "\(generation.seoulDay), \(generation.counts.words)단어, 최근 3세대 보존"
        } catch {
            recoveryReplicaDescription = "복구 replica 상태를 읽지 못했습니다."
        }
    }

    private func uploadSnapshotToCloud() async {
        guard !isUploadingSnapshot else { return }
        isUploadingSnapshot = true
        syncMessage = nil
        syncMessageIsError = false
        defer { isUploadingSnapshot = false }

        do {
            let checkpoint = try VocabLocalStoreCheckpointStore.createCheckpoint(
                storeURL: try VocabModelContainerFactory.storeURL(),
                destinationRoot: try localCheckpointRoot()
            )
            let result = try await VocabEmergencyRecoveryService()
                .uploadExplicitRecoverySnapshot(context: modelContext)
            syncMessage = result.disposition == .unchanged
                ? "서버 복구 snapshot과 canonical fingerprint가 같습니다. 변경 없음. asset 업로드를 건너뛰었습니다. 체크포인트: \(checkpoint.directory.lastPathComponent)"
                : "\(result.wordCount)개 단어와 \(result.dailySetCount)개 학습세트를 iCloud에 업로드했습니다. 체크포인트: \(checkpoint.directory.lastPathComponent)"
        } catch {
            syncMessage = userFacingSyncError(error)
            syncMessageIsError = true
        }
    }

    private func prepareAndMigrateToMirroredStore() async {
        guard !isMigratingToMirroredStore else { return }
        isMigratingToMirroredStore = true
        syncMessage = nil
        syncMessageIsError = false
        defer { isMigratingToMirroredStore = false }

        do {
            let outcome = try await VocabBootstrapActivationService.activate(
                localContext: modelContext,
                allowsNewClaim: true
            )
            syncMessage = outcome.message
            serverClaimStatus = await VocabCloudKitBootstrapClaimService().fixedClaimStatus()
        } catch {
            syncMessage = userFacingSyncError(error)
            syncMessageIsError = true
        }
    }

    private func localCheckpointRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Vocab", isDirectory: true)
        .appendingPathComponent("SyncCheckpoints", isDirectory: true)
    }

    private func userFacingSyncError(_ error: Error) -> String {
        if error is CKError {
            return "iCloud 요청을 완료하지 못했습니다. iCloud 로그인, 네트워크 상태, 앱의 iCloud 권한을 확인한 뒤 다시 시도하세요."
        }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "iCloud 동기화 중 문제가 발생했습니다. iCloud 로그인, 네트워크 상태, 앱 서명 권한을 확인한 뒤 다시 시도하세요."
    }

    private func loadAPIKey() async {
        do {
            apiKey = try GeminiAPIKeyStore.shared.load() ?? ""
            apiKeyLoaded = true
        } catch {
            apiKeyMessage = error.localizedDescription
            apiKeyError = true
        }
    }

    private func saveAPIKey() {
        do {
            try GeminiAPIKeyStore.shared.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            apiKeyMessage = "Gemini API 키를 저장했습니다."
            apiKeyError = false
            apiKeyLoaded = true
        } catch {
            apiKeyMessage = error.localizedDescription
            apiKeyError = true
        }
    }

    private func deleteAPIKey() {
        do {
            try GeminiAPIKeyStore.shared.delete()
            apiKey = ""
            apiKeyMessage = "Gemini API 키를 삭제했습니다."
            apiKeyError = false
        } catch {
            apiKeyMessage = error.localizedDescription
            apiKeyError = true
        }
    }

    private var localStoreDescription: String {
        do {
            return "로컬 저장소: \(try VocabModelContainerFactory.storeURL().path)"
        } catch {
            return "로컬 저장소 경로를 확인하지 못했습니다."
        }
    }
}

struct VocabBootstrapClaimSettingsPresentation: Equatable {
    let summary: String
    let details: String?

    init(status: VocabBootstrapServerClaimStatus) {
        switch status {
        case .missing:
            summary = "서버 claim 없음: Mac 최초 전환이 필요합니다."
            details = nil
        case .unavailable(let message):
            summary = "서버 claim 확인 실패"
            details = message
        case .available(let claim):
            switch claim.state {
            case .claimed: summary = "Mac이 최초 업로드를 준비하고 있습니다."
            case .seeding: summary = "Mac이 기존 단어장을 iCloud에 업로드하는 중입니다."
            case .completed: summary = "최초 업로드 완료: 재업로드 없이 hydration합니다."
            }
            details = "claimID: \(claim.request.claimID.uuidString)\nrequestID: \(claim.request.requestID.uuidString)\nowner: \(claim.request.ownerDeviceID)\nfingerprint: \(claim.request.sourceFingerprint)\nschema: \(claim.request.schemaVersion)\ncreated: \(claim.createdAt.formatted())\nupdated: \(claim.updatedAt.formatted())"
        }
    }
}
