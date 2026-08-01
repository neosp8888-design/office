// 이 파일은 V4 배경 위의 환경 효과를 SpriteKit 게임 루프로 실시간 갱신한다.

import AppKit
import OfficeCore
import SpriteKit
import SwiftUI

enum BossActivity: Equatable, Sendable {
    case working
    case speaking
}

struct OfficeRealtimeView: NSViewRepresentable {
    let theme: OfficeTheme
    let style: OfficeArtStyle
    let isActive: Bool
    let reduceMotion: Bool
    let bossActivity: BossActivity

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SKView {
        let view = PassiveSKView()
        view.allowsTransparency = false
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 10

        context.coordinator.scene.apply(
            theme: theme,
            style: style,
            reduceMotion: reduceMotion,
            bossActivity: bossActivity
        )
        view.presentScene(context.coordinator.scene)
        view.isPaused = !isActive
        return view
    }

    func updateNSView(_ view: SKView, context: Context) {
        context.coordinator.scene.apply(
            theme: theme,
            style: style,
            reduceMotion: reduceMotion,
            bossActivity: bossActivity
        )
        view.preferredFramesPerSecond = 10
        view.isPaused = !isActive
    }

    static func dismantleNSView(_ view: SKView, coordinator: Coordinator) {
        view.isPaused = true
        view.presentScene(nil)
    }

    final class Coordinator {
        let scene = OfficeRealtimeScene()
    }
}

private final class PassiveSKView: SKView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class OfficeRealtimeScene: SKScene {
    private struct MotionKey: Hashable {
        let character: OfficeCharacter
        let kind: OfficeCharacterMotionKind
    }

    private struct CharacterMotionSpec {
        let character: OfficeCharacter
        let blinkRect: CGRect
        let mouthRect: CGRect
        let typingRect: CGRect
        let phase: TimeInterval

        func rect(for kind: OfficeCharacterMotionKind) -> CGRect {
            switch kind {
            case .blink:
                blinkRect
            case .mouth:
                mouthRect
            case .typing:
                typingRect
            }
        }
    }

    private struct WindowLight {
        let shade: SKSpriteNode
        let halo: SKSpriteNode
        let core: SKSpriteNode
    }

    private struct RooftopBeacon {
        let halo: SKSpriteNode
        let core: SKSpriteNode
    }

    private let contentRoot = SKNode()
    private let themeArtworkRoot = SKNode()
    private let letterboxNode = SKSpriteNode()
    private let backgroundNode = SKSpriteNode()
    private let windowLightRoot = SKNode()
    private let rooftopBeaconRoot = SKNode()
    private let monitorGlowRoot = SKNode()
    private let stageGlowWide = SKShapeNode()
    private let stageGlowCore = SKShapeNode()
    private let analogClockDial = SKNode()
    private let analogClockFaceCover = SKShapeNode()
    private let analogClockTicks = SKShapeNode()
    private let analogClockHourHand = SKShapeNode()
    private let analogClockMinuteHand = SKShapeNode()
    private let analogClockSecondHand = SKShapeNode()
    private let analogClockHub = SKShapeNode()
    private let bossCropNode = SKCropNode()
    private let bossCharacter = SKSpriteNode()
    private let bossForeground = SKSpriteNode()
    private var windowLights: [WindowLight] = []
    private var rooftopBeacons: [RooftopBeacon] = []
    private var monitorGlows: [SKShapeNode] = []
    private var bossTextures: [BossCharacterFrame: SKTexture] = [:]
    private var currentTheme: OfficeTheme?
    private var currentStyle: OfficeArtStyle?
    private var currentBossActivity: BossActivity?
    private var currentBossReduceMotion: Bool?
    private var currentCharacterReduceMotion: Bool?
    private var reduceMotion = false
    private var lastClockSecond = -1
    private var motionNodes: [MotionKey: SKSpriteNode] = [:]

    private let threeDCharacterMotionSpecs = [
        CharacterMotionSpec(
            character: .boss,
            blinkRect: CGRect(x: 744, y: 202, width: 62, height: 37),
            mouthRect: CGRect(x: 754, y: 229, width: 39, height: 27),
            typingRect: CGRect(x: 738, y: 269, width: 48, height: 42),
            phase: 0.2
        ),
        CharacterMotionSpec(
            character: .leftMan,
            blinkRect: CGRect(x: 323, y: 524, width: 58, height: 42),
            mouthRect: CGRect(x: 338, y: 558, width: 32, height: 24),
            typingRect: CGRect(x: 316, y: 579, width: 94, height: 76),
            phase: 0.7
        ),
        CharacterMotionSpec(
            character: .leftWoman,
            blinkRect: CGRect(x: 480, y: 478, width: 51, height: 36),
            mouthRect: CGRect(x: 487, y: 507, width: 38, height: 26),
            typingRect: CGRect(x: 468, y: 538, width: 59, height: 47),
            phase: 1.1
        ),
        CharacterMotionSpec(
            character: .rightWoman,
            blinkRect: CGRect(x: 1_085, y: 481, width: 58, height: 39),
            mouthRect: CGRect(x: 1_097, y: 510, width: 37, height: 28),
            typingRect: CGRect(x: 1_084, y: 558, width: 62, height: 50),
            phase: 1.6
        ),
        CharacterMotionSpec(
            character: .rightMan,
            blinkRect: CGRect(x: 1_205, y: 557, width: 64, height: 43),
            mouthRect: CGRect(x: 1_218, y: 588, width: 41, height: 30),
            typingRect: CGRect(x: 1_205, y: 626, width: 75, height: 55),
            phase: 2.0
        )
    ]

    private let twoDCharacterMotionSpecs = [
        CharacterMotionSpec(
            character: .boss,
            blinkRect: CGRect(x: 749, y: 190, width: 77, height: 42),
            mouthRect: CGRect(x: 779, y: 218, width: 26, height: 20),
            typingRect: CGRect(x: 758, y: 267, width: 43, height: 34),
            phase: 0.2
        ),
        CharacterMotionSpec(
            character: .leftMan,
            blinkRect: CGRect(x: 320, y: 524, width: 91, height: 55),
            mouthRect: CGRect(x: 344, y: 558, width: 25, height: 22),
            typingRect: CGRect(x: 329, y: 628, width: 53, height: 46),
            phase: 0.7
        ),
        CharacterMotionSpec(
            character: .leftWoman,
            blinkRect: CGRect(x: 484, y: 467, width: 84, height: 51),
            mouthRect: CGRect(x: 504, y: 486, width: 31, height: 28),
            typingRect: CGRect(x: 493, y: 550, width: 65, height: 42),
            phase: 1.1
        ),
        CharacterMotionSpec(
            character: .rightWoman,
            blinkRect: CGRect(x: 1_087, y: 460, width: 86, height: 51),
            mouthRect: CGRect(x: 1_106, y: 486, width: 29, height: 28),
            typingRect: CGRect(x: 1_099, y: 548, width: 66, height: 41),
            phase: 1.6
        ),
        CharacterMotionSpec(
            character: .rightMan,
            blinkRect: CGRect(x: 1_215, y: 540, width: 88, height: 54),
            mouthRect: CGRect(x: 1_227, y: 581, width: 30, height: 29),
            typingRect: CGRect(x: 1_232, y: 660, width: 59, height: 41),
            phase: 2.0
        )
    ]

    override init() {
        super.init(size: OfficeCanvasGeometry.designSize)
        scaleMode = .resizeFill
        backgroundColor = .black
        configureLetterbox()
        addChild(contentRoot)
        contentRoot.addChild(themeArtworkRoot)
        configureBackground()
        configureCharacterMotions()
        configureWindowLights()
        configureRooftopBeacons()
        configureMonitorGlows()
        configureStageGlow()
        configureAnalogClock()
        windowLightRoot.isHidden = true
        rooftopBeaconRoot.isHidden = true
        monitorGlowRoot.isHidden = true
        stageGlowWide.isHidden = true
        stageGlowCore.isHidden = true
        layoutContent()
    }

    @available(*, unavailable)
    required init?(coder decoder: NSCoder) {
        fatalError("OfficeRealtimeScene은 코드로만 생성합니다.")
    }

    func apply(
        theme: OfficeTheme,
        style: OfficeArtStyle,
        reduceMotion: Bool,
        bossActivity: BossActivity
    ) {
        self.reduceMotion = reduceMotion
        applyCharacterMotion(reduceMotion: reduceMotion)
        applyBossMotion(
            activity: bossActivity,
            reduceMotion: reduceMotion
        )

        guard currentTheme != theme || currentStyle != style else {
            return
        }

        currentTheme = theme
        currentStyle = style
        backgroundColor = edgeBackdropColors(
            for: theme,
            style: style
        )[1]
        letterboxNode.texture = letterboxTexture(
            for: theme,
            style: style
        )
        let texture = SKTexture(
            image: PixelOfficeAsset.image(
                for: theme,
                style: style
            )
        )
        texture.filteringMode = .linear
        backgroundNode.texture = texture
        applyCharacterMotionGeometry(style: style)
        applyCharacterMotionTextures(
            theme: theme,
            style: style
        )
        applyEnvironmentGeometry(style: style)
        themeArtworkRoot.position = CGPoint(
            x: 0,
            y: artworkVerticalOffset(
                for: theme,
                style: style
            )
        )

        let nightEffectsEnabled = theme == .modernNight
        windowLightRoot.isHidden = !nightEffectsEnabled
        rooftopBeaconRoot.isHidden = !nightEffectsEnabled
        monitorGlowRoot.isHidden = !nightEffectsEnabled
        stageGlowWide.isHidden = !nightEffectsEnabled
        stageGlowCore.isHidden = !nightEffectsEnabled
        let stageColor = stageLightColor(for: theme)
        stageGlowWide.strokeColor = stageColor
        stageGlowCore.strokeColor = stageColor
        applyAnalogClockStyle(
            theme: theme,
            style: style
        )

        bossCropNode.isHidden = true
        bossForeground.isHidden = true
    }

    override func didChangeSize(_ oldSize: CGSize) {
        layoutContent()
    }

    override func update(_ currentTime: TimeInterval) {
        guard let theme = currentTheme else {
            return
        }

        let now = Date()
        let phase = OfficeAnimationPhase(
            date: now,
            reduceMotion: reduceMotion
        )
        if theme == .modernNight {
            updateStageGlow(phase: phase)
            updateWindowLights(phase: phase)
            updateRooftopBeacons(phase: phase)
            updateMonitorGlows(phase: phase)
        }

        if phase.clockSecond != lastClockSecond {
            lastClockSecond = phase.clockSecond
            updateAnalogClock(date: now)
        }
    }

    private func configureBackground() {
        backgroundNode.anchorPoint = .zero
        backgroundNode.position = .zero
        backgroundNode.size = size
        backgroundNode.zPosition = 0
        themeArtworkRoot.addChild(backgroundNode)
    }

    private func configureLetterbox() {
        letterboxNode.anchorPoint = .zero
        letterboxNode.position = .zero
        letterboxNode.zPosition = -100
        addChild(letterboxNode)
    }

    private func letterboxTexture(
        for theme: OfficeTheme,
        style: OfficeArtStyle
    ) -> SKTexture {
        let image = NSImage(
            size: CGSize(width: 2, height: 256),
            flipped: false
        ) { rect in
            guard let gradient = NSGradient(
                colors: self.edgeBackdropColors(
                    for: theme,
                    style: style
                )
            ) else {
                return false
            }
            gradient.draw(in: rect, angle: -90)
            return true
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    private func edgeBackdropColors(
        for theme: OfficeTheme,
        style: OfficeArtStyle
    ) -> [NSColor] {
        guard style == .twoD else {
            return theme.edgeBackdropColors
        }

        let samples: [(CGFloat, CGFloat, CGFloat)]
        if theme.isNight {
            samples = [
                (56, 51, 50),
                (72, 62, 57),
                (60, 54, 52)
            ]
        } else {
            samples = [
                (239, 219, 205),
                (240, 220, 204),
                (238, 218, 202)
            ]
        }
        return samples.map { sample in
            NSColor(
                srgbRed: sample.0 / 255,
                green: sample.1 / 255,
                blue: sample.2 / 255,
                alpha: 1
            )
        }
    }

    private func configureCharacterMotions() {
        for spec in threeDCharacterMotionSpecs {
            for kind in OfficeCharacterMotionKind.allCases {
                let key = MotionKey(character: spec.character, kind: kind)
                let rect = spec.rect(for: kind)
                let node = SKSpriteNode()
                node.anchorPoint = .zero
                node.position = CGPoint(
                    x: rect.minX,
                    y: OfficeCanvasGeometry.designSize.height - rect.maxY
                )
                node.size = rect.size
                node.alpha = 0
                node.zPosition = 60 + zOffset(for: kind)
                themeArtworkRoot.addChild(node)
                motionNodes[key] = node
            }
        }
    }

    private func applyCharacterMotionGeometry(style: OfficeArtStyle) {
        for spec in characterMotionSpecs(for: style) {
            for kind in OfficeCharacterMotionKind.allCases {
                let key = MotionKey(character: spec.character, kind: kind)
                let rect = spec.rect(for: kind)
                guard let node = motionNodes[key] else {
                    continue
                }
                node.position = CGPoint(
                    x: rect.minX,
                    y: OfficeCanvasGeometry.designSize.height - rect.maxY
                )
                node.size = rect.size
            }
        }
    }

    private func applyCharacterMotionTextures(
        theme: OfficeTheme,
        style: OfficeArtStyle
    ) {
        for key in motionNodes.keys {
            let texture = SKTexture(
                image: PixelOfficeAsset.motionImage(
                    for: key.character,
                    kind: key.kind,
                    theme: theme,
                    style: style
                )
            )
            texture.filteringMode = .linear
            motionNodes[key]?.texture = texture
        }
    }

    private func applyCharacterMotion(reduceMotion: Bool) {
        guard currentCharacterReduceMotion != reduceMotion else {
            return
        }
        currentCharacterReduceMotion = reduceMotion

        for spec in threeDCharacterMotionSpecs {
            for kind in OfficeCharacterMotionKind.allCases {
                let key = MotionKey(character: spec.character, kind: kind)
                guard let node = motionNodes[key] else {
                    continue
                }
                node.removeAction(forKey: "character-motion")
                node.alpha = 0
                guard !reduceMotion else {
                    continue
                }

                let action: SKAction
                switch kind {
                case .blink:
                    action = blinkAction(phase: spec.phase)
                case .mouth:
                    action = mouthAction(phase: spec.phase)
                case .typing:
                    action = typingAction(phase: spec.phase)
                }
                node.run(action, withKey: "character-motion")
            }
        }
    }

    private func characterMotionSpecs(
        for style: OfficeArtStyle
    ) -> [CharacterMotionSpec] {
        switch style {
        case .twoD:
            twoDCharacterMotionSpecs
        case .threeD:
            threeDCharacterMotionSpecs
        }
    }

    private func blinkAction(phase: TimeInterval) -> SKAction {
        let blink = SKAction.sequence([
            .fadeAlpha(to: 1, duration: 0.025),
            .wait(forDuration: 0.085),
            .fadeAlpha(to: 0, duration: 0.025)
        ])
        return .sequence([
            .wait(forDuration: 0.8 + phase),
            .repeatForever(
                .sequence([
                    .wait(
                        forDuration: 3.4 + phase * 0.35,
                        withRange: 2.4
                    ),
                    blink
                ])
            )
        ])
    }

    private func mouthAction(phase: TimeInterval) -> SKAction {
        let syllable = SKAction.sequence([
            .fadeAlpha(to: 1, duration: 0.035),
            .wait(forDuration: 0.18 + phase * 0.008),
            .fadeAlpha(to: 0, duration: 0.035),
            .wait(forDuration: 0.09)
        ])
        let phrase = SKAction.repeat(
            syllable,
            count: 3 + Int((phase * 1.5).rounded())
        )
        return .sequence([
            .wait(forDuration: 1.0 + phase * 0.45),
            .repeatForever(
                .sequence([
                    .wait(
                        forDuration: 3.0 + phase * 0.25,
                        withRange: 2.0
                    ),
                    phrase
                ])
            )
        ])
    }

    private func typingAction(phase: TimeInterval) -> SKAction {
        let keyPress = SKAction.sequence([
            .fadeAlpha(to: 1, duration: 0.035),
            .wait(forDuration: 0.12 + phase * 0.008),
            .fadeAlpha(to: 0, duration: 0.035),
            .wait(forDuration: 0.11)
        ])
        let burst = SKAction.repeat(
            keyPress,
            count: 6 + Int(phase * 2)
        )
        return .sequence([
            .wait(forDuration: 0.4 + phase * 0.55),
            .repeatForever(
                .sequence([
                    burst,
                    .wait(
                        forDuration: 1.0 + phase * 0.28,
                        withRange: 1.4
                    )
                ])
            )
        ])
    }

    private func zOffset(
        for kind: OfficeCharacterMotionKind
    ) -> CGFloat {
        switch kind {
        case .blink:
            0
        case .mouth:
            1
        case .typing:
            2
        }
    }

    private func configureWindowLights() {
        let positions = [
            CGPoint(x: 508, y: 721),
            CGPoint(x: 497, y: 714),
            CGPoint(x: 487, y: 704),
            CGPoint(x: 476, y: 697),
            CGPoint(x: 476, y: 689),
            CGPoint(x: 443, y: 683),
            CGPoint(x: 449, y: 673),
            CGPoint(x: 443, y: 665),
            CGPoint(x: 432, y: 661),
            CGPoint(x: 390, y: 653),
            CGPoint(x: 373, y: 628)
        ]
        let sizes: [CGFloat] = [4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 4]
        let warmLight = NSColor(
            calibratedRed: 1.00,
            green: 0.72,
            blue: 0.20,
            alpha: 1
        )
        let nightShade = NSColor(
            calibratedRed: 0.025,
            green: 0.075,
            blue: 0.17,
            alpha: 1
        )

        windowLightRoot.zPosition = 20
        contentRoot.addChild(windowLightRoot)

        for (index, position) in positions.enumerated() {
            let size = sizes[index]
            let shade = SKSpriteNode(
                color: nightShade,
                size: CGSize(width: size + 3, height: size + 3)
            )
            let halo = SKSpriteNode(
                color: warmLight,
                size: CGSize(width: size * 3, height: size * 3)
            )
            let core = SKSpriteNode(
                color: warmLight,
                size: CGSize(width: size, height: size)
            )

            shade.position = position
            halo.position = position
            core.position = position
            shade.zPosition = 0
            halo.zPosition = 1
            core.zPosition = 2
            halo.blendMode = .add
            core.blendMode = .add

            windowLightRoot.addChild(shade)
            windowLightRoot.addChild(halo)
            windowLightRoot.addChild(core)
            windowLights.append(
                WindowLight(shade: shade, halo: halo, core: core)
            )
        }
    }

    private func configureRooftopBeacons() {
        let positions = [
            CGPoint(x: 507, y: 737),
            CGPoint(x: 478, y: 707),
            CGPoint(x: 449, y: 693)
        ]
        let beaconLight = NSColor(
            calibratedRed: 1.00,
            green: 1.00,
            blue: 0.96,
            alpha: 1
        )

        rooftopBeaconRoot.zPosition = 21
        contentRoot.addChild(rooftopBeaconRoot)

        for position in positions {
            let halo = SKSpriteNode(
                color: beaconLight,
                size: CGSize(width: 7, height: 7)
            )
            let core = SKSpriteNode(
                color: beaconLight,
                size: CGSize(width: 2, height: 2)
            )

            halo.position = position
            core.position = position
            halo.zPosition = 0
            core.zPosition = 1
            halo.blendMode = .add
            core.blendMode = .add

            rooftopBeaconRoot.addChild(halo)
            rooftopBeaconRoot.addChild(core)
            rooftopBeacons.append(RooftopBeacon(halo: halo, core: core))
        }
    }

    private func configureStageGlow() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 560, y: 606))
        path.addLine(to: CGPoint(x: 677, y: 548))
        path.addLine(to: CGPoint(x: 909, y: 548))
        path.addLine(to: CGPoint(x: 1_004, y: 595))

        stageGlowWide.path = path
        stageGlowWide.lineWidth = 10
        stageGlowWide.glowWidth = 4
        stageGlowWide.lineCap = .butt
        stageGlowWide.lineJoin = .miter
        stageGlowWide.blendMode = .add
        stageGlowWide.zPosition = 10

        stageGlowCore.path = path
        stageGlowCore.lineWidth = 2
        stageGlowCore.glowWidth = 1
        stageGlowCore.lineCap = .butt
        stageGlowCore.lineJoin = .miter
        stageGlowCore.blendMode = .add
        stageGlowCore.zPosition = 11

        contentRoot.addChild(stageGlowWide)
        contentRoot.addChild(stageGlowCore)
    }

    private func configureMonitorGlows() {
        let positions = [
            CGPoint(x: 816, y: 700),
            CGPoint(x: 548, y: 448),
            CGPoint(x: 406, y: 370),
            CGPoint(x: 1_058, y: 444),
            CGPoint(x: 1_195, y: 356)
        ]
        let cyan = NSColor(
            calibratedRed: 0.48,
            green: 0.90,
            blue: 1.00,
            alpha: 1
        )

        monitorGlowRoot.zPosition = 16
        contentRoot.addChild(monitorGlowRoot)

        for position in positions {
            let glow = SKShapeNode(
                ellipseOf: CGSize(width: 112, height: 44)
            )
            glow.position = position
            glow.fillColor = cyan
            glow.strokeColor = .clear
            glow.glowWidth = 18
            glow.blendMode = .add
            glow.alpha = 0.02
            monitorGlowRoot.addChild(glow)
            monitorGlows.append(glow)
        }
    }

    private func applyEnvironmentGeometry(style: OfficeArtStyle) {
        let windowGeometry = windowLightGeometry(for: style)
        for (index, light) in windowLights.enumerated() {
            guard index < windowGeometry.positions.count,
                  index < windowGeometry.sizes.count else {
                light.shade.isHidden = true
                light.halo.isHidden = true
                light.core.isHidden = true
                continue
            }
            let position = windowGeometry.positions[index]
            let lightSize = windowGeometry.sizes[index]
            light.shade.isHidden = false
            light.halo.isHidden = false
            light.core.isHidden = false
            light.shade.position = position
            light.halo.position = position
            light.core.position = position
            light.shade.size = CGSize(
                width: lightSize + 3,
                height: lightSize + 3
            )
            light.halo.size = CGSize(
                width: lightSize * 3,
                height: lightSize * 3
            )
            light.core.size = CGSize(
                width: lightSize,
                height: lightSize
            )
        }

        let beaconPositions = rooftopBeaconPositions(for: style)
        for (index, beacon) in rooftopBeacons.enumerated() {
            guard index < beaconPositions.count else {
                beacon.halo.isHidden = true
                beacon.core.isHidden = true
                continue
            }
            let position = beaconPositions[index]
            beacon.halo.isHidden = false
            beacon.core.isHidden = false
            beacon.halo.position = position
            beacon.core.position = position
        }

        let monitorGeometry = monitorGlowGeometry(for: style)
        for (index, glow) in monitorGlows.enumerated() {
            guard index < monitorGeometry.positions.count else {
                glow.isHidden = true
                continue
            }
            glow.isHidden = false
            glow.position = monitorGeometry.positions[index]
            glow.path = CGPath(
                ellipseIn: CGRect(
                    x: -monitorGeometry.size.width / 2,
                    y: -monitorGeometry.size.height / 2,
                    width: monitorGeometry.size.width,
                    height: monitorGeometry.size.height
                ),
                transform: nil
            )
            glow.glowWidth = monitorGeometry.glowWidth
        }

        let stagePath = stageGlowPath(for: style)
        stageGlowWide.path = stagePath
        stageGlowCore.path = stagePath
    }

    private func windowLightGeometry(
        for style: OfficeArtStyle
    ) -> (positions: [CGPoint], sizes: [CGFloat]) {
        switch style {
        case .threeD:
            (
                [
                    CGPoint(x: 508, y: 721),
                    CGPoint(x: 497, y: 714),
                    CGPoint(x: 487, y: 704),
                    CGPoint(x: 476, y: 697),
                    CGPoint(x: 476, y: 689),
                    CGPoint(x: 443, y: 683),
                    CGPoint(x: 449, y: 673),
                    CGPoint(x: 443, y: 665),
                    CGPoint(x: 432, y: 661),
                    CGPoint(x: 390, y: 653),
                    CGPoint(x: 373, y: 628)
                ],
                [4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 4]
            )
        case .twoD:
            (
                [
                    CGPoint(x: 501, y: 726),
                    CGPoint(x: 514, y: 722),
                    CGPoint(x: 527, y: 718),
                    CGPoint(x: 504, y: 697),
                    CGPoint(x: 520, y: 692),
                    CGPoint(x: 438, y: 693),
                    CGPoint(x: 452, y: 689),
                    CGPoint(x: 465, y: 681),
                    CGPoint(x: 442, y: 659),
                    CGPoint(x: 387, y: 658),
                    CGPoint(x: 400, y: 655)
                ],
                [4, 5, 4, 4, 5, 4, 4, 5, 4, 5, 4]
            )
        }
    }

    private func rooftopBeaconPositions(
        for style: OfficeArtStyle
    ) -> [CGPoint] {
        switch style {
        case .threeD:
            [
                CGPoint(x: 507, y: 737),
                CGPoint(x: 478, y: 707),
                CGPoint(x: 449, y: 693)
            ]
        case .twoD:
            [
                CGPoint(x: 399, y: 684),
                CGPoint(x: 466, y: 702),
                CGPoint(x: 525, y: 754)
            ]
        }
    }

    private func monitorGlowGeometry(
        for style: OfficeArtStyle
    ) -> (positions: [CGPoint], size: CGSize, glowWidth: CGFloat) {
        switch style {
        case .threeD:
            (
                [
                    CGPoint(x: 816, y: 700),
                    CGPoint(x: 548, y: 448),
                    CGPoint(x: 406, y: 370),
                    CGPoint(x: 1_058, y: 444),
                    CGPoint(x: 1_195, y: 356)
                ],
                CGSize(width: 112, height: 44),
                18
            )
        case .twoD:
            (
                [
                    CGPoint(x: 835, y: 740),
                    CGPoint(x: 558, y: 464),
                    CGPoint(x: 414, y: 373),
                    CGPoint(x: 1_061, y: 464),
                    CGPoint(x: 1_208, y: 353)
                ],
                CGSize(width: 96, height: 34),
                15
            )
        }
    }

    private func stageGlowPath(
        for style: OfficeArtStyle
    ) -> CGPath {
        let points: [CGPoint]
        switch style {
        case .threeD:
            points = [
                CGPoint(x: 560, y: 606),
                CGPoint(x: 677, y: 548),
                CGPoint(x: 909, y: 548),
                CGPoint(x: 1_004, y: 595)
            ]
        case .twoD:
            points = [
                CGPoint(x: 574, y: 610),
                CGPoint(x: 689, y: 548),
                CGPoint(x: 936, y: 548),
                CGPoint(x: 1_032, y: 604)
            ]
        }

        let path = CGMutablePath()
        guard let first = points.first else {
            return path
        }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func configureAnalogClock() {
        analogClockFaceCover.path = CGPath(
            ellipseIn: CGRect(x: -22.5, y: -22.5, width: 45, height: 45),
            transform: nil
        )
        analogClockFaceCover.strokeColor = .clear
        analogClockFaceCover.zPosition = 0

        let tickPath = CGMutablePath()
        for index in 0..<12 {
            let angle = CGFloat(index) / 12 * 2 * CGFloat.pi
            let innerRadius: CGFloat = index.isMultiple(of: 3) ? 14.5 : 17
            let outerRadius: CGFloat = 20
            tickPath.move(
                to: CGPoint(
                    x: sin(angle) * innerRadius,
                    y: cos(angle) * innerRadius
                )
            )
            tickPath.addLine(
                to: CGPoint(
                    x: sin(angle) * outerRadius,
                    y: cos(angle) * outerRadius
                )
            )
        }
        analogClockTicks.path = tickPath
        analogClockTicks.lineWidth = 1.7
        analogClockTicks.lineCap = .round
        analogClockTicks.zPosition = 0.5

        configureClockHand(
            analogClockHourHand,
            length: 12.5,
            tailLength: 2.5,
            lineWidth: 4.4,
            zPosition: 1
        )
        configureClockHand(
            analogClockMinuteHand,
            length: 19,
            tailLength: 3.0,
            lineWidth: 3.1,
            zPosition: 2
        )
        configureClockHand(
            analogClockSecondHand,
            length: 22,
            tailLength: 4.5,
            lineWidth: 1.6,
            zPosition: 3
        )

        analogClockHub.path = CGPath(
            ellipseIn: CGRect(x: -2.8, y: -2.8, width: 5.6, height: 5.6),
            transform: nil
        )
        analogClockHub.strokeColor = .clear
        analogClockHub.zPosition = 4

        analogClockDial.position = CGPoint(x: 1_191.5, y: 672)
        analogClockDial.xScale = 0.66
        analogClockDial.zPosition = 35
        analogClockDial.addChild(analogClockFaceCover)
        analogClockDial.addChild(analogClockTicks)
        analogClockDial.addChild(analogClockHourHand)
        analogClockDial.addChild(analogClockMinuteHand)
        analogClockDial.addChild(analogClockSecondHand)
        analogClockDial.addChild(analogClockHub)
        themeArtworkRoot.addChild(analogClockDial)
        updateAnalogClock(date: Date())
    }

    private func configureClockHand(
        _ hand: SKShapeNode,
        length: CGFloat,
        tailLength: CGFloat,
        lineWidth: CGFloat,
        zPosition: CGFloat
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -tailLength))
        path.addLine(to: CGPoint(x: 0, y: length))
        hand.path = path
        hand.lineWidth = lineWidth
        hand.lineCap = .round
        hand.zPosition = zPosition
    }

    private func applyAnalogClockStyle(
        theme: OfficeTheme,
        style: OfficeArtStyle
    ) {
        switch style {
        case .twoD:
            analogClockDial.isHidden = false
            analogClockTicks.isHidden = false
            analogClockDial.position = OfficeAnalogClockGeometry.twoDCenter
            analogClockDial.xScale =
                OfficeAnalogClockGeometry.twoDHorizontalScale
            analogClockDial.yScale =
                OfficeAnalogClockGeometry.twoDVerticalScale
            analogClockDial.zRotation =
                OfficeAnalogClockGeometry.twoDRotation
            analogClockFaceCover.fillColor = theme.isNight
                ? NSColor(
                    calibratedRed: 0.84,
                    green: 0.66,
                    blue: 0.49,
                    alpha: 1
                )
                : NSColor(
                    calibratedRed: 0.97,
                    green: 0.91,
                    blue: 0.85,
                    alpha: 1
                )
        case .threeD:
            analogClockTicks.isHidden = true
            analogClockDial.position.x = 1_191.5
            analogClockDial.xScale = 0.66
            analogClockDial.yScale = 1
            analogClockDial.zRotation = 0
            switch theme {
            case .modernDay:
                analogClockDial.isHidden = false
                analogClockDial.position.y = 665
                analogClockFaceCover.fillColor = NSColor(
                    calibratedRed: 0.92,
                    green: 0.90,
                    blue: 0.88,
                    alpha: 1
                )
            case .modernNight:
                analogClockDial.isHidden = false
                analogClockDial.position.y = 672
                analogClockFaceCover.fillColor = NSColor(
                    calibratedRed: 0.76,
                    green: 0.67,
                    blue: 0.60,
                    alpha: 1
                )
            }
        }

        let handColor = NSColor(
            calibratedRed: 0.08,
            green: 0.07,
            blue: 0.065,
            alpha: 1
        )
        analogClockHourHand.strokeColor = handColor
        analogClockMinuteHand.strokeColor = handColor
        analogClockTicks.strokeColor = handColor.withAlphaComponent(0.72)
        analogClockSecondHand.strokeColor = NSColor(
            calibratedRed: 0.78,
            green: 0.13,
            blue: 0.10,
            alpha: 1
        )
        analogClockHub.fillColor = handColor
    }

    private func updateAnalogClock(date: Date) {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute, .second],
            from: date
        )
        let hour = Double((components.hour ?? 0) % 12)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)

        analogClockHourHand.zRotation =
            -CGFloat((hour + minute / 60 + second / 3_600) / 12) * 2 * .pi
        analogClockMinuteHand.zRotation =
            -CGFloat((minute + second / 60) / 60) * 2 * .pi
        analogClockSecondHand.zRotation =
            -CGFloat(second / 60) * 2 * .pi
    }

    private func configureBossCharacter() {
        for frame in BossCharacterFrame.allCases {
            let texture = SKTexture(
                image: BossCharacterAsset.image(for: frame)
            )
            texture.filteringMode = .nearest
            bossTextures[frame] = texture
        }

        bossCharacter.texture = bossTextures[.workA]
        bossCharacter.anchorPoint = .zero
        bossCharacter.position = CGPoint(x: 705, y: 681)
        bossCharacter.size = CGSize(width: 128, height: 176)

        let visibleUpperBody = SKSpriteNode(
            color: .white,
            size: CGSize(width: 128, height: 113)
        )
        visibleUpperBody.anchorPoint = .zero
        visibleUpperBody.position = CGPoint(x: 705, y: 744)

        bossCropNode.maskNode = visibleUpperBody
        bossCropNode.zPosition = 30
        bossCropNode.addChild(bossCharacter)
        contentRoot.addChild(bossCropNode)

        bossForeground.anchorPoint = .zero
        bossForeground.position = CGPoint(x: 764, y: 676)
        bossForeground.size = CGSize(width: 104, height: 90)
        bossForeground.zPosition = 40
        contentRoot.addChild(bossForeground)
    }

    private func applyBossMotion(
        activity: BossActivity,
        reduceMotion: Bool
    ) {
        guard currentBossActivity != activity
                || currentBossReduceMotion != reduceMotion else {
            return
        }

        currentBossActivity = activity
        currentBossReduceMotion = reduceMotion
        let animationKey = "boss-motion"
        bossCharacter.removeAction(forKey: animationKey)

        if reduceMotion {
            bossCharacter.texture = bossTextures[
                activity == .working ? .workA : .speakA
            ]
            return
        }

        let loop: SKAction?
        switch activity {
        case .working:
            loop = bossWorkingLoop()
        case .speaking:
            loop = bossSpeakingLoop()
        }

        if let loop {
            bossCharacter.run(loop, withKey: animationKey)
        }
    }

    private func bossWorkingLoop() -> SKAction? {
        guard let workA = bossTextures[.workA],
              let workB = bossTextures[.workB],
              let blink = bossTextures[.workBlink] else {
            return nil
        }

        var actions: [SKAction] = []
        for _ in 0..<5 {
            actions.append(.setTexture(workA, resize: false))
            actions.append(.wait(forDuration: 0.24))
            actions.append(.setTexture(workB, resize: false))
            actions.append(.wait(forDuration: 0.22))
        }
        actions.append(.setTexture(blink, resize: false))
        actions.append(.wait(forDuration: 0.13))
        actions.append(.setTexture(workA, resize: false))
        actions.append(.wait(forDuration: 0.65))

        return .repeatForever(.sequence(actions))
    }

    private func bossSpeakingLoop() -> SKAction? {
        guard let speakA = bossTextures[.speakA],
              let speakB = bossTextures[.speakB],
              let blink = bossTextures[.speakBlink] else {
            return nil
        }

        return .repeatForever(
            .sequence([
                .setTexture(speakA, resize: false),
                .wait(forDuration: 0.34),
                .setTexture(speakB, resize: false),
                .wait(forDuration: 0.22),
                .setTexture(speakA, resize: false),
                .wait(forDuration: 0.28),
                .setTexture(speakB, resize: false),
                .wait(forDuration: 0.24),
                .setTexture(blink, resize: false),
                .wait(forDuration: 0.13),
                .setTexture(speakA, resize: false),
                .wait(forDuration: 0.42)
            ])
        )
    }

    private func updateWindowLights(phase: OfficeAnimationPhase) {
        for (index, light) in windowLights.enumerated() {
            let level = CGFloat(phase.windowLightOpacity(at: index))
            let scale = 0.92 + level * 0.16

            if currentStyle == .twoD {
                light.shade.alpha = (1 - level) * 0.16
                light.halo.alpha = 0.012 + level * 0.09
                light.core.alpha = 0.035 + level * 0.36
            } else {
                light.shade.alpha = (1 - level) * 0.16
                light.halo.alpha = 0.01 + level * 0.08
                light.core.alpha = 0.04 + level * 0.28
            }
            light.halo.setScale(scale)
            light.core.setScale(scale)
        }
    }

    private func updateRooftopBeacons(phase: OfficeAnimationPhase) {
        for (index, beacon) in rooftopBeacons.enumerated() {
            let level = CGFloat(phase.rooftopBeaconOpacity(at: index))

            if currentStyle == .twoD {
                beacon.halo.alpha = 0.015 + level * 0.28
                beacon.core.alpha = 0.03 + level * 0.92
            } else {
                beacon.halo.alpha = 0.015 + level * 0.16
                beacon.core.alpha = 0.08 + level * 0.72
            }
            beacon.halo.setScale(0.65 + level * 0.90)
            beacon.core.setScale(0.90 + level * 0.65)
        }
    }

    private func updateMonitorGlows(phase: OfficeAnimationPhase) {
        for (index, glow) in monitorGlows.enumerated() {
            let level = CGFloat(phase.monitorGlowOpacity(at: index))
            glow.alpha = currentStyle == .twoD
                ? 0.004 + level * 0.016
                : 0.012 + level * 0.032
            glow.setScale(0.98 + level * 0.04)
        }
    }

    private func updateStageGlow(phase: OfficeAnimationPhase) {
        let level = CGFloat(phase.stageGlow)
        if currentStyle == .twoD {
            stageGlowWide.alpha = 0.008 + level * 0.015
            stageGlowCore.alpha = 0.015 + level * 0.035
        } else {
            stageGlowWide.alpha = 0.025 + level * 0.055
            stageGlowCore.alpha = 0.06 + level * 0.10
        }
    }

    private func stageLightColor(for theme: OfficeTheme) -> NSColor {
        switch theme {
        case .modernDay:
            NSColor(calibratedRed: 0.82, green: 0.95, blue: 0.96, alpha: 1)
        case .modernNight:
            NSColor(calibratedRed: 1.00, green: 0.80, blue: 0.52, alpha: 1)
        }
    }

    private func artworkVerticalOffset(
        for theme: OfficeTheme,
        style: OfficeArtStyle
    ) -> CGFloat {
        style == .threeD && theme == .modernDay ? 7 : 0
    }

    private func layoutContent() {
        letterboxNode.size = size
        let fittedFrame = OfficeCanvasGeometry.fittedFrame(in: size)
        let scale =
            fittedFrame.width / OfficeCanvasGeometry.designSize.width
        contentRoot.setScale(scale)
        contentRoot.position = CGPoint(
            x: fittedFrame.minX,
            y: fittedFrame.minY
        )
    }
}
