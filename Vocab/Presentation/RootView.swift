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
    @AppStorage("reviewDefaultMode") private var reviewDefaultMode = "mixed"
    @AppStorage("showTypoSuggestions") private var showTypoSuggestions = true
    @AppStorage("memoryAidModel") private var memoryAidModel = MemoryAidModel.defaultModel.rawValue
    @State private var apiKey = ""
    @State private var apiKeyLoaded = false
    @State private var apiKeyMessage: String?
    @State private var apiKeyError = false
    @State private var cloudKitState: VocabCloudKitAccountState = .unknown
    @State private var isCheckingCloudKit = false

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
                Text("현재 빌드는 기존 macOS 단어장을 보호하기 위해 로컬 저장을 기본값으로 유지합니다. iCloud 동기화는 별도 브랜치에서 저장 모델 호환성, 서명 권한, 최초 업로드 검증을 마친 뒤 켜야 합니다.")
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
    }

    private var cloudKitFeedbackItems: [FeedbackItem] {
        let color: Color = cloudKitState.isReadyForSync ? .green : .secondary
        let symbol = cloudKitState.isReadyForSync ? "checkmark.icloud" : "icloud"
        return [
            FeedbackItem(
                text: "\(cloudKitState.title): \(cloudKitState.message)",
                systemImage: symbol,
                color: color
            )
        ]
    }

    private func checkCloudKitStatus() async {
        guard !isCheckingCloudKit else { return }
        isCheckingCloudKit = true
        defer { isCheckingCloudKit = false }
        cloudKitState = await VocabCloudKitStatusService().accountStatus()
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
