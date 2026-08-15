// 이 파일은 대화 백화 증상 함정의 판정과 기록 형식을 검증한다.

import XCTest
@testable import OfficeGame

final class LiveWorkspaceFeedStallReportTests: XCTestCase {
    func testBlankIsOnlyReportedWhenConversationExistsButNothingShows() {
        // 문서가 사라진 경우.
        XCTAssertTrue(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 8,
                documentHeight: 0,
                viewportHeight: 600,
                visibleIntersectionHeight: 0
            )
        )
        // 문서는 있지만 보이는 영역과 겹치지 않는 경우.
        XCTAssertTrue(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 8,
                documentHeight: 4_000,
                viewportHeight: 600,
                visibleIntersectionHeight: 0
            )
        )
        // 정상 표시.
        XCTAssertFalse(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 8,
                documentHeight: 4_000,
                viewportHeight: 600,
                visibleIntersectionHeight: 600
            )
        )
        // 대화가 없으면 빈 화면이 정상이라 증상이 아니다.
        XCTAssertFalse(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 0,
                documentHeight: 0,
                viewportHeight: 600,
                visibleIntersectionHeight: 0
            )
        )
        // 창이 접혀 보기 영역이 없는 순간은 판정 대상이 아니다.
        XCTAssertFalse(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 8,
                documentHeight: 0,
                viewportHeight: 0,
                visibleIntersectionHeight: 0
            )
        )
    }

    func testBlankIsCaughtWhenGeometryLooksFineButNoCardIsDrawn() {
        // 실제 증상은 문서 높이와 스크롤 위치가 정상인데도 카드가 하나도
        // 그려지지 않는 구간이었다. 기하만 보는 판정으로는 놓친다.
        XCTAssertTrue(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 12,
                documentHeight: 4_000,
                viewportHeight: 600,
                visibleIntersectionHeight: 600,
                visibleCardCount: 0
            ),
            "카드가 하나도 없으면 사용자 눈에는 빈 화면입니다."
        )
        XCTAssertFalse(
            LiveWorkspaceFeedBlankDetector.isBlank(
                turnCount: 12,
                documentHeight: 4_000,
                viewportHeight: 600,
                visibleIntersectionHeight: 600,
                visibleCardCount: 3
            )
        )
    }

    func testTrapStaysOffUnlessExplicitlyEnabled() {
        // 평소에는 기록이 쌓이지 않아야 한다. 증상을 쫓을 때만 켠다.
        XCTAssertNil(
            LiveWorkspaceFeedStallRecorder.live(environment: [:]),
            "환경변수 없이 기록이 쌓이면 로그가 계속 자란다."
        )
        XCTAssertNotNil(
            LiveWorkspaceFeedStallRecorder.live(
                environment: [
                    LiveWorkspaceFeedStallRecorder.enableVariableName: "1",
                ]
            ),
            "환경변수를 켜면 다시 기록해야 합니다."
        )
    }

    func testTestRunsNeverWriteIntoTheRealLog() {
        XCTAssertNil(
            LiveWorkspaceFeedStallRecorder.live(
                environment: ["XCTestConfigurationFilePath": "/tmp/x.plist"]
            ),
            "테스트 값이 실제 사용 기록에 섞이면 증거를 믿을 수 없습니다."
        )
        XCTAssertNotNil(
            LiveWorkspaceFeedStallRecorder.live(
                environment: [
                    LiveWorkspaceFeedStallRecorder.enableVariableName: "1",
                ]
            )
        )
    }

    func testDocumentHeightTraceKeepsShapeWithoutGrowingForever() {
        var detector = LiveWorkspaceFeedBlankDetector()
        for height in [3_200.0, 3_200.0, 0.0, 0.0, 480.0, 3_200.0] {
            detector.appendTrace(documentHeight: height)
        }
        XCTAssertEqual(
            detector.documentHeightTrace,
            [3_200, 0, 480, 3_200],
            "같은 값이 이어지면 한 번만 남겨 흔들린 모양이 드러나야 합니다."
        )

        for index in 0..<100 {
            detector.appendTrace(documentHeight: Double(index) * 10)
        }
        XCTAssertEqual(
            detector.documentHeightTrace.count,
            LiveWorkspaceFeedBlankDetector.maximumTraceCount,
            "기록이 무한정 늘어나면 안 됩니다."
        )

        detector.reset()
        XCTAssertTrue(detector.documentHeightTrace.isEmpty)
    }

    func testStallPolicyWaitsThenRepeatsWithABound() {
        var policy = LiveWorkspaceFeedStallPolicy()

        XCTAssertFalse(
            policy.shouldReport(
                elapsed: LiveWorkspaceFeedStallPolicy.firstReportDelay / 2
            ),
            "짧은 지연까지 남기면 기록이 잡음이 됩니다."
        )
        XCTAssertTrue(
            policy.shouldReport(
                elapsed: LiveWorkspaceFeedStallPolicy.firstReportDelay
            )
        )
        XCTAssertFalse(
            policy.shouldReport(
                elapsed: LiveWorkspaceFeedStallPolicy.firstReportDelay
                    + LiveWorkspaceFeedStallPolicy.repeatReportInterval / 2
            ),
            "반복 기록은 간격을 두어야 합니다."
        )

        var elapsed = LiveWorkspaceFeedStallPolicy.firstReportDelay
        var reported = 1
        for _ in 0..<10 {
            elapsed += LiveWorkspaceFeedStallPolicy.repeatReportInterval
            if policy.shouldReport(elapsed: elapsed) {
                reported += 1
            }
        }
        XCTAssertEqual(
            reported,
            LiveWorkspaceFeedStallPolicy.maximumReportsPerTransition,
            "한 전환에서 남기는 기록 수에 상한이 있어야 합니다."
        )

        policy.reset()
        XCTAssertTrue(
            policy.shouldReport(
                elapsed: LiveWorkspaceFeedStallPolicy.firstReportDelay
            )
        )
    }

    func testRecordedLineKeepsRawFieldsAndHumanSummary() throws {
        let report = LiveWorkspaceFeedStallReport(
            kind: "active-blank-recovered",
            characterID: "left-woman",
            elapsedSeconds: 3.25,
            readiness: "recovered",
            hostWidth: 700,
            hostHeight: 560,
            hasScrollView: true,
            documentHeight: 0,
            viewportHeight: 560,
            visibleIntersectionHeight: 0,
            turnCount: 12,
            isLoadingInitialFeed: false,
            readinessRevision: 7,
            preClampPassCount: 1,
            postClampPassCount: 0,
            viewportClampCount: 3,
            hasLoadingGate: false,
            documentHeightTrace: [3_200, 0, 480, 3_200]
        )

        XCTAssertTrue(report.summary.contains("active-blank-recovered"))
        XCTAssertTrue(report.summary.contains("3.2s"))
        XCTAssertTrue(
            report.summary.contains("trace=3200>0>480>3200"),
            "스크롤바가 움찔거린 모양이 요약에 드러나야 합니다."
        )

        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let line = try XCTUnwrap(
            LiveWorkspaceFeedStallRecorder.line(for: report, at: timestamp)
        )
        XCTAssertTrue(line.hasSuffix("\n"), "한 줄씩 덧붙일 수 있어야 합니다.")
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(decoded["turnCount"] as? Int, 12)
        XCTAssertEqual(decoded["documentHeight"] as? Double, 0)
        XCTAssertEqual(decoded["characterID"] as? String, "left-woman")
        XCTAssertNotNil(decoded["recordedAt"])
        XCTAssertNotNil(decoded["summary"])
    }

    func testRecorderAppendsEachOccurrenceToOneFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "office-stall-\(UUID().uuidString)")
        let recorder = LiveWorkspaceFeedStallRecorder(
            directoryURL: directory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let report = LiveWorkspaceFeedStallReport(
            kind: "active-blank-persisting",
            characterID: "boss",
            elapsedSeconds: 2.5,
            readiness: "blank",
            hostWidth: 700,
            hostHeight: 560,
            hasScrollView: true,
            documentHeight: 0,
            viewportHeight: 560,
            visibleIntersectionHeight: 0,
            turnCount: 5,
            isLoadingInitialFeed: false,
            readinessRevision: 2,
            preClampPassCount: 0,
            postClampPassCount: 0,
            viewportClampCount: 0,
            hasLoadingGate: false
        )

        XCTAssertTrue(recorder.record(report, at: Date()))
        XCTAssertTrue(recorder.record(report, at: Date()))

        let contents = try String(
            contentsOf: recorder.fileURL,
            encoding: .utf8
        )
        XCTAssertEqual(
            contents.split(separator: "\n").count,
            2,
            "증상이 다시 나면 덮어쓰지 말고 이어 붙여야 합니다."
        )
    }

    func testJitterIsDetectedWhenLayoutKeepsMovingWithoutGoingBlank() {
        var detector = LiveWorkspaceFeedJitterDetector()
        // 화면은 비지 않지만 문서 높이와 스크롤 위치가 짧은 시간에
        // 여러 번 튀는 구간이 사용자가 말한 깜빡임이다.
        detector.append(at: 0, documentHeight: 4_000, offsetY: 3_400)
        XCTAssertFalse(detector.isJittering, "변화 한 번은 깜빡임이 아닙니다.")
        detector.append(at: 0.1, documentHeight: 2_600, offsetY: 3_400)
        detector.append(at: 0.2, documentHeight: 4_000, offsetY: 3_200)
        detector.append(at: 0.3, documentHeight: 3_000, offsetY: 3_400)
        XCTAssertTrue(
            detector.isJittering,
            "문서 높이와 위치가 연달아 크게 바뀌면 깜빡임으로 잡아야 합니다."
        )

        detector.reset()
        XCTAssertTrue(detector.samples.isEmpty)
    }

    func testSteadyScrollingIsNotReportedAsJitter() {
        var detector = LiveWorkspaceFeedJitterDetector()
        // 사용자가 천천히 읽어 내려가는 것은 깜빡임이 아니다.
        for step in 0..<6 {
            detector.append(
                at: Double(step) * 0.1,
                documentHeight: 4_000,
                offsetY: 3_000 + Double(step) * 20
            )
        }
        XCTAssertFalse(
            detector.isJittering,
            "완만한 스크롤까지 남기면 기록이 잡음이 됩니다."
        )
    }

    func testJitterWindowDropsOldSamples() {
        var detector = LiveWorkspaceFeedJitterDetector()
        detector.append(at: 0, documentHeight: 4_000, offsetY: 0)
        detector.append(at: 0.1, documentHeight: 1_000, offsetY: 400)
        // 창을 벗어난 과거 변화는 현재 흔들림 판정에 쓰지 않는다.
        detector.append(
            at: LiveWorkspaceFeedJitterDetector.window + 1,
            documentHeight: 4_000,
            offsetY: 0
        )
        XCTAssertEqual(detector.samples.count, 1)
        XCTAssertFalse(detector.isJittering)
    }

    func testReportDistinguishesMountedAndVisibleCardMarkers() {
        var report = LiveWorkspaceFeedStallReport(
            kind: "active-blank-persisting",
            characterID: "left-woman",
            elapsedSeconds: 2,
            readiness: "blank",
            hostWidth: 1_100,
            hostHeight: 640,
            hasScrollView: true,
            documentHeight: 11_000,
            viewportHeight: 640,
            visibleIntersectionHeight: 640,
            turnCount: 44,
            isLoadingInitialFeed: false,
            readinessRevision: 7,
            preClampPassCount: 2,
            postClampPassCount: 3,
            viewportClampCount: 1,
            hasLoadingGate: false
        )
        report.mountedCardCount = 10
        report.visibleCardCount = 0

        XCTAssertTrue(report.summary.contains("cards=0/10"))
    }
}
