// 이 파일은 V4 네 테마의 파일 형식과 동일한 화면 규격을 검증한다.

import AppKit
import XCTest
@testable import OfficeCore

final class PixelOfficeAssetTests: XCTestCase {
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

    func testAllFourThemesLoadFromBundle() {
        XCTAssertEqual(OfficeTheme.allCases.count, 4)

        for theme in OfficeTheme.allCases {
            XCTAssertEqual(PixelOfficeAsset.resourceURL(for: theme).pathExtension, "png")
            XCTAssertFalse(PixelOfficeAsset.image(for: theme).representations.isEmpty)
        }
    }

    func testAllThemesUseTheV4Canvas() throws {
        for theme in OfficeTheme.allCases {
            let data = try Data(contentsOf: PixelOfficeAsset.resourceURL(for: theme))
            let representation = try XCTUnwrap(NSBitmapImageRep(data: data))

            XCTAssertEqual(representation.pixelsWide, 1_536, theme.title)
            XCTAssertEqual(representation.pixelsHigh, 1_024, theme.title)
            XCTAssertEqual(
                Double(representation.pixelsWide) / Double(representation.pixelsHigh),
                1.5,
                accuracy: 0.0001,
                theme.title
            )
        }
    }

    func testAllCharacterMotionPatchesLoadForEveryTheme() {
        for theme in OfficeTheme.allCases {
            for character in OfficeCharacter.allCases {
                for kind in OfficeCharacterMotionKind.allCases {
                    let url = PixelOfficeAsset.motionResourceURL(
                        for: character,
                        kind: kind,
                        theme: theme
                    )
                    XCTAssertEqual(url.pathExtension, "png")
                    XCTAssertFalse(
                        PixelOfficeAsset.motionImage(
                            for: character,
                            kind: kind,
                            theme: theme
                        ).representations.isEmpty,
                        "\(theme.title) \(character.rawValue) \(kind.rawValue)"
                    )
                }
            }
        }
    }

    func testNightFlagsMatchThemeNames() {
        XCTAssertFalse(OfficeTheme.modernDay.isNight)
        XCTAssertTrue(OfficeTheme.modernNight.isNight)
        XCTAssertFalse(OfficeTheme.woodDay.isNight)
        XCTAssertTrue(OfficeTheme.woodNight.isNight)
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

    func testRooftopBeaconFlashesBrieflyThenDims() {
        let periodStart = 3.8 * 100
        let flash = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: periodStart + 0.22),
            reduceMotion: false
        )
        let betweenFlashes = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: periodStart + 2.0),
            reduceMotion: false
        )

        XCTAssertGreaterThan(flash.rooftopBeaconOpacity(at: 0), 0.9)
        XCTAssertLessThan(betweenFlashes.rooftopBeaconOpacity(at: 0), 0.2)
    }

    func testRealtimeEffectsChangeAcrossFrames() {
        let first = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 0),
            reduceMotion: false
        )
        let next = OfficeAnimationPhase(
            date: Date(timeIntervalSince1970: 0.4),
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
            CGPoint(x: 210, y: 425)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 108, y: 0),
            CGPoint(x: 318, y: 366)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 108, y: 69),
            CGPoint(x: 318, y: 435)
        )
        XCTAssertEqual(
            OfficeWhiteboardGeometry.usagePoint(x: 0, y: 69),
            CGPoint(x: 210, y: 494)
        )
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
