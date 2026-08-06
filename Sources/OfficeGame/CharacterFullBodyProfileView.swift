// 이 파일은 선택한 직원의 전신 프로필을 별도 시트로 표시한다.

import AppKit
import AVFoundation
import OfficeCore
import SwiftUI

enum CharacterFullBodyProfileLayout {
    static let referenceContentWidth: CGFloat = 386
    static let horizontalPadding: CGFloat = 16
    static let imageWidthRatio: CGFloat = 0.5
    static let imageAspectRatio: CGFloat = 0.5

    static let imageWidth = referenceContentWidth * imageWidthRatio

    static var imageHeight: CGFloat {
        imageWidth / imageAspectRatio
    }

    static var sheetWidth: CGFloat {
        imageWidth + (horizontalPadding * 2)
    }
}

enum CharacterFullBodyProfileSelection {
    static let dragThreshold: CGFloat = 36

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
    @State private var selectedVideoIndex = 0

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

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                Text(name)
                    .font(.system(size: 22, weight: .bold))

                Spacer()

                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if let selectedVideoURL {
                ZStack {
                    CharacterFullBodyProfileVideo(url: selectedVideoURL)
                        .id(selectedVideoURL)

                    if videoURLs.count > 1 {
                        profileNavigationControls
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
    }

    private var profileNavigationControls: some View {
        HStack {
            profileNavigationButton(
                systemName: "chevron.left",
                accessibilityLabel: "이전 프로필"
            ) {
                selectVideo(
                    CharacterFullBodyProfileSelection.previousIndex(
                        from: selectedVideoIndex,
                        count: videoURLs.count
                    )
                )
            }

            Spacer()

            profileNavigationButton(
                systemName: "chevron.right",
                accessibilityLabel: "다음 프로필"
            ) {
                selectVideo(
                    CharacterFullBodyProfileSelection.nextIndex(
                        from: selectedVideoIndex,
                        count: videoURLs.count
                    )
                )
            }
        }
        .padding(.horizontal, 8)
    }

    private func profileNavigationButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.58), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func selectVideo(_ index: Int) {
        guard index != selectedVideoIndex else {
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedVideoIndex = index
        }
    }
}

private struct CharacterFullBodyProfileVideo: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {}

    static func dismantleNSView(_ nsView: PlayerLayerView, coordinator: Coordinator) {
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
