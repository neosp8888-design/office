// 이 파일은 대화 원문의 Markdown 블록을 선택 가능한 SwiftUI 콘텐츠로 표시한다.

import Foundation
import MarkdownUI
import SwiftUI

struct ConversationMarkdownView: View {
    let source: String
    let fontSize: CGFloat

    init(source: String, fontSize: CGFloat = 12) {
        self.source = source
        self.fontSize = fontSize
    }

    var body: some View {
        Markdown(renderedSource)
            .markdownTheme(.gitHub)
            .markdownImageProvider(.asset)
            .markdownInlineImageProvider(.asset)
            .markdownTextStyle(\.text) {
                FontSize(fontSize)
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTableBorderStyle(
                            .init(color: Color.primary.opacity(0.18))
                        )
                        .markdownTableBackgroundStyle(
                            .alternatingRows(
                                Color.clear,
                                Color.primary.opacity(0.035),
                                header: Color.primary.opacity(0.07)
                            )
                        )
                }
                .markdownMargin(top: 0, bottom: 16)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedSource: String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "내용 없음"
            : source
    }
}
