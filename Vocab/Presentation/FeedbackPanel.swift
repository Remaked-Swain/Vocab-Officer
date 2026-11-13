import SwiftUI

struct FeedbackItem {
    let text: String
    let systemImage: String
    let color: Color
}

enum VocabularyRegistrationFeedback {
    static func successMessage(for result: VocabularyRegistrationResult) -> String {
        var details = ["신규 표제어 \(result.createdHeadwordCount)개"]
        if result.matchedExistingHeadwordCount > 0 {
            details.append("기존 표제어와 통합 \(result.matchedExistingHeadwordCount)개")
        }
        if result.duplicateInputRowCount > 0 {
            details.append("입력 내 중복 행 통합 \(result.duplicateInputRowCount)개")
        }
        if result.meaningsAddedToExistingHeadwords > 0 {
            details.append("기존 표제어에 새 뜻 추가 \(result.meaningsAddedToExistingHeadwords)개")
        }

        var message = "입력 \(result.inputRowCount)개를 모두 처리했습니다. \(details.joined(separator: " · "))."
        if result.matchedExistingHeadwordCount > 0 || result.duplicateInputRowCount > 0 {
            message += " 기존 표제어는 최초 등록일에 유지되며, 이번 저장으로 현재 등록일 그룹에 신규 \(result.createdHeadwordCount)개가 추가됩니다."
        }
        return message
    }
}

struct FeedbackPanel: View {
    let items: [FeedbackItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item.text, systemImage: item.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.color)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}
