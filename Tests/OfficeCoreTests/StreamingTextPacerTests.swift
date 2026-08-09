// 이 파일은 긴 한글과 이모지 응답의 적응형 타자 표시량을 검증한다.

import AppKit
import XCTest
@testable import OfficeCore
@testable import OfficeGame

@MainActor
final class StreamingTextPacerTests: XCTestCase {
    func testEmptyBacklogHasNoImmediatePrefix() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 0
            ),
            0
        )
    }

    func testShortBacklogKeepsOnlyAnimatedTail() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 180
            ),
            0
        )
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 181
            ),
            1
        )
    }

    func testLargeBacklogAppearsImmediatelyExceptForTail() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 1_920
            ),
            1_740
        )
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 20_000
            ),
            19_820
        )
    }

    func testTailAnimationPreservesUnicodeAndMarkdownText() {
        let target = String(
            repeating: "한글🙂 **굵게**\n| 열 | 값 |\n",
            count: 80
        )
        var rendered = ""
        var index = target.startIndex
        var remaining = target.count
        let immediatelyVisibleCount =
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: remaining
            )

        if immediatelyVisibleCount > 0 {
            let nextIndex = target.index(
                index,
                offsetBy: immediatelyVisibleCount
            )
            rendered.append(contentsOf: target[index ..< nextIndex])
            index = nextIndex
            remaining -= immediatelyVisibleCount
        }

        var animatedFrameCount = 0
        while remaining > 0 {
            let nextIndex = target.index(after: index)
            rendered.append(contentsOf: target[index ..< nextIndex])
            index = nextIndex
            remaining -= 1
            animatedFrameCount += 1
            XCTAssertTrue(target.hasPrefix(rendered))
        }

        XCTAssertEqual(rendered, target)
        XCTAssertLessThanOrEqual(
            animatedFrameCount,
            StreamingTextPacer.animatedTailCharacterCount
        )
    }

    func testUpdatePlanAnimatesOnlyNewUnicodeSuffix() {
        let plan = StreamingTextPacer.updatePlan(
            current: "한글🙂",
            target: "한글🙂 문장이 이어집니다.",
            animates: true
        )

        XCTAssertEqual(plan.immediateText, "한글🙂")
        XCTAssertEqual(
            String(plan.animatedCharacters),
            " 문장이 이어집니다."
        )
    }

    func testUpdatePlanHandlesReplacementAndDisabledAnimation() {
        let replacement = StreamingTextPacer.updatePlan(
            current: "이전 응답",
            target: "새 응답",
            animates: true
        )
        XCTAssertEqual(replacement.immediateText, "")
        XCTAssertEqual(String(replacement.animatedCharacters), "새 응답")

        let immediate = StreamingTextPacer.updatePlan(
            current: "이전 응답",
            target: "새 응답",
            animates: false
        )
        XCTAssertEqual(immediate.immediateText, "새 응답")
        XCTAssertTrue(immediate.animatedCharacters.isEmpty)
    }

    func testFullLinePlanStartsEmptyAndCompletesWithinOneSecond() {
        let target = String(repeating: "가", count: 1_000)
        let plan = StreamingTextPacer.fullLineUpdatePlan(
            current: "",
            target: target,
            animates: true
        )

        XCTAssertEqual(plan.immediateText, "")
        XCTAssertEqual(String(plan.animatedCharacters), target)
        XCTAssertEqual(plan.charactersPerTick, 1)
        XCTAssertEqual(
            plan.animationDuration,
            StreamingTextPacer.maximumLineRevealDuration
        )
    }

    func testFullLinePlanKeepsShortLinesSmooth() {
        let plan = StreamingTextPacer.fullLineUpdatePlan(
            current: "",
            target: "짧은 문장",
            animates: true
        )

        XCTAssertEqual(plan.charactersPerTick, 1)
        XCTAssertEqual(String(plan.animatedCharacters), "짧은 문장")
    }

    func testFullLineDurationIsProportionalThenCapsWithoutSawtooth() {
        var previousDuration = TimeInterval.zero
        for count in 1...2_000 {
            let plan = StreamingTextPacer.fullLineUpdatePlan(
                current: "",
                target: String(repeating: "a", count: count),
                animates: true
            )
            let duration = plan.animationDuration ?? .infinity
            let expected = min(
                StreamingTextPacer.maximumLineRevealDuration,
                TimeInterval(count)
                    * StreamingTextPacer.animationTickInterval
            )
            XCTAssertEqual(duration, expected, accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(duration, previousDuration)
            previousDuration = duration
        }

        let fiftySix = StreamingTextPacer.fullLineUpdatePlan(
            current: "",
            target: String(repeating: "a", count: 56),
            animates: true
        )
        let fiftySeven = StreamingTextPacer.fullLineUpdatePlan(
            current: "",
            target: String(repeating: "a", count: 57),
            animates: true
        )
        XCTAssertEqual(
            fiftySix.animationDuration ?? .infinity,
            0.896,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            fiftySeven.animationDuration ?? .infinity,
            0.9,
            accuracy: 0.000_001
        )
    }

    func testElapsedRevealCatchesUpAfterDelayedTick() {
        XCTAssertEqual(
            StreamingTextPacer.elapsedRevealCharacterCount(
                totalCharacterCount: 1_000,
                minimumCharacterCount: 18,
                elapsed: 0.45,
                duration: 0.9
            ),
            500
        )
        XCTAssertEqual(
            StreamingTextPacer.elapsedRevealCharacterCount(
                totalCharacterCount: 1_000,
                minimumCharacterCount: 18,
                elapsed: 1.2,
                duration: 0.9
            ),
            1_000
        )
    }

    func testImmediateFullLineCompletionFiresOncePerRevision() async {
        let view = IncrementalStreamingTextView(
            fontSize: 14,
            lineSpacing: 3
        )
        let completion = expectation(description: "즉시 완료")
        completion.assertForOverFulfill = true
        var completionCount = 0
        view.onFinishedTyping = {
            completionCount += 1
            completion.fulfill()
        }

        view.apply(
            source: "완료",
            animates: false,
            revealMode: .fullLine
        )
        await fulfillment(of: [completion], timeout: 1)
        view.apply(
            source: "완료",
            animates: false,
            revealMode: .fullLine
        )
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(completionCount, 1)
    }

    func testReplacedImmediateRevisionIgnoresStaleCompletion() async {
        let view = IncrementalStreamingTextView(
            fontSize: 14,
            lineSpacing: 3
        )
        let completion = expectation(description: "최신 revision만 완료")
        completion.assertForOverFulfill = true
        var completionCount = 0
        view.onFinishedTyping = {
            completionCount += 1
            completion.fulfill()
        }

        view.apply(
            source: "교체 전",
            animates: false,
            revealMode: .fullLine
        )
        view.apply(
            source: "교체 후",
            animates: false,
            revealMode: .fullLine
        )
        await fulfillment(of: [completion], timeout: 1)

        XCTAssertEqual(completionCount, 1)
    }

    func testMountedLongLineCompletesWithinWallClockBudget() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = IncrementalStreamingTextView(
            fontSize: 14,
            lineSpacing: 3
        )
        view.frame = window.contentView?.bounds ?? .zero
        window.contentView = view
        let completion = expectation(description: "긴 한 줄 타이핑 완료")
        let startedAt = ProcessInfo.processInfo.systemUptime
        var completedAt: TimeInterval?
        view.onFinishedTyping = {
            completedAt = ProcessInfo.processInfo.systemUptime
            completion.fulfill()
        }

        view.apply(
            source: String(repeating: "가", count: 1_000),
            animates: true,
            revealMode: .fullLine
        )
        await fulfillment(of: [completion], timeout: 1.2)

        XCTAssertLessThan(
            (completedAt ?? .infinity) - startedAt,
            1.0
        )
        window.contentView = nil
    }
}
