// 이 파일은 일반 대화 응답의 시간과 복사 및 평가 아이콘을 배치한다.

import SwiftUI

struct ResponseMessageFooter: View {
    static let timestampFontWeight: Font.Weight = .medium

    let occurredAt: Date
    let copied: Bool
    let accentColor: Color
    let accessibilityID: String
    let showsFeedback: Bool
    let feedback: TurnResponseFeedback?
    let feedbackAccessibilityIDPrefix: String
    let copy: () -> Void
    let feedbackChanged: (TurnResponseFeedback?) async -> Void

    @State private var isUpdatingFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(occurredAt.formatted(date: .omitted, time: .standard))
                .font(.system(
                    size: 8.5,
                    weight: Self.timestampFontWeight,
                    design: .monospaced
                ))
                .foregroundStyle(.tertiary)

            HStack(spacing: 7) {
                if showsFeedback {
                    Button {
                        toggleFeedback(.disliked)
                    } label: {
                        Image(
                            systemName: feedback == .disliked
                                ? "hand.thumbsdown.fill"
                                : "hand.thumbsdown"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            feedback == .disliked
                                ? Color.gray
                                : Color.secondary
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingFeedback)
                    .accessibilityLabel(
                        feedback == .disliked ? "싫어요 취소" : "싫어요"
                    )
                    .accessibilityIdentifier(
                        "dislikeMessage-\(feedbackAccessibilityIDPrefix)"
                    )

                    Button {
                        toggleFeedback(.liked)
                    } label: {
                        Image(
                            systemName: feedback == .liked
                                ? "heart.fill"
                                : "heart"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(
                            feedback == .liked ? Color.red : Color.secondary
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingFeedback)
                    .accessibilityLabel(
                        feedback == .liked ? "좋아요 취소" : "좋아요"
                    )
                    .accessibilityIdentifier(
                        "likeMessage-\(feedbackAccessibilityIDPrefix)"
                    )
                }

                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            copied ? accentColor : Color.secondary
                        )
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "복사됨" : "복사")
                .accessibilityIdentifier(accessibilityID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleFeedback(_ selection: TurnResponseFeedback) {
        guard !isUpdatingFeedback else {
            return
        }
        let nextFeedback = TurnResponseFeedback.toggled(
            current: feedback,
            selection: selection
        )
        isUpdatingFeedback = true
        Task {
            await feedbackChanged(nextFeedback)
            isUpdatingFeedback = false
        }
    }
}
