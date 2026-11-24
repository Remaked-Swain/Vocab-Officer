import SwiftUI

/// Layout tokens shared by the macOS and iOS targets so both platforms keep one
/// visual rhythm for cards, panels and grids.
enum VocabMetrics {
    static let cardCornerRadius: CGFloat = 18
    static let panelCornerRadius: CGFloat = 14
    static let cardGridMinimumWidth: CGFloat = 210
    static let cardGridSpacing: CGFloat = 16

    static var cardGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardGridMinimumWidth), spacing: cardGridSpacing)]
    }
}

extension WordRecord {
    /// Every active meaning in registration order, joined for display.
    var meaningsDisplayText: String {
        activeMeanings.map(\.text).joined(separator: ", ")
    }
}

extension FinalResult {
    /// The order in which the final judgement control and its Tab shortcut cycle.
    static let judgementOrder: [FinalResult] = [.correct, .incorrect, .unknown]

    var title: String {
        switch self {
        case .correct: "정답"
        case .incorrect: "오답"
        case .unknown: "모름"
        }
    }

    var systemImage: String {
        switch self {
        case .correct: "checkmark.circle.fill"
        case .incorrect: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .correct: .green
        case .incorrect: .red
        case .unknown: .orange
        }
    }
}

extension PracticeDirection {
    var shortTitle: String {
        switch self {
        case .enToKo: "영 → 한"
        case .koToEn: "한 → 영"
        }
    }
}

extension SessionMode {
    /// What the mode draws from, shown under the mode picker on both platforms.
    var setupDescription: String {
        switch self {
        case .review:
            "미암기 단어를 우선하고, 직전 등록일 단어와 점검 기한이 지난 장기정착 단어를 함께 출제합니다."
        case .mixed:
            "활성 복습과 장기정착 점검을 일부 포함하고 단어장 전체를 넓게 순환합니다. 오늘 아직 나오지 않은 단어가 있으면 같은 단어를 반복하지 않습니다."
        case .today, .set, .loose:
            "오늘 등록한 단어를 출제하며, 없으면 가장 최근 등록일의 단어를 사용합니다."
        }
    }
}

extension QuestionFormat {
    var setupDescription: String {
        switch self {
        case .typed: "정답을 직접 입력하는 기본 테스트입니다."
        case .multipleChoice: "4개의 선택지 중 정답을 고르는 가벼운 복습입니다."
        }
    }

    var startButtonTitle: String {
        switch self {
        case .typed: "직접 입력 테스트 시작"
        case .multipleChoice: "4지선택형 테스트 시작"
        }
    }
}

extension VocabularyLearningStatus {
    var tint: Color {
        switch self {
        case .active: .blue
        case .consolidating: .green
        case .mastered: .purple
        }
    }
}

/// A compact capsule used for statuses and judgements on both platforms.
struct StatusBadge: View {
    let title: String
    var systemImage: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A learning card that flips between the headword and its meanings. Flipping
/// only changes presentation; it never records progress.
struct WordFlipCard<Accessory: View>: View {
    let word: WordSummary
    @Binding var showsMeaning: Bool
    var height: CGFloat = 146
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let meanings = word.meaningsText
        Button {
            withAnimation(.bouncy(duration: 0.45, extraBounce: 0.10)) {
                showsMeaning.toggle()
            }
        } label: {
            ZStack {
                cardFace(caption: "영단어", value: word.term, isBack: false)
                    .opacity(showsMeaning ? 0 : 1)
                    .rotation3DEffect(.degrees(showsMeaning ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
                cardFace(caption: "의미", value: meanings, isBack: true)
                    .opacity(showsMeaning ? 1 : 0)
                    .rotation3DEffect(.degrees(showsMeaning ? 0 : -180), axis: (x: 0, y: 1, z: 0), perspective: 0.65)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .shadow(color: showsMeaning ? .accentColor.opacity(0.16) : .black.opacity(0.06), radius: 8, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: VocabMetrics.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(word.term)
        .accessibilityValue(showsMeaning ? meanings : "영단어 앞면")
        .accessibilityHint("눌러서 카드 앞뒤를 전환합니다")
        // Actions sit beside the caption row, outside the flip button, so they
        // never overlap the headword and stay reachable on both faces.
        .overlay(alignment: .topTrailing) {
            accessory()
                .padding(10)
        }
    }

    private func cardFace(caption: String, value: String, isBack: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: VocabMetrics.cardCornerRadius, style: .continuous)
        return shape
            .fill(isBack ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.background.secondary))
            .overlay {
                shape.stroke(isBack ? Color.accentColor.opacity(0.40) : Color.secondary.opacity(0.20), lineWidth: 1)
            }
            .overlay {
                VStack(spacing: 8) {
                    Text(caption)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isBack ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(value)
                        .font(isBack ? .body.weight(.medium) : .title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.72)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
    }
}

extension WordFlipCard where Accessory == EmptyView {
    init(word: WordSummary, showsMeaning: Binding<Bool>, height: CGFloat = 146) {
        self.init(word: word, showsMeaning: showsMeaning, height: height) { EmptyView() }
    }
}

/// A static review card. Meanings are never truncated (learning policy).
struct ReviewWordCard<Accessory: View>: View {
    let word: WordSummary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let meanings = word.meaningsText
        let failureCheck = word.failureCheck
        let activePriority = word.activePriority
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(word.term)
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                accessory()
            }
            Text(meanings)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                StatusBadge(title: "복습 우선도 \(activePriority)", systemImage: "arrow.clockwise", tint: .accentColor)
                StatusBadge(title: "실패 체크 \(failureCheck)", systemImage: "exclamationmark.circle", tint: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: VocabMetrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VocabMetrics.cardCornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("원문 \(word.term), 의미 \(meanings), 복습 우선도 \(activePriority), 실패 체크 \(failureCheck)")
    }
}

extension ReviewWordCard where Accessory == EmptyView {
    init(word: WordSummary) {
        self.init(word: word) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// Bumped by the root view on every save or import into the store, so pages
    /// that render prepared snapshots know when to rebuild them.
    @Entry var vocabStoreRevision = 0
}

/// When a page rebuilds its snapshot after a store change.
enum PageReloadPolicy {
    static let coalescingDelay: Duration = .milliseconds(200)

    /// The first load runs at once; a reload waits briefly so a burst of saves
    /// or imports, which restarts the page's `task(id:)`, rebuilds only once.
    static func shouldLoad(hasSnapshot: Bool) async -> Bool {
        if hasSnapshot {
            // Sleep only throws on cancellation, which the return value reports.
            try? await Task.sleep(for: coalescingDelay)
        }
        return !Task.isCancelled
    }
}

/// Placeholder shown while a page snapshot is prepared off the main actor.
struct PageLoadingView: View {
    var body: some View {
        ProgressView()
            .controlSize(.regular)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("불러오는 중")
    }
}
