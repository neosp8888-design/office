// 이 파일은 캐릭터 클릭 영역과 이름이 포함된 말풍선을 장면 위에 표시한다.

import OfficeCore
import SwiftUI

struct CharacterInteractionLayer: View {
    @ObservedObject var director: AgentDirector
    let onMonitorTapped: (OfficeCharacter) -> Void
    let onArchiveCabinetTapped: () -> Void
    let onBubbleTapped: (OfficeCharacter, String) -> Void

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
                    if let message = director.bubbles[character.id] {
                        let isThinking = director.runningCharacters.contains(
                            character.id
                        )

                        Button {
                            onBubbleTapped(character.id, message)
                        } label: {
                            CharacterSpeechBubble(
                                name: director.displayName(for: character.id),
                                message: message,
                                isThinking: isThinking
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
                        .transition(.opacity)
                        .accessibilityLabel(
                            "\(director.displayName(for: character.id)) 응답 전문 보기"
                        )
                        .help("응답 전문 보기")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: director.bubbles)
        }
    }
}

private struct CharacterSpeechBubble: View {
    let name: String
    let message: String
    let isThinking: Bool

    var body: some View {
        VStack(spacing: -1) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.62))

                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: 250, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            )

            SpeechBubbleTail()
                .fill(.white.opacity(0.96))
                .frame(width: 16, height: 9)
        }
        .opacity(isThinking ? 0.9 : 1)
    }
}

private struct SpeechBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
