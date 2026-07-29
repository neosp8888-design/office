// 이 파일은 캐릭터 클릭 영역과 이름이 포함된 말풍선을 장면 위에 표시한다.

import OfficeCore
import SwiftUI

struct CharacterInteractionLayer: View {
    @ObservedObject var director: AgentDirector
    @ObservedObject private var speechBubbleStore: SpeechBubbleStore
    let onMonitorTapped: (OfficeCharacter) -> Void
    let onArchiveCabinetTapped: () -> Void
    let onWhiteboardTapped: () -> Void
    let onBubbleTapped: (OfficeCharacter, String) -> Void

    init(
        director: AgentDirector,
        onMonitorTapped: @escaping (OfficeCharacter) -> Void,
        onArchiveCabinetTapped: @escaping () -> Void,
        onWhiteboardTapped: @escaping () -> Void,
        onBubbleTapped: @escaping (OfficeCharacter, String) -> Void
    ) {
        self.director = director
        _speechBubbleStore = ObservedObject(
            wrappedValue: director.speechBubbleStore
        )
        self.onMonitorTapped = onMonitorTapped
        self.onArchiveCabinetTapped = onArchiveCabinetTapped
        self.onWhiteboardTapped = onWhiteboardTapped
        self.onBubbleTapped = onBubbleTapped
    }

    var body: some View {
        GeometryReader { geometry in
            let fittedFrame = OfficeCanvasGeometry.fittedFrame(
                in: geometry.size
            )
            let scale =
                fittedFrame.width / OfficeCanvasGeometry.designSize.width

            ZStack {
                ForEach(director.characters) { character in
                    Button {
                        director.select(character)
                    } label: {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: character.hitbox.width * scale,
                        height: character.hitbox.height * scale
                    )
                    .position(
                        x: fittedFrame.minX
                            + character.hitbox.rect.midX * scale,
                        y: fittedFrame.minY
                            + character.hitbox.rect.midY * scale
                    )
                    .accessibilityLabel(
                        "\(director.displayName(for: character.id)) 선택"
                    )
                }

                Button(action: onArchiveCabinetTapped) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(
                    width: director.archiveCabinetHitbox.width * scale,
                    height: director.archiveCabinetHitbox.height * scale
                )
                .position(
                    x: fittedFrame.minX
                        + director.archiveCabinetHitbox.rect.midX * scale,
                    y: fittedFrame.minY
                        + director.archiveCabinetHitbox.rect.midY * scale
                )
                .accessibilityLabel("전체 대화 보관함 열기")
                .help("전체 대화 보관함")

                Button(action: onWhiteboardTapped) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(
                    width:
                        OfficeWhiteboardGeometry.interactionRect.width
                        * scale,
                    height:
                        OfficeWhiteboardGeometry.interactionRect.height
                        * scale
                )
                .position(
                    x: fittedFrame.minX
                        + OfficeWhiteboardGeometry.interactionRect.midX
                        * scale,
                    y: fittedFrame.minY
                        + OfficeWhiteboardGeometry.interactionRect.midY
                        * scale
                )
                .accessibilityLabel("화이트보드 상세 열기")
                .help("CLI 한도 상세")

                ForEach(director.characters) { character in
                    Button {
                        onMonitorTapped(character.id)
                    } label: {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(
                        width: character.monitorHitbox.width * scale,
                        height: character.monitorHitbox.height * scale
                    )
                    .position(
                        x: fittedFrame.minX
                            + character.monitorHitbox.rect.midX * scale,
                        y: fittedFrame.minY
                            + character.monitorHitbox.rect.midY * scale
                    )
                    .accessibilityLabel(
                        "\(director.displayName(for: character.id)) 대화 열기"
                    )
                    .help(
                        "\(director.displayName(for: character.id)) 대화 내역"
                    )
                }

                ForEach(director.characters) { character in
                    if let message =
                        speechBubbleStore.bubbles[character.id]
                    {
                        let isThinking = director.runningCharacters.contains(
                            character.id
                        )
                        let isQuestion =
                            director.pendingQuestion(for: character.id) != nil
                        let isFailure =
                            director.failureMessage(for: character.id) != nil
                        let isOffDuty =
                            director.offDutyReason(for: character.id) != nil

                        Button {
                            onBubbleTapped(character.id, message)
                        } label: {
                            CharacterSpeechBubble(
                                name: director.displayName(for: character.id),
                                message: message,
                                isThinking: isThinking,
                                isQuestion: isQuestion,
                                isFailure: isFailure,
                                isOffDuty: isOffDuty,
                                tailEdge:
                                    character.id == .boss
                                    ? .leading
                                    : .bottom
                            )
                            .id(message)
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.88)
                                        .combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .position(
                            x: fittedFrame.minX
                                + character.bubble.x * scale,
                            y: fittedFrame.minY
                                + character.bubble.y * scale
                        )
                        .allowsHitTesting(!isThinking)
                        .transition(
                            .scale(scale: 0.88).combined(with: .opacity)
                        )
                        .accessibilityLabel(
                            isQuestion
                                ? "\(director.displayName(for: character.id)) 질문에 답변하기"
                                : isOffDuty
                                ? "\(director.displayName(for: character.id)) 퇴근 사유 보기"
                                : isFailure
                                ? "\(director.displayName(for: character.id)) 중단 원인 보기"
                                : "\(director.displayName(for: character.id)) 응답 전문 보기"
                        )
                        .help(
                            isQuestion
                                ? "질문에 답변하기"
                                : isOffDuty
                                ? "퇴근 사유 보기"
                                : isFailure
                                ? "중단 원인 보기"
                                : "응답 전문 보기"
                        )
                    }
                }
            }
            .animation(
                .spring(response: 0.30, dampingFraction: 0.72),
                value: speechBubbleStore.bubbles
            )
        }
    }
}

private struct CharacterSpeechBubble: View {
    let name: String
    let message: String
    let isThinking: Bool
    let isQuestion: Bool
    let isFailure: Bool
    let isOffDuty: Bool
    let tailEdge: SpeechBubbleTailEdge

    var body: some View {
        Group {
            if tailEdge == .leading {
                HStack(spacing: -1) {
                    SpeechBubbleTail(edge: .leading)
                        .fill(bubbleColor)
                        .frame(width: 6, height: 10)
                    bubbleCard
                }
            } else {
                VStack(spacing: -1) {
                    bubbleCard
                    SpeechBubbleTail(edge: .bottom)
                        .fill(bubbleColor)
                        .frame(width: 10, height: 6)
                }
            }
        }
        .opacity(isThinking ? 0.9 : 1)
    }

    private var bubbleCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(name)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .lineLimit(1)

                statusLabel
            }

            Text(message)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.86))
                .lineLimit(isThinking ? 1 : 5)
                .minimumScaleFactor(isThinking ? 0.78 : 1)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: 75, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(bubbleColor)
                .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
        )
        .overlay {
            if isQuestion || isFailure || isOffDuty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(statusColor, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if isQuestion {
            Label("질문", systemImage: "questionmark.bubble.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(
                    Color(red: 0.56, green: 0.35, blue: 0.08)
                )
        } else if isOffDuty {
            Label("퇴근", systemImage: "moon.zzz.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(
                    Color(red: 0.23, green: 0.32, blue: 0.57)
                )
        } else if isFailure {
            Label("중단", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(
                    Color(red: 0.67, green: 0.14, blue: 0.12)
                )
        }
    }

    private var statusColor: Color {
        isOffDuty
            ? Color(red: 0.33, green: 0.43, blue: 0.72)
            : isFailure
            ? Color(red: 0.78, green: 0.20, blue: 0.17)
            : Color(red: 0.78, green: 0.52, blue: 0.16)
    }

    private var bubbleColor: Color {
        isQuestion
            ? Color(red: 1.0, green: 0.97, blue: 0.86).opacity(0.98)
            : isOffDuty
            ? Color(red: 0.91, green: 0.94, blue: 1.0).opacity(0.98)
            : isFailure
            ? Color(red: 1.0, green: 0.91, blue: 0.90).opacity(0.98)
            : .white.opacity(0.96)
    }
}

private enum SpeechBubbleTailEdge {
    case bottom
    case leading
}

private struct SpeechBubbleTail: Shape {
    let edge: SpeechBubbleTailEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .leading:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}
