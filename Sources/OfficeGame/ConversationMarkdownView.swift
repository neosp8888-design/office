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
        ConversationMarkdownContent(
            source: source,
            fontSize: fontSize
        )
        .equatable()
    }
}

private struct ConversationMarkdownContent: View, Equatable {
    let source: String
    let fontSize: CGFloat

    var body: some View {
        Markdown(
            ConversationMarkdownCache.shared.content(for: source)
        )
            .markdownImageProvider(LocalMarkdownImageProvider())
            .markdownInlineImageProvider(.asset)
            .markdownTextStyle(\.text) {
                FontSize(fontSize)
            }
            .markdownTextStyle(\.code) {
                FontFamily(.system())
                FontFamilyVariant(.normal)
                FontSize(fontSize)
                BackgroundColor(Color.primary.opacity(0.055))
            }
            .markdownCodeSyntaxHighlighter(
                ConversationCodeSyntaxHighlighter()
            )
            .markdownBlockStyle(\.codeBlock) { configuration in
                ConversationCodeBlockView(
                    configuration: configuration,
                    fontSize: fontSize
                )
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
}

@MainActor
private final class ConversationMarkdownCache {
    private final class Entry {
        let content: MarkdownContent

        init(content: MarkdownContent) {
            self.content = content
        }
    }

    static let shared = ConversationMarkdownCache()

    private let storage = NSCache<NSString, Entry>()

    private init() {
        storage.countLimit = 64
        storage.totalCostLimit = 4 * 1_024 * 1_024
    }

    func content(for source: String) -> MarkdownContent {
        let trimmed = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rendered = trimmed.isEmpty
            ? "내용 없음"
            : LocalMarkdownResource.addingLinkedImagePreviews(
                to: trimmed
            )
        let key = rendered as NSString
        if let entry = storage.object(forKey: key) {
            return entry.content
        }

        let content = MarkdownContent(rendered)
        storage.setObject(
            Entry(content: content),
            forKey: key,
            cost: max(1, rendered.utf8.count)
        )
        return content
    }
}

private struct LocalMarkdownImageProvider: ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if
            let url,
            let fileURL = LocalMarkdownResource.imageFileURL(from: url)
        {
            LocalMarkdownFileImage(url: fileURL)
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

private struct LocalMarkdownFileImage: View {
    let url: URL
    @State private var image: NSImage?

    init(url: URL) {
        self.url = url
        _image = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let image {
                LocalMarkdownThumbnail(image: image)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .frame(width: 240, height: 160)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        if let cached = LocalMarkdownImageCache.shared.image(at: url) {
            image = cached
            return
        }

        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url, options: .mappedIfSafe)
        }.value
        guard
            !Task.isCancelled,
            let data,
            let loadedImage = NSImage(data: data)
        else {
            return
        }
        LocalMarkdownImageCache.shared.store(loadedImage, at: url)
        image = loadedImage
    }
}

@MainActor
final class LocalMarkdownImageCache {
    static let shared = LocalMarkdownImageCache()

    private let storage = NSCache<NSString, NSImage>()

    private init() {
        storage.countLimit = 32
        storage.totalCostLimit = 64 * 1_024 * 1_024
    }

    func image(at url: URL) -> NSImage? {
        storage.object(forKey: cacheKey(for: url))
    }

    func store(_ image: NSImage, at url: URL) {
        let estimatedCost = max(
            1,
            image.representations.reduce(0) { current, representation in
                max(
                    current,
                    representation.pixelsWide
                        * representation.pixelsHigh
                        * 4
                )
            }
        )
        storage.setObject(
            image,
            forKey: cacheKey(for: url),
            cost: estimatedCost
        )
    }

    private func cacheKey(for url: URL) -> NSString {
        let values = try? url.resourceValues(
            forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
            ]
        )
        let modifiedAt =
            values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = values?.fileSize ?? 0
        return "\(url.path)|\(modifiedAt)|\(fileSize)" as NSString
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
