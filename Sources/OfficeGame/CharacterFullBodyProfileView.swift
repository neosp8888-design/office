// 이 파일은 선택한 직원의 전신 프로필을 별도 시트로 표시한다.

import AppKit
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

struct CharacterFullBodyProfileView: View {
    let character: CharacterConfiguration
    let name: String

    @Environment(\.dismiss) private var dismiss

    private var image: NSImage? {
        CharacterFullBodyProfileImageCache.image(for: character.id)
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

            if let image {
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
