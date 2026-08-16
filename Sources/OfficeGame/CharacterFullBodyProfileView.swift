// 이 파일은 선택한 직원의 전신 프로필을 별도 시트로 표시한다.

import AppKit
import AVFoundation
import OfficeCore
import SwiftUI

enum CharacterFullBodyProfileLayout {
    static let referenceContentWidth: CGFloat = 386
    static let horizontalPadding: CGFloat = 16
    static let previousImageWidthRatio: CGFloat = 0.5
    static let imageWidthScale: CGFloat = 1.8
    static let imageWidthRatio = previousImageWidthRatio * imageWidthScale
    static let imageAspectRatio: CGFloat = 0.5

    static let imageWidth = referenceContentWidth * imageWidthRatio

    static var imageHeight: CGFloat {
        imageWidth / imageAspectRatio
    }

    static var sheetWidth: CGFloat {
        imageWidth + (horizontalPadding * 2)
    }
}

enum CharacterFullBodyProfileCloseButtonMetrics {
    static let diameter: CGFloat = 18
    static let iconSize: CGFloat = 8
    static let hoverRotation = 90.0
    static let hoverScale = 1.08
    static let pressedScale = 0.88
}

enum CharacterFullBodyProfilePresentationMetrics {
    static let initialScale = 0.82
    static let initialRotation = 7.0
    static let initialVerticalOffset: CGFloat = 18
    static let avatarHoverScale = 1.08
    static let avatarPressedScale = 0.90
}

enum CharacterFullBodyProfileSelection {
    static let dragThreshold: CGFloat = 36
    static let crossfadeDuration: TimeInterval = 1.2

    static func previousIndex(from index: Int, count: Int) -> Int {
        guard count > 1 else {
            return 0
        }
        return (index - 1 + count) % count
    }

    static func nextIndex(from index: Int, count: Int) -> Int {
        guard count > 1 else {
            return 0
        }
        return (index + 1) % count
    }

    static func index(
        afterHorizontalDrag translation: CGFloat,
        from index: Int,
        count: Int
    ) -> Int {
        if translation <= -dragThreshold {
            return nextIndex(from: index, count: count)
        }
        if translation >= dragThreshold {
            return previousIndex(from: index, count: count)
        }
        return index
    }

}

struct CharacterFullBodyProfileView: View {
    let character: CharacterConfiguration
    let name: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedVideoIndex = 0
    @State private var outgoingVideoURL: URL?
    @State private var crossfadeProgress = 1.0
    @State private var isPresented = false

    private var image: NSImage? {
        CharacterFullBodyProfileImageCache.image(for: character.id)
    }

    private var videoURLs: [URL] {
        PixelOfficeAsset.fullBodyProfileVideoURLs(for: character.id)
    }

    private var selectedVideoURL: URL? {
        guard !videoURLs.isEmpty else {
            return nil
        }
        return videoURLs[selectedVideoIndex % videoURLs.count]
    }

    private var visibleVideoURLs: [URL] {
        guard let selectedVideoURL else {
            return []
        }
        if let outgoingVideoURL, outgoingVideoURL != selectedVideoURL {
            return [outgoingVideoURL, selectedVideoURL]
        }
        return [selectedVideoURL]
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                Text(name)
                    .font(.system(size: 22, weight: .bold))

                Spacer()

                AnimatedProfileCloseButton {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if selectedVideoURL != nil {
                ZStack {
                    ForEach(visibleVideoURLs, id: \.self) { videoURL in
                        CharacterFullBodyProfileVideo(
                            url: videoURL,
                            // 반복이 끝나도 다음 영상으로 넘기지 않는다.
                            // 전환은 사용자의 스와이프만 담당한다.
                            onLoopCompleted: {}
                        )
                        .id(videoURL)
                        .opacity(opacity(for: videoURL))
                    }
                }
                .frame(
                    width: CharacterFullBodyProfileLayout.imageWidth,
                    height: CharacterFullBodyProfileLayout.imageHeight
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            selectVideo(
                                CharacterFullBodyProfileSelection.index(
                                    afterHorizontalDrag: value.translation.width,
                                    from: selectedVideoIndex,
                                    count: videoURLs.count
                                )
                            )
                        }
                )
                .task(id: outgoingVideoURL) {
                    await completeCrossfadeIfNeeded()
                }
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(
                        width: CharacterFullBodyProfileLayout.imageWidth,
                        height: CharacterFullBodyProfileLayout.imageHeight
                    )
            }
        }
        .padding(CharacterFullBodyProfileLayout.horizontalPadding)
        .frame(width: CharacterFullBodyProfileLayout.sheetWidth)
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(
            isPresented
                ? 1
                : CharacterFullBodyProfilePresentationMetrics.initialScale
        )
        .rotation3DEffect(
            .degrees(
                isPresented
                    ? 0
                    : CharacterFullBodyProfilePresentationMetrics
                        .initialRotation
            ),
            axis: (x: 0.72, y: -0.38, z: 0)
        )
        .offset(
            y: isPresented
                ? 0
                : CharacterFullBodyProfilePresentationMetrics
                    .initialVerticalOffset
        )
        .onAppear {
            if reduceMotion {
                isPresented = true
            } else {
                withAnimation(
                    .spring(response: 0.56, dampingFraction: 0.74)
                ) {
                    isPresented = true
                }
            }
        }
    }

    private func opacity(for videoURL: URL) -> Double {
        if videoURL == outgoingVideoURL {
            return 1 - crossfadeProgress
        }
        if outgoingVideoURL != nil {
            return crossfadeProgress
        }
        return 1
    }

    private func selectVideo(_ index: Int) {
        guard
            outgoingVideoURL == nil,
            index != selectedVideoIndex,
            let selectedVideoURL
        else {
            return
        }

        outgoingVideoURL = selectedVideoURL
        crossfadeProgress = 0
        selectedVideoIndex = index
    }

    private func completeCrossfadeIfNeeded() async {
        guard outgoingVideoURL != nil else {
            return
        }

        await Task.yield()
        withAnimation(
            .easeInOut(
                duration: CharacterFullBodyProfileSelection.crossfadeDuration
            )
        ) {
            crossfadeProgress = 1
        }

        try? await Task.sleep(
            for: .seconds(
                CharacterFullBodyProfileSelection.crossfadeDuration
            )
        )
        guard !Task.isCancelled else {
            return
        }
        outgoingVideoURL = nil
    }
}

private struct AnimatedProfileCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(isHovered ? 0.72 : 0.46),
                                Color.indigo.opacity(isHovered ? 0.72 : 0.28),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .stroke(
                        AngularGradient(
                            colors: [
                                .cyan.opacity(0.9),
                                .purple.opacity(0.9),
                                .cyan.opacity(0.9),
                            ],
                            center: .center
                        ),
                        lineWidth: isHovered ? 1.8 : 0.8
                    )
                    .rotationEffect(.degrees(isHovered ? 180 : 0))

                Image(systemName: "xmark")
                    .font(
                        .system(
                            size: CharacterFullBodyProfileCloseButtonMetrics
                                .iconSize,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(.white)
                    .rotationEffect(
                        .degrees(
                            isHovered
                                ? CharacterFullBodyProfileCloseButtonMetrics.hoverRotation
                                : 0
                        )
                    )
            }
            .frame(
                width: CharacterFullBodyProfileCloseButtonMetrics.diameter,
                height: CharacterFullBodyProfileCloseButtonMetrics.diameter
            )
            .scaleEffect(
                isHovered
                    ? CharacterFullBodyProfileCloseButtonMetrics.hoverScale
                    : 1
            )
            .shadow(
                color: .cyan.opacity(isHovered ? 0.42 : 0.12),
                radius: isHovered ? 8 : 3
            )
            .contentShape(Circle())
        }
        .buttonStyle(AnimatedProfileCloseButtonPressStyle())
        .onHover { isHovered = $0 }
        .animation(
            .spring(response: 0.38, dampingFraction: 0.72),
            value: isHovered
        )
        .accessibilityLabel("닫기")
        .help("닫기")
    }
}

private struct AnimatedProfileCloseButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? CharacterFullBodyProfileCloseButtonMetrics.pressedScale
                    : 1
            )
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(
                .spring(response: 0.22, dampingFraction: 0.58),
                value: configuration.isPressed
            )
    }
}

private struct CharacterFullBodyProfileVideo: NSViewRepresentable {
    let url: URL
    let onLoopCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoopCompleted: onLoopCompleted)
    }

    func makeNSView(context: Context) -> PlayerLayerView {
        let player = AVPlayer(url: url)
        player.isMuted = true

        let view = PlayerLayerView(player: player)
        view.setAccessibilityLabel("직원 전신 프로필 동영상")
        context.coordinator.startLooping(player)
        player.play()
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        context.coordinator.onLoopCompleted = onLoopCompleted
    }

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stopLooping()
        nsView.player.pause()
    }

    final class Coordinator {
        var onLoopCompleted: () -> Void
        private var endObserver: NSObjectProtocol?

        init(onLoopCompleted: @escaping () -> Void) {
            self.onLoopCompleted = onLoopCompleted
        }

        func startLooping(_ player: AVPlayer) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self, weak player] _ in
                self?.onLoopCompleted()
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

@MainActor
private enum CharacterFullBodyProfileImageCache {
    private static let images: [OfficeCharacter: NSImage] = Dictionary(
        uniqueKeysWithValues: OfficeCharacter.allCases.compactMap { character in
            guard
                let url = PixelOfficeAsset.fullBodyProfileURL(for: character),
                let image = NSImage(contentsOf: url)
            else {
                return nil
            }
            return (character, image)
        }
    )

    static func image(for character: OfficeCharacter) -> NSImage? {
        images[character]
    }
}
