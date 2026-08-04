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

                if showsFeedback {
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

                    Button {
                        toggleFeedback(.disliked)
                    } label: {
                        BrokenHeartIcon(isSelected: feedback == .disliked)
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
                }
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

private struct BrokenHeartIcon: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            brokenHalf(mask: BrokenHeartLeftMask())
                .offset(
                    x: isSelected ? -1.7 : -0.25,
                    y: isSelected ? 0.8 : 0
                )
            brokenHalf(mask: BrokenHeartRightMask())
                .offset(
                    x: isSelected ? 1.7 : 0.25,
                    y: isSelected ? -0.8 : 0
                )
        }
        .frame(width: 14, height: 14)
        .animation(
            .spring(response: 0.24, dampingFraction: 0.62),
            value: isSelected
        )
    }

    private func brokenHalf<Mask: Shape>(mask: Mask) -> some View {
        Image(systemName: isSelected ? "heart.fill" : "heart")
            .resizable()
            .scaledToFit()
            .foregroundStyle(isSelected ? Color.gray : Color.secondary)
            .mask(mask)
    }
}

private struct BrokenHeartLeftMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.height * 0.27))
        path.addLine(to: CGPoint(x: rect.midX + 1, y: rect.height * 0.39))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.midX + 0.5, y: rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct BrokenHeartRightMask: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + 0.5, y: rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.midX + 1, y: rect.height * 0.39))
        path.addLine(to: CGPoint(x: rect.midX - 1, y: rect.height * 0.27))
        path.closeSubpath()
        return path
    }
}
