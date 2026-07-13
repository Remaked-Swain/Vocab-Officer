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
    @State private var cloudKitState: VocabCloudKitAccountState = .unknown
    @State private var isChecking = false

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

            Section("동기화 활성화 조건") {
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
            }
        }
    }

    private var readiness: VocabCloudSyncReadiness {
        VocabCloudSyncReadinessPolicy.current(accountState: cloudKitState)
    }

    private func checkCloudKitStatus() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        cloudKitState = await VocabCloudKitStatusService().accountStatus()
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
