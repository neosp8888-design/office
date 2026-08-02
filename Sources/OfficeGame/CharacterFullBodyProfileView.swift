// 이 파일은 선택한 직원의 전신 프로필을 별도 시트로 표시한다.

import AppKit
import OfficeCore
import SwiftUI

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
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 22, weight: .bold))
                    Text(OfficeLocalization.string(character.seat))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

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
                    .frame(maxHeight: 520)
                    .frame(maxWidth: .infinity)
                    .background(
                        Color(red: 0.985, green: 0.96, blue: 0.94),
                        in: RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )
            }
        }
        .padding(22)
        .frame(width: 430)
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
