// 이 파일은 대화 원문의 Markdown 블록을 선택 가능한 SwiftUI 콘텐츠로 표시한다.

import AppKit
import AVFoundation
import Combine
import MarkdownUI
import OfficeCore
import SwiftUI

private struct LiveWorkspaceFeedPresentationStoreKey: EnvironmentKey {
    static let defaultValue: LiveWorkspaceFeedPresentationStore? = nil
}

extension EnvironmentValues {
    var liveWorkspaceFeedPresentationStore:
        LiveWorkspaceFeedPresentationStore?
    {
        get { self[LiveWorkspaceFeedPresentationStoreKey.self] }
        set { self[LiveWorkspaceFeedPresentationStoreKey.self] = newValue }
    }
}

struct ConversationMarkdownView: View {
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let allowsTextSelection: Bool

    init(
        source: String,
        fontSize: CGFloat = 12,
        fileBaseDirectory: String? = nil,
        allowsTextSelection: Bool = true
    ) {
        self.source = source
        self.fontSize = fontSize
        self.fileBaseDirectory = fileBaseDirectory
        self.allowsTextSelection = allowsTextSelection
    }

    var body: some View {
        ConversationMarkdownContent(
            source: source,
            fontSize: fontSize,
            fileBaseDirectory: fileBaseDirectory,
            allowsTextSelection: allowsTextSelection
        )
        .equatable()
    }
}

private struct ConversationMarkdownContent: View, Equatable {
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let allowsTextSelection: Bool

    var body: some View {
        let fallbackDirectory = fileBaseDirectory.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        }
        let videoURLs = LocalMarkdownResource.videoFileURLs(
            in: source,
            fallbackDirectory: fallbackDirectory
        )

        let content = VStack(alignment: .leading, spacing: 9) {
            Markdown(
                ConversationMarkdownCache.shared.content(
                    for: source,
                    fallbackDirectory: fallbackDirectory
                )
            )
            .markdownImageProvider(
                LocalMarkdownImageProvider(
                    fallbackDirectory: fallbackDirectory
                )
            )
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
            ForEach(Array(videoURLs.prefix(4)), id: \.self) { videoURL in
                LocalMarkdownFileVideo(url: videoURL)
            }
        }
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard
                        let fileURL = LocalMarkdownResource.existingFileURL(
                            from: url,
                            fallbackDirectory: fallbackDirectory
                        )
                    else {
                        return LocalMarkdownResource.fileURL(from: url) == nil
                            ? .systemAction
                            : .discarded
                    }

                    if !NSWorkspace.shared.open(fileURL) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [fileURL]
                        )
                    }
                    return .handled
                }
            )

        if allowsTextSelection {
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 완료 응답을 타이핑하는 동안에는 이 Markdown이 실제 표시용이
            // 아니라 높이 예약용으로도 만들어진다. 선택 오버레이를 만들면
            // 직원 전환 직후 스크롤과 겹쳐 SwiftUI가 갱신 루프에 빠질 수 있다.
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    func content(
        for source: String,
        fallbackDirectory: URL?
    ) -> MarkdownContent {
        let trimmed = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rendered = trimmed.isEmpty
            ? "내용 없음"
            : LocalMarkdownResource.addingLinkedImagePreviews(
                to: trimmed,
                fallbackDirectory: fallbackDirectory
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
    let fallbackDirectory: URL?

    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if
            let url,
            let fileURL = LocalMarkdownResource.imageFileURL(
                from: url,
                fallbackDirectory: fallbackDirectory
            )
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

private struct LocalMarkdownFileVideo: View {
    let url: URL
    @Environment(\.liveWorkspaceFeedPresentationStore)
    private var feedPresentationStore
    @State private var isPlaying = false
    @State private var aspectRatio =
        ConversationMarkdownVideoLayout.fallbackAspectRatio

    var body: some View {
        ZStack {
            LocalMarkdownVideoSurface(
                url: url,
                isPlaying: isPlaying
            )
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(maxWidth: ConversationMarkdownVideoLayout.maximumWidth)
            .clipShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )

            Button {
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "영상 일시 정지" : "영상 재생")
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url) {
            await loadAspectRatio()
        }
        .onDisappear {
            isPlaying = false
        }
        .onReceive(feedPresentationPublisher) { isPresented in
            if !isPresented {
                isPlaying = false
            }
        }
    }

    private var feedPresentationPublisher: AnyPublisher<Bool, Never> {
        if let feedPresentationStore {
            return feedPresentationStore.$isPresented.eraseToAnyPublisher()
        }
        return Just(true).eraseToAnyPublisher()
    }

    @MainActor
    private func loadAspectRatio() async {
        if
            let cached = ConversationMarkdownVideoAspectRatioCache.shared
                .aspectRatio(for: url)
        {
            aspectRatio = cached
            return
        }

        let asset = AVURLAsset(url: url)
        guard
            let tracks = try? await asset.loadTracks(withMediaType: .video),
            let track = tracks.first,
            let naturalSize = try? await track.load(.naturalSize),
            let preferredTransform = try? await track.load(.preferredTransform)
        else {
            return
        }

        let loadedAspectRatio = ConversationMarkdownVideoLayout.aspectRatio(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        ConversationMarkdownVideoAspectRatioCache.shared.store(
            loadedAspectRatio,
            for: url
        )
        aspectRatio = loadedAspectRatio
    }
}

@MainActor
final class ConversationMarkdownVideoAspectRatioCache {
    static let shared = ConversationMarkdownVideoAspectRatioCache()

    private let storage = NSCache<NSURL, NSNumber>()

    init(countLimit: Int = 32) {
        storage.countLimit = countLimit
    }

    func aspectRatio(for url: URL) -> CGFloat? {
        guard let value = storage.object(forKey: url as NSURL) else {
            return nil
        }
        return CGFloat(truncating: value)
    }

    func store(_ aspectRatio: CGFloat, for url: URL) {
        storage.setObject(NSNumber(value: aspectRatio), forKey: url as NSURL)
    }
}

enum ConversationMarkdownVideoLayout {
    static let maximumWidth: CGFloat = 294
    static let fallbackAspectRatio: CGFloat = 9 / 16

    static func aspectRatio(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGFloat {
        let displayedSize = naturalSize.applying(preferredTransform)
        let width = abs(displayedSize.width)
        let height = abs(displayedSize.height)
        guard width > 0, height > 0 else {
            return fallbackAspectRatio
        }
        return width / height
    }
}

private struct LocalMarkdownVideoSurface: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let player = AVPlayer(url: url)
        player.isMuted = true
        let view = PlayerLayerView(player: player)
        view.setAccessibilityLabel("대화 로컬 동영상")
        context.coordinator.startLooping(player)
        return view
    }

    func updateNSView(
        _ nsView: PlayerLayerView,
        context: Context
    ) {
        if isPlaying {
            nsView.player.play()
        } else {
            nsView.player.pause()
        }
    }

    static func dismantleNSView(
        _ nsView: PlayerLayerView,
        coordinator: Coordinator
    ) {
        coordinator.stopLooping()
        nsView.player.pause()
    }

    final class Coordinator {
        private var endObserver: NSObjectProtocol?

        func startLooping(_ player: AVPlayer) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
        }

        func stopLooping() {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
            endObserver = nil
        }

        deinit {
            stopLooping()
        }
    }

    final class PlayerLayerView: NSView {
        let player: AVPlayer
        private let playerLayer: AVPlayerLayer

        init(player: AVPlayer) {
            self.player = player
            playerLayer = AVPlayerLayer(player: player)
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
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
