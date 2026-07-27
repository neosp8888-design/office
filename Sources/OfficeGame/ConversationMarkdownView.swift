// 이 파일은 대화 원문의 Markdown 블록을 선택 가능한 SwiftUI 콘텐츠로 표시한다.

import AppKit
import MarkdownUI
import OfficeCore
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
            .markdownImageProvider(LocalMarkdownImageProvider())
            .markdownInlineImageProvider(.asset)
            .markdownTextStyle(\.text) {
                FontSize(fontSize)
            }
            .markdownBlockStyle(\.image) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .markdownMargin(top: 8, bottom: 8)
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
            .markdownTheme(.gitHub)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard
                        let fileURL = LocalMarkdownResource.fileURL(
                            from: url
                        )
                    else {
                        return .systemAction
                    }
                    guard FileManager.default.fileExists(
                        atPath: fileURL.path
                    ) else {
                        return .discarded
                    }

                    if !NSWorkspace.shared.open(fileURL) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [fileURL]
                        )
                    }
                    return .handled
                }
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedSource: String {
        let trimmed = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty
            ? "내용 없음"
            : LocalMarkdownResource.addingLinkedImagePreviews(
                to: trimmed
            )
    }
}

private struct LocalMarkdownImageProvider: ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if
            let url,
            let fileURL = LocalMarkdownResource.imageFileURL(from: url),
            let image = NSImage(contentsOf: fileURL)
        {
            LocalMarkdownThumbnail(image: image)
        } else if
            let url,
            url.scheme == nil,
            !url.path.hasPrefix("/"),
            let image = NSImage(named: url.lastPathComponent)
        {
            LocalMarkdownThumbnail(image: image)
        }
    }
}

private struct LocalMarkdownThumbnail: View {
    let image: NSImage

    var body: some View {
        let size = fittedSize

        Image(nsImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .clipShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
                .stroke(Color.primary.opacity(0.10))
            }
    }

    private var fittedSize: CGSize {
        let original = image.size
        guard original.width > 0, original.height > 0 else {
            return CGSize(width: 240, height: 180)
        }

        let scale = min(
            1,
            320 / original.width,
            240 / original.height
        )
        return CGSize(
            width: max(1, floor(original.width * scale)),
            height: max(1, floor(original.height * scale))
        )
    }
}
