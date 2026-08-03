// 이 파일은 V4 네 테마의 파일 형식과 동일한 화면 규격을 검증한다.

import AppKit
import AVFoundation
import XCTest
@testable import OfficeCore

final class PixelOfficeAssetTests: XCTestCase {
    func testArtStyleMetadataAndSupportedThemesAreStable() {
        XCTAssertEqual(OfficeArtStyle.twoD.rawValue, "2d")
        XCTAssertEqual(OfficeArtStyle.threeD.rawValue, "3d")
        XCTAssertEqual(OfficeArtStyle.defaultValue, .twoD)
        XCTAssertEqual(OfficeArtStyle.twoD.title, "2D")
        XCTAssertEqual(OfficeArtStyle.threeD.title, "3D")
        XCTAssertEqual(
            OfficeArtStyle.twoD.supportedThemes,
            [.modernDay, .modernNight]
        )
        XCTAssertEqual(
            OfficeArtStyle.threeD.supportedThemes,
            OfficeTheme.allCases
        )
        XCTAssertEqual(OfficeTheme.allCases, [.modernDay, .modernNight])
    }

    func testTwoDAndThreeDUseDistinctModernBackgrounds() {
        for theme in [OfficeTheme.modernDay, .modernNight] {
            let twoDURL = PixelOfficeAsset.resourceURL(
                for: theme,
                style: .twoD
            )
            let threeDURL = PixelOfficeAsset.resourceURL(
                for: theme,
                style: .threeD
            )

            XCTAssertNotEqual(twoDURL, threeDURL)
            XCTAssertTrue(
                twoDURL.path.contains("office-retina-v1/backgrounds/2d")
            )
            XCTAssertTrue(
                threeDURL.path.contains("office-retina-v1/backgrounds/3d")
            )
        }
    }

    func testSpeechBubbleAnchorsStayClearOfCharacterFaces() throws {
        let configuration = try CharacterConfigurationAsset.load()
        let boss = try XCTUnwrap(
            configuration.characters.first { $0.id == .boss }
        )

        XCTAssertGreaterThan(
            boss.bubble.x,
            boss.hitbox.rect.maxX,
            "부장 말풍선은 얼굴 오른쪽에 있어야 합니다."
        )
        XCTAssertLessThanOrEqual(
            boss.bubble.y,
            boss.hitbox.rect.minY + 16,
            "부장 말풍선은 머리 높이 가까이에 있어야 합니다."
        )

        for character in configuration.characters where character.id != .boss {
            XCTAssertLessThanOrEqual(
                character.bubble.y,
                character.hitbox.rect.minY - 36,
                "\(character.id.rawValue) 말풍선은 머리 위에 있어야 합니다."
            )
        }
    }

    func testAllThemesLoadFromBundle() {
        XCTAssertEqual(OfficeTheme.allCases.count, 2)

        for theme in OfficeTheme.allCases {
            XCTAssertEqual(PixelOfficeAsset.resourceURL(for: theme).pathExtension, "png")
            XCTAssertFalse(PixelOfficeAsset.image(for: theme).representations.isEmpty)
        }
    }

    func testFullBodyProfilesExistForAllCharactersAtProfileSize() throws {
        for character in OfficeCharacter.allCases {
            let url = try XCTUnwrap(
                PixelOfficeAsset.fullBodyProfileURL(for: character)
            )
            let image = try XCTUnwrap(NSImage(contentsOf: url))
            let representation = try XCTUnwrap(
                image.representations.first as? NSBitmapImageRep
            )

            XCTAssertEqual(representation.pixelsWide, 1_774)
            XCTAssertEqual(representation.pixelsHigh, 3_548)
        }
    }

    func testOnlyLeftWomanHasASilentFullBodyProfileVideo() async throws {
        let videoURL = try XCTUnwrap(
            PixelOfficeAsset.fullBodyProfileVideoURL(for: .leftWoman)
        )
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertEqual(videoURL.pathExtension, "mp4")
        XCTAssertEqual(videoURL.lastPathComponent, "profile-left-woman-loop.mp4")
        XCTAssertFalse(videoTracks.isEmpty)
        XCTAssertTrue(audioTracks.isEmpty)

        for character in OfficeCharacter.allCases where character != .leftWoman {
            XCTAssertNil(PixelOfficeAsset.fullBodyProfileVideoURL(for: character))
        }
    }

    func testAllThemesUseTheRetinaV4Canvas() throws {
        for style in OfficeArtStyle.allCases {
            for theme in style.supportedThemes {
                let data = try Data(
                    contentsOf: PixelOfficeAsset.resourceURL(
                        for: theme,
                        style: style
                    )
                )
                let representation = try XCTUnwrap(NSBitmapImageRep(data: data))

                XCTAssertEqual(
                    representation.pixelsWide,
                    3_072,
                    "\(style.title) \(theme.title)"
                )
                XCTAssertEqual(
                    representation.pixelsHigh,
                    2_048,
                    "\(style.title) \(theme.title)"
                )
                XCTAssertEqual(
                    Double(representation.pixelsWide)
                        / Double(representation.pixelsHigh),
                    1.5,
                    accuracy: 0.0001,
                    "\(style.title) \(theme.title)"
                )
            }
        }
    }

    func testAllCharacterMotionPatchesLoadForEveryTheme() {
        for style in OfficeArtStyle.allCases {
            for theme in style.supportedThemes {
                for character in OfficeCharacter.allCases {
                    for kind in OfficeCharacterMotionKind.allCases {
                        let url = PixelOfficeAsset.motionResourceURL(
                            for: character,
                            kind: kind,
                            theme: theme,
                            style: style
                        )
                        XCTAssertEqual(url.pathExtension, "png")
                        XCTAssertFalse(
                            PixelOfficeAsset.motionImage(
                                for: character,
                                kind: kind,
                                theme: theme,
                                style: style
                            ).representations.isEmpty,
                            "\(style.title) \(theme.title) "
                                + "\(character.rawValue) \(kind.rawValue)"
                        )
                    }
                }
            }
        }
    }

    func testMotionPatchDimensionsMatchDoubleResolutionCanvasBoxes() throws {
        let expected: [
            OfficeArtStyle: [
                OfficeCharacter: [OfficeCharacterMotionKind: CGSize]
            ]
        ] = [
            .twoD: [
                .boss: [
                    .blink: CGSize(width: 77, height: 42),
                    .mouth: CGSize(width: 26, height: 20),
                    .typing: CGSize(width: 43, height: 34)
                ],
                .leftMan: [
                    .blink: CGSize(width: 91, height: 55),
                    .mouth: CGSize(width: 25, height: 22),
                    .typing: CGSize(width: 53, height: 46)
                ],
                .leftWoman: [
                    .blink: CGSize(width: 84, height: 51),
                    .mouth: CGSize(width: 31, height: 28),
                    .typing: CGSize(width: 65, height: 42)
                ],
                .rightWoman: [
                    .blink: CGSize(width: 86, height: 51),
                    .mouth: CGSize(width: 29, height: 28),
                    .typing: CGSize(width: 66, height: 41)
                ],
                .rightMan: [
                    .blink: CGSize(width: 88, height: 54),
                    .mouth: CGSize(width: 30, height: 29),
                    .typing: CGSize(width: 59, height: 41)
                ]
            ],
            .threeD: [
                .boss: [
                    .blink: CGSize(width: 62, height: 37),
                    .mouth: CGSize(width: 39, height: 27),
                    .typing: CGSize(width: 48, height: 42)
                ],
                .leftMan: [
                    .blink: CGSize(width: 58, height: 42),
                    .mouth: CGSize(width: 32, height: 24),
                    .typing: CGSize(width: 94, height: 76)
                ],
                .leftWoman: [
                    .blink: CGSize(width: 51, height: 36),
                    .mouth: CGSize(width: 38, height: 26),
                    .typing: CGSize(width: 59, height: 47)
                ],
                .rightWoman: [
                    .blink: CGSize(width: 58, height: 39),
                    .mouth: CGSize(width: 37, height: 28),
                    .typing: CGSize(width: 62, height: 50)
                ],
                .rightMan: [
                    .blink: CGSize(width: 64, height: 43),
                    .mouth: CGSize(width: 41, height: 30),
                    .typing: CGSize(width: 75, height: 55)
                ]
            ]
        ]

        for style in OfficeArtStyle.allCases {
            for theme in style.supportedThemes {
                for character in OfficeCharacter.allCases {
                    for kind in OfficeCharacterMotionKind.allCases {
                        let data = try Data(
                            contentsOf: PixelOfficeAsset.motionResourceURL(
                                for: character,
                                kind: kind,
                                theme: theme,
                                style: style
                            )
                        )
                        let representation = try XCTUnwrap(
                            NSBitmapImageRep(data: data)
                        )
                        let size = try XCTUnwrap(
                            expected[style]?[character]?[kind]
                        )

                        XCTAssertEqual(
                            representation.pixelsWide,
                            Int(size.width) * 2,
                            "\(style.title) \(theme.title) "
                                + "\(character.rawValue) \(kind.rawValue)"
                        )
                        XCTAssertEqual(
                            representation.pixelsHigh,
                            Int(size.height) * 2,
                            "\(style.title) \(theme.title) "
                                + "\(character.rawValue) \(kind.rawValue)"
                        )
                    }
                }
            }
        }
    }

    func testTwoDMotionPatchesUseTransparentStableEdges() throws {
        for theme in OfficeArtStyle.twoD.supportedThemes {
            for character in OfficeCharacter.allCases {
                for kind in OfficeCharacterMotionKind.allCases {
                    let data = try Data(
                        contentsOf: PixelOfficeAsset.motionResourceURL(
                            for: character,
                            kind: kind,
                            theme: theme,
                            style: .twoD
                        )
                    )
                    let representation = try XCTUnwrap(
                        NSBitmapImageRep(data: data)
                    )
                    let topLeft = try XCTUnwrap(
                        representation.colorAt(x: 0, y: 0)
                    )

                    XCTAssertTrue(
                        representation.hasAlpha,
                        "\(theme.title) \(character.rawValue) "
                            + "\(kind.rawValue)"
                    )
                    XCTAssertEqual(
                        topLeft.alphaComponent,
                        0,
                        accuracy: 0.001,
                        "\(theme.title) \(character.rawValue) "
                            + "\(kind.rawValue)"
                    )
                }
            }
        }
    }

    func testNightFlagsMatchThemeNames() {
        XCTAssertFalse(OfficeTheme.modernDay.isNight)
        XCTAssertTrue(OfficeTheme.modernNight.isNight)
    }

    func testWoodThemeValuesAreRetired() {
        XCTAssertNil(OfficeTheme(rawValue: "woodDay"))
        XCTAssertNil(OfficeTheme(rawValue: "woodNight"))
    }

    func testCanvasAspectFitIncludesLetterboxing() {
        XCTAssertEqual(
            OfficeCanvasGeometry.fittedFrame(in: CGSize(width: 1_200, height: 800)),
            CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        XCTAssertEqual(
            OfficeCanvasGeometry.fittedFrame(in: CGSize(width: 1_200, height: 900)),
            CGRect(x: 0, y: 50, width: 1_200, height: 800)
        )
        XCTAssertEqual(
            OfficeCanvasGeometry.fittedFrame(in: CGSize(width: 1_000, height: 600)),
            CGRect(x: 50, y: 0, width: 900, height: 600)
        )
    }

    func testAnimationPhaseUsesRealClockSeconds() {
        XCTAssertEqual(
            OfficeAnimationPhase(
                date: Date(timeIntervalSince1970: 15),
                reduceMotion: false
            ).clockSecond,
            15
        )
        XCTAssertEqual(
            OfficeAnimationPhase(
                date: Date(timeIntervalSince1970: 75),
                reduceMotion: false
            ).clockSecond,
            15
        )
    }

    func testDecorativeAnimationFreezesForReduceMotion() {
        let early = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 10),
            reduceMotion: true
        )
        let late = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 1_000),
            reduceMotion: true
        )

        XCTAssertEqual(early.stageGlow, 0.5)
        XCTAssertEqual(late.stageGlow, 0.5)
        XCTAssertEqual(
            early.windowLightOpacity(at: 3),
            late.windowLightOpacity(at: 3)
        )
        XCTAssertEqual(
            early.monitorGlowOpacity(at: 2),
            late.monitorGlowOpacity(at: 2)
        )
    }

    func testAnimationValuesStayWithinRenderRange() {
        for second in 0 ... 120 {
            let phase = OfficeAnimationPhase(
                date: Date(timeIntervalSince1970: Double(second) / 2),
                reduceMotion: false
            )

            XCTAssertGreaterThanOrEqual(phase.stageGlow, 0)
            XCTAssertLessThanOrEqual(phase.stageGlow, 1)

            for lightIndex in 0 ..< 11 {
                let opacity = phase.windowLightOpacity(at: lightIndex)
                XCTAssertGreaterThanOrEqual(opacity, 0)
                XCTAssertLessThanOrEqual(opacity, 1)
            }

            for monitorIndex in 0 ..< 5 {
                let opacity = phase.monitorGlowOpacity(at: monitorIndex)
                XCTAssertGreaterThanOrEqual(opacity, 0)
                XCTAssertLessThanOrEqual(opacity, 1)
            }

            for beaconIndex in 0 ..< 3 {
                let opacity = phase.rooftopBeaconOpacity(at: beaconIndex)
                XCTAssertGreaterThanOrEqual(opacity, 0)
                XCTAssertLessThanOrEqual(opacity, 1)
            }
        }
    }

    func testWindowLightsHoldSteadyBetweenSwitches() {
        let first = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 4_000),
            reduceMotion: false
        )
        let shortlyAfter = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 4_000.4),
            reduceMotion: false
        )

        // 창문 불빛은 프레임마다 흔들리지 않고 한동안 같은 밝기를 유지한다.
        XCTAssertEqual(
            first.windowLightOpacity(at: 0),
            shortlyAfter.windowLightOpacity(at: 0)
        )

        let levels = (0 ..< 400).map { step in
            OfficeAnimationPhase(
                date: Date(timeIntervalSince1970: 4_000 + Double(step)),
                reduceMotion: false
            )
            .windowLightOpacity(at: 0)
        }
        XCTAssertGreaterThan(Set(levels).count, 1)
    }

    func testWindowLightsChangeWithinEveryTenSecondWindow() {
        for windowStart in stride(
            from: 0.0,
            through: 40.0,
            by: 10.0
        ) {
            let initial = (0 ..< 11).map { lightIndex in
                OfficeAnimationPhase(
                    date: Date(timeIntervalSince1970: windowStart),
                    reduceMotion: false
                )
                .windowLightOpacity(at: lightIndex)
            }
            let changed = (1 ... 20).contains { step in
                let sampleTime = windowStart + Double(step) * 0.5
                let sample = (0 ..< 11).map { lightIndex in
                    OfficeAnimationPhase(
                        date: Date(timeIntervalSince1970: sampleTime),
                        reduceMotion: false
                    )
                    .windowLightOpacity(at: lightIndex)
                }
                return sample != initial
            }
            XCTAssertTrue(changed, "\(windowStart)초 구간")
        }
    }

    func testRooftopBeaconFlashesBrieflyThenDims() {
        let periodStart = 2.6 * 100
        let flash = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: periodStart + 0.19),
            reduceMotion: false
        )
        let betweenFlashes = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: periodStart + 1.3),
            reduceMotion: false
        )
        let nextFlash = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: periodStart + 2.6 + 0.19),
            reduceMotion: false
        )

        XCTAssertGreaterThan(flash.rooftopBeaconOpacity(at: 0), 0.9)
        XCTAssertLessThan(betweenFlashes.rooftopBeaconOpacity(at: 0), 0.1)
        XCTAssertGreaterThan(nextFlash.rooftopBeaconOpacity(at: 0), 0.9)
    }

    func testRealtimeEffectsChangeAcrossFrames() {
        let first = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 0),
            reduceMotion: false
        )
        let next = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 0.19),
            reduceMotion: false
        )

        XCTAssertNotEqual(first.stageGlow, next.stageGlow)
        XCTAssertNotEqual(
            first.rooftopBeaconOpacity(at: 0),
            next.rooftopBeaconOpacity(at: 0)
        )
        XCTAssertNotEqual(
            first.monitorGlowOpacity(at: 0),
            next.monitorGlowOpacity(at: 0)
        )
    }

    func testClaudeWorkspacePermissionUsesNoninteractiveAutoMode() {
        XCTAssertEqual(
            AgentPermission.workspaceWrite.cliValue(for: .claude),
            "auto"
        )
        XCTAssertEqual(
            AgentPermission(cliValue: "acceptEdits"),
            .workspaceWrite
        )
    }

    func testFullAccessPermissionKeepsBackendSpecificValues() {
        XCTAssertEqual(
            AgentPermission.fullAccess.cliValue(for: .codex),
            "danger-full-access"
        )
        XCTAssertEqual(
            AgentPermission.fullAccess.cliValue(for: .claude),
            "bypassPermissions"
        )
    }

    func testWhiteboardUsageAreaMatchesPerspectiveCorners() {
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 0, y: 0),
            CGPoint(x: 200, y: 415)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 128, y: 0),
            CGPoint(x: 328, y: 345)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 128, y: 78),
            CGPoint(x: 328, y: 423)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 0, y: 78),
            CGPoint(x: 200, y: 493)
        )
    }

    func testTwoDWhiteboardUsageAreaMatchesAnimePerspective() {
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(
                for: .twoD,
                x: 0,
                y: 0
            ),
            CGPoint(x: 194, y: 423)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(
                for: .twoD,
                x: 128,
                y: 0
            ),
            CGPoint(x: 326, y: 339)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(
                for: .twoD,
                x: 128,
                y: 78
            ),
            CGPoint(x: 326, y: 447)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(
                for: .twoD,
                x: 0,
                y: 78
            ),
            CGPoint(x: 194, y: 531)
        )
    }

    func testTwoDWhiteboardRowsStayParallelToBoardFrame() {
        let top = OfficeWhiteboardGeometry.usageTransform(
            for: .twoD,
            at: CGPoint(x: 0, y: 0)
        )
        let bottom = OfficeWhiteboardGeometry.usageTransform(
            for: .twoD,
            at: CGPoint(x: 0, y: 78)
        )

        XCTAssertEqual(top.b, -84.0 / 128.0, accuracy: 0.000_001)
        XCTAssertEqual(bottom.b, -84.0 / 128.0, accuracy: 0.000_001)
        XCTAssertEqual(top.b, bottom.b, accuracy: 0.000_001)
    }

    func testTwoDClockFaceMatchesTheUprightBackgroundEllipse() {
        XCTAssertEqual(
            OfficeAnalogClockGeometry.twoDCenter,
            CGPoint(x: 1_194, y: 687)
        )
        XCTAssertEqual(OfficeAnalogClockGeometry.twoDHorizontalScale, 1)
        XCTAssertEqual(OfficeAnalogClockGeometry.twoDVerticalScale, 1.35)
        XCTAssertEqual(OfficeAnalogClockGeometry.twoDRotation, 0)
    }

    func testNormalAgentResponseRemainsUnchanged() {
        let text = "작업을 마쳤습니다.\n추가 확인은 필요하지 않습니다."

        XCTAssertEqual(
            AgentResponseProtocol.decode(text),
            AgentResponseEnvelope(text: text, needsInput: false)
        )
    }

    func testAgentQuestionMarkerIsRemovedAndQuestionIsPreserved() {
        let response = "\r\n[NEED_INPUT]\r\n첫 번째 선택인가요?\r\n- A\r\n- B"

        XCTAssertEqual(
            AgentResponseProtocol.decode(response),
            AgentResponseEnvelope(
                text: "첫 번째 선택인가요?\n- A\n- B",
                needsInput: true
            )
        )
    }

    func testEmptyAgentQuestionMarkerIsNotAccepted() {
        let response = "[NEED_INPUT]\n\n"

        XCTAssertEqual(
            AgentResponseProtocol.decode(response),
            AgentResponseEnvelope(text: response, needsInput: false)
        )
    }

    func testMarkerAfterNormalTextDoesNotCreateAQuestion() {
        let response = "설명입니다.\n[NEED_INPUT]\n이 문장은 예시입니다."

        XCTAssertEqual(
            AgentResponseProtocol.decode(response),
            AgentResponseEnvelope(text: response, needsInput: false)
        )
    }

    func testClaudeSessionLimitIsRecognized() {
        XCTAssertTrue(
            AgentUsageLimitClassifier.isLimitReached(
                "You've hit your session limit · resets 2:50am (Asia/Seoul)"
            )
        )
    }

    func testCodexUsageAndQuotaLimitsAreRecognized() {
        XCTAssertTrue(
            AgentUsageLimitClassifier.isLimitReached(
                "You have reached your weekly usage limit."
            )
        )
        XCTAssertTrue(
            AgentUsageLimitClassifier.isLimitReached(
                "insufficient_quota"
            )
        )
        XCTAssertTrue(
            AgentUsageLimitClassifier.isLimitReached(
                "0 weighted tokens left"
            )
        )
    }

    func testTransientRateLimitIsNotTreatedAsEndOfShift() {
        XCTAssertFalse(
            AgentUsageLimitClassifier.isLimitReached(
                "Rate limit exceeded. Retry after 10 seconds."
            )
        )
        XCTAssertFalse(
            AgentUsageLimitClassifier.isLimitReached(
                "Weekly usage is currently 70 percent."
            )
        )
    }
}
