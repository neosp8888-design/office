// 이 파일은 여성 보스의 애니메이션 프레임과 테마별 가림 이미지를 제공한다.

import AppKit

public enum BossCharacterFrame: String, CaseIterable, Sendable {
    case workA
    case workB
    case workBlink
    case speakA
    case speakB
    case speakBlink

    fileprivate var filename: String {
        switch self {
        case .workA:
            "boss-female-work-a-v2"
        case .workB:
            "boss-female-work-b-v2"
        case .workBlink:
            "boss-female-work-blink-v2"
        case .speakA:
            "boss-female-speak-a-v2"
        case .speakB:
            "boss-female-speak-b-v2"
        case .speakBlink:
            "boss-female-speak-blink-v2"
        }
    }
}

public enum BossCharacterAsset {
    public static func image(for frame: BossCharacterFrame) -> NSImage {
        frames[frame]!
    }

    public static func foregroundImage(for theme: OfficeTheme) -> NSImage {
        foregrounds[theme]!
    }

    private static let frames = Dictionary(
        uniqueKeysWithValues: BossCharacterFrame.allCases.map {
            ($0, load($0.filename))
        }
    )

    private static let foregrounds = Dictionary(
        uniqueKeysWithValues: OfficeTheme.allCases.map {
            ($0, load("boss-foreground-\($0.assetSlug)-v1"))
        }
    )

    private static func load(_ filename: String) -> NSImage {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "png"
        ),
        let image = NSImage(contentsOf: url) else {
            fatalError("\(filename).png 이미지를 불러오지 못했습니다.")
        }
        return image
    }
}

private extension OfficeTheme {
    var assetSlug: String {
        switch self {
        case .modernDay:
            "modern-day"
        case .modernNight:
            "modern-night"
        case .woodDay:
            "wood-day"
        case .woodNight:
            "wood-night"
        }
    }
}
