import CloudKit
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
    @State private var selection: NavigationItem? = .intake
    @State private var studyCardFaceStates: [UUID: Bool] = [:]

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
            Group {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
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
    @State private var showUploadConfirmation = false
    @State private var syncMessage: String?
    @State private var syncMessageIsError = false

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
                LabeledContent("현재 저장 방식", value: VocabSyncMode.current().displayName)
                LabeledContent("CloudKit 컨테이너", value: VocabSyncMode.cloudKitContainerIdentifier)
                FeedbackPanel(items: cloudKitFeedbackItems)
                DisclosureGroup("자동 iCloud 저장소 전환 조건") {
                    VStack(alignment: .leading, spacing: 10) {
                        if cloudSyncReadiness.isReadyToEnable {
                            Label("모든 안전 조건을 통과했습니다.", systemImage: "checkmark.shield")
                                .foregroundStyle(.green)
                        } else {
                            ForEach(cloudSyncReadiness.blockers) { blocker in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(blocker.title, systemImage: "lock.shield")
                                        .font(.body.weight(.semibold))
                                    Text(blocker.message)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                HStack {
                    Button {
                        Task { await checkCloudKitStatus() }
                    } label: {
                        if isCheckingCloudKit {
                            Label("확인 중", systemImage: "icloud")
                        } else {
                            Label("iCloud 상태 확인", systemImage: "icloud")
                        }
                    }
                    .disabled(isCheckingCloudKit)

                    if isCheckingCloudKit {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Button {
                    showUploadConfirmation = true
                } label: {
                    if isUploadingSnapshot {
                        Label("업로드 중", systemImage: "icloud.and.arrow.up")
                    } else {
                        Label("현재 Mac 단어장을 iCloud에 업로드", systemImage: "icloud.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUploadSnapshot)

                if isUploadingSnapshot {
                    ProgressView("단어장 스냅샷을 iCloud에 업로드하는 중입니다.")
                }

                if let syncMessage {
                    Label(syncMessage, systemImage: syncMessageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(syncMessageIsError ? .red : .green)
                        .font(.callout)
                }

                Text("현재 빌드는 기존 macOS 단어장을 보호하기 위해 로컬 저장을 기본값으로 유지합니다. 아래 업로드 버튼은 자동 저장소 전환이 아니라, iPhone에서 가져올 수 있는 수동 스냅샷을 iCloud에 올리는 기능입니다.")
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
        .controlSize(.large)
        .padding(24)
        .frame(width: 480)
        .task {
            await loadAPIKey()
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
            Text("업로드 전에 현재 로컬 저장소 체크포인트를 생성합니다. iPhone에서는 이 스냅샷을 가져와 phone-local Vocab 데이터를 교체하게 됩니다.")
        }
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
        cloudKitState.isReadyForSync
            && VocabCloudEntitlementStatus.hasRequiredCloudKitContainer()
            && !isUploadingSnapshot
    }

    private func checkCloudKitStatus() async {
        guard !isCheckingCloudKit else { return }
        isCheckingCloudKit = true
        defer { isCheckingCloudKit = false }
        cloudKitState = await VocabCloudKitStatusService().accountStatus()
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
            syncMessage = "\(result.wordCount)개 단어와 \(result.dailySetCount)개 학습세트를 iCloud에 업로드했습니다. 체크포인트: \(checkpoint.directory.lastPathComponent)"
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
