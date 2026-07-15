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
            } else if hydrationState != .localOnly && hydrationState != .ready {
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
        .task { refreshHydration() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshHydration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
            refreshHydration()
        }
    }

    private func refreshHydration() {
        do {
            let status = try VocabCloudReconciler.hydrationStatus(context: modelContext, syncMode: syncMode)
            if status.state == .reconciling || status.state == .ready || status.state == .localOnly {
                let result = try VocabCloudReconciler.reconcile(context: modelContext, syncMode: syncMode)
                hydrationState = result.state
                hydrationMessage = result.message
            } else {
                hydrationState = status.state
                hydrationMessage = status.message
            }
        } catch {
            hydrationState = .failed
            hydrationMessage = error.localizedDescription
        }
    }

    private var hydrationDescription: String {
        let base = "현재 상태: \(hydrationState.rawValue). metadata와 예상 레코드가 모두 도착하기 전에는 학습 데이터를 변경하지 않습니다."
        guard let hydrationMessage, !hydrationMessage.isEmpty else { return base }
        return base + "\n\n" + hydrationMessage
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
    @State private var serverClaimStatus: VocabBootstrapServerClaimStatus = .unavailable("아직 확인하지 않았습니다.")

    var body: some View {
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
                claimStatusView
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
        .font(.body)
        .lineLimit(nil)
        .textSelection(.enabled)
        .controlSize(.large)
        .padding(24)
        .frame(minWidth: 520, idealWidth: 680, minHeight: 520, idealHeight: 760)
        .task {
            await loadAPIKey()
            refreshHydrationStatus()
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
        refreshHydrationStatus()
    }

    private func refreshHydrationStatus() {
        let mode = VocabSyncMode.current(allowsCloudKit: true)
        do {
            let status = try VocabCloudReconciler.hydrationStatus(context: modelContext, syncMode: mode)
            hydrationState = status.state
            hydrationMessage = status.message
        } catch {
            hydrationState = .failed
            hydrationMessage = error.localizedDescription
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
            let result = try await VocabCloudSnapshotSyncService().uploadLocalSnapshot(context: modelContext)
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
            let claimService = VocabCloudKitBootstrapClaimService()
            let status = await claimService.fixedClaimStatus()
            serverClaimStatus = status
            let credential = try VocabBootstrapTokenStore.load()
            let localSnapshot = try VocabSyncSnapshotService.exportSnapshot(context: modelContext)
            let fingerprint = try localSnapshot.contentFingerprint()
            let manifest = try VocabBootstrapRecoveryManifestStore.load()
            let receiptIsValid: Bool
            if case .available(let claim) = status, credential?.request == nil {
                let mirrored = try VocabModelContainerFactory.makeContainer(syncMode: .cloudKitPrivate)
                let receipts = try ModelContext(mirrored).fetch(FetchDescriptor<BootstrapExportReceipt>())
                receiptIsValid = receipts.contains {
                    $0.requestID == claim.request.requestID
                        && $0.fingerprint == claim.request.sourceFingerprint
                        && !$0.storeUUID.isEmpty
                        && $0.transactionCommittedAt > .distantPast
                        && ($0.state == "awaitingExport" || $0.state == "exported")
                }
                withExtendedLifetime(mirrored) {}
            } else {
                receiptIsValid = credential?.request != nil
            }
            let decision = VocabBootstrapResumePolicy.decide(
                serverStatus: status,
                storedRequest: credential?.request,
                currentCanonicalFingerprint: fingerprint,
                checkpointManifest: manifest,
                expectedSchemaVersion: VocabCloudReconciler.metadataSchemaVersion,
                receiptIsValid: receiptIsValid
            )
            let token: VocabBootstrapToken
            let existingClaimRequest: VocabBootstrapClaimRequest?
            switch decision {
            case .hydrateCompleted(let claim):
                UserDefaults.standard.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)
                syncMessage = "서버 bootstrap은 완료 상태입니다. 로컬 데이터를 다시 seed하지 않고 다음 실행부터 iCloud 레코드를 hydration합니다. claim \(claim.request.requestID.uuidString)"
                return
            case .createNew:
                token = try VocabBootstrapTokenStore.createAndPersist().token
                existingClaimRequest = nil
            case .resume(let request), .recoverExisting(let request):
                try VocabBootstrapTokenStore.persist(request)
                token = VocabBootstrapToken(claimID: request.claimID, requestID: request.requestID)
                existingClaimRequest = request
            case .blocked(let message):
                throw VocabBootstrapPreparationError.blocked(message)
            }
            let mirroredContainer = try VocabModelContainerFactory.makeContainer(syncMode: .cloudKitPrivate)
            defer { withExtendedLifetime(mirroredContainer) {} }
            let mirroredStoreURL = try VocabModelContainerFactory.mirroredStoreURL()
            let report = try await VocabStoreMigrationService.claimAndMigrateLocalSnapshotToMirroredStore(
                localContext: modelContext,
                mirroredContext: ModelContext(mirroredContainer),
                bootstrapToken: token,
                existingClaimRequest: existingClaimRequest,
                claimService: claimService,
                mirroredStoreURL: mirroredStoreURL,
                exportObserver: VocabPersistentCloudKitExportObserver(),
                createCheckpoint: {
                    let checkpoint = try VocabLocalStoreCheckpointStore.createDefaultStoreCheckpoint()
                    _ = try VocabLocalStoreCheckpointStore.rehearseCheckpoint(checkpoint)
                    return checkpoint
                },
                persistClaimRequest: { request in
                    try VocabBootstrapTokenStore.persist(request)
                },
                persistRecoveryManifest: { checkpoint, fingerprint, request in
                    try VocabBootstrapRecoveryManifestStore.save(
                        checkpoint: checkpoint,
                        fingerprint: fingerprint,
                        request: request
                    )
                }
            )
            UserDefaults.standard.set(VocabSyncMode.cloudKitPrivate.rawValue, forKey: VocabSyncMode.userDefaultsKey)
            syncMessage = "\(report.wordCount)개 단어, \(report.dailySetCount)개 세트, \(report.attemptCount)개 시도 기록의 CloudKit export 성공을 확인했습니다. 다음 앱 실행부터 per-record iCloud 저장소를 사용합니다. 체크포인트: \(report.checkpointDirectoryName)"
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

private enum VocabBootstrapPreparationError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let message): message
        }
    }
}
