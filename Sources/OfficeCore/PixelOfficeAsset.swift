// 이 파일은 V4 오피스의 네 가지 테마와 번들 이미지를 안전하게 제공한다.

import AppKit

public enum OfficeTheme: String, CaseIterable, Identifiable, Sendable {
    case modernDay
    case modernNight
    case woodDay
    case woodNight

    public var id: String {
        rawValue
    }

    public var filename: String {
        switch self {
        case .modernDay:
            "office-theme-modern-day-v4"
        case .modernNight:
            "office-theme-modern-night-v4"
        case .woodDay:
            "office-theme-wood-day-v4"
        case .woodNight:
            "office-theme-wood-night-v4"
        }
    }

    public var title: String {
        switch self {
        case .modernDay:
            "모던 낮"
        case .modernNight:
            "모던 밤"
        case .woodDay:
            "우드 낮"
        case .woodNight:
            "우드 밤"
        }
    }

    public var materialTitle: String {
        switch self {
        case .modernDay, .modernNight:
            "모던"
        case .woodDay, .woodNight:
            "우드"
        }
    }

    public var isNight: Bool {
        switch self {
        case .modernNight, .woodNight:
            true
        case .modernDay, .woodDay:
            false
        }
    }

    public var edgeBackdropColors: [NSColor] {
        switch self {
        case .modernDay:
            [
                NSColor(
                    srgbRed: 0.941,
                    green: 0.864,
                    blue: 0.827,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.934,
                    green: 0.854,
                    blue: 0.817,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.918,
                    green: 0.837,
                    blue: 0.801,
                    alpha: 1
                )
            ]
        case .modernNight:
            [
                NSColor(
                    srgbRed: 0.183,
                    green: 0.227,
                    blue: 0.313,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.227,
                    green: 0.257,
                    blue: 0.337,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.224,
                    green: 0.247,
                    blue: 0.324,
                    alpha: 1
                )
            ]
        case .woodDay:
            [
                NSColor(
                    srgbRed: 0.951,
                    green: 0.894,
                    blue: 0.861,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.949,
                    green: 0.897,
                    blue: 0.864,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.948,
                    green: 0.895,
                    blue: 0.864,
                    alpha: 1
                )
            ]
        case .woodNight:
            [
                NSColor(
                    srgbRed: 0.523,
                    green: 0.555,
                    blue: 0.643,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.523,
                    green: 0.556,
                    blue: 0.646,
                    alpha: 1
                ),
                NSColor(
                    srgbRed: 0.522,
                    green: 0.555,
                    blue: 0.644,
                    alpha: 1
                )
            ]
        }
    }

    public var edgeBackdropColor: NSColor {
        edgeBackdropColors[1]
    }
}

public enum OfficeCharacter:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    case boss
    case leftMan = "left-man"
    case leftWoman = "left-woman"
    case rightWoman = "right-woman"
    case rightMan = "right-man"

    public var id: String {
        rawValue
    }
}

public enum OfficeCharacterMotionKind: String, CaseIterable, Hashable, Sendable {
    case blink
    case mouth
    case typing
}

public enum PixelOfficeAsset {
    public static let renderedV4 = loadResource(
        named: "office-background-3d-v4"
    )

    public static func resourceURL(for theme: OfficeTheme) -> URL {
        guard let url = Bundle.module.url(
            forResource: theme.filename,
            withExtension: "png"
        ) else {
            fatalError("\(theme.filename).png 리소스를 찾을 수 없습니다.")
        }
        return url
    }

    public static func avatarURL(for character: OfficeCharacter) -> URL? {
        Bundle.module.url(
            forResource: "avatar-\(character.rawValue)",
            withExtension: "png",
            subdirectory: "avatars"
        )
    }

    public static func image(for theme: OfficeTheme) -> NSImage {
        switch theme {
        case .modernDay:
            modernDay
        case .modernNight:
            modernNight
        case .woodDay:
            woodDay
        case .woodNight:
            woodNight
        }
    }

    public static func motionResourceURL(
        for character: OfficeCharacter,
        kind: OfficeCharacterMotionKind,
        theme: OfficeTheme
    ) -> URL {
        let filename = "\(character.rawValue)-\(kind.rawValue)"
        let subdirectory = "office-3d-motion-v1/\(theme.rawValue)"
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "png",
            subdirectory: subdirectory
        ) else {
            fatalError(
                "\(subdirectory)/\(filename).png 리소스를 찾을 수 없습니다."
            )
        }
        return url
    }

    public static func motionImage(
        for character: OfficeCharacter,
        kind: OfficeCharacterMotionKind,
        theme: OfficeTheme
    ) -> NSImage {
        guard let image = NSImage(
            contentsOf: motionResourceURL(
                for: character,
                kind: kind,
                theme: theme
            )
        ) else {
            fatalError(
                "\(character.rawValue)-\(kind.rawValue).png 이미지를 불러오지 못했습니다."
            )
        }
        return image
    }

    private static let modernDay = load(.modernDay)
    private static let modernNight = load(.modernNight)
    private static let woodDay = load(.woodDay)
    private static let woodNight = load(.woodNight)

    private static func load(_ theme: OfficeTheme) -> NSImage {
        loadResource(named: theme.filename)
    }

    private static func loadResource(
        named filename: String
    ) -> NSImage {
        guard let url = Bundle.module.url(
            forResource: filename,
            withExtension: "png"
        ) else {
            fatalError("\(filename).png 리소스를 찾을 수 없습니다.")
        }
        guard let image = NSImage(contentsOf: url) else {
            fatalError("\(filename).png 이미지를 불러오지 못했습니다.")
        }
        return image
    }
}
