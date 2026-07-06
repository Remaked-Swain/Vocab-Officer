import SwiftUI

struct FeedbackItem {
    let text: String
    let systemImage: String
    let color: Color
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
