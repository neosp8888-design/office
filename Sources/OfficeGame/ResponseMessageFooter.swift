// 이 파일은 일반 대화 응답의 시간과 복사 동작을 세로로 배치한다.

import SwiftUI

struct ResponseMessageFooter: View {
    static let timestampFontWeight: Font.Weight = .medium

    let occurredAt: Date
    let copied: Bool
    let accentColor: Color
    let accessibilityID: String
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(occurredAt.formatted(date: .omitted, time: .standard))
                .font(.system(
                    size: 8.5,
                    weight: Self.timestampFontWeight,
                    design: .monospaced
                ))
                .foregroundStyle(.tertiary)

            Button(action: copy) {
                Label(
                    copied ? "복사됨" : "복사",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(copied ? accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(copied ? "메시지 복사됨" : "메시지 복사")
            .accessibilityIdentifier(accessibilityID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
