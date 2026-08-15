// 이 파일은 이전 기록 확장 시 사용자 업무 블록이 세로 여유를 흡수하지 않는지 검증한다.

import AppKit
import SwiftUI
import XCTest
@testable import OfficeCore
@testable import OfficeGame

@MainActor
final class LiveTurnPromptBlockLayoutTests: XCTestCase {
    func testPromptBlockKeepsIntrinsicHeightUnderTallProposal() {
        let presentation = TaskPromptPresentation(
            prompt: "이전 기록을 펼쳐도 이 업무 블록 높이는 바뀌지 않아야 합니다."
        )

        let regularHeight = measuredHeight(
            presentation,
            proposedHeight: 1_000
        )
        let tallHeight = measuredHeight(
            presentation,
            proposedHeight: 10_000
        )

        XCTAssertLessThan(tallHeight, 200)
        XCTAssertEqual(regularHeight, tallHeight, accuracy: 0.5)
    }

    func testPromptBlockWithAttachmentKeepsIntrinsicHeight() {
        let prompt = TaskPromptPresentation.canonicalPrompt(
            text: "첨부 화면을 확인해줘.",
            attachmentPaths: ["/tmp/layout-reference.png"]
        )
        let height = measuredHeight(
            TaskPromptPresentation(prompt: prompt),
            proposedHeight: 10_000
        )

        XCTAssertLessThan(height, 200)
    }

    private func measuredHeight(
        _ presentation: TaskPromptPresentation,
        proposedHeight: CGFloat
    ) -> CGFloat {
        let controller = NSHostingController(
            rootView: LiveTurnPromptBlock(
                presentation: presentation,
                sentAt: Date(timeIntervalSinceReferenceDate: 60_000)
            )
                .frame(width: 520)
        )
        return controller.sizeThatFits(
            in: NSSize(width: 520, height: proposedHeight)
        ).height
    }

    func testPromptBubbleStaysRightAlignedWithinMaximumWidth() {
        let presentation = TaskPromptPresentation(
            prompt: String(repeating: "질문이 아주 깁니다. ", count: 40)
        )
        let host = NSHostingView(
            rootView: LiveTurnPromptBlock(
                presentation: presentation,
                sentAt: Date(timeIntervalSinceReferenceDate: 60_000)
            )
            .frame(width: 900)
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        host.layoutSubtreeIfNeeded()

        let texts = allDescendants(of: host)
            .compactMap { $0 as? NSTextField }
        XCTAssertFalse(texts.isEmpty, "질문 텍스트가 렌더링되지 않았습니다.")

        // 말풍선은 화면 폭을 다 쓰지 않고, 오른쪽으로 붙어야 한다.
        let widest = texts.map { $0.frame.width }.max() ?? 0
        XCTAssertLessThanOrEqual(
            widest,
            host.bounds.width - 80,
            "질문 말풍선이 화면 폭을 그대로 차지하면 답변과 구분되지 않습니다."
        )
        let rightmost = texts
            .map { host.convert($0.bounds, from: $0).maxX }
            .max() ?? 0
        XCTAssertGreaterThan(
            rightmost,
            host.bounds.width - 40,
            "질문 말풍선은 오른쪽 끝에 붙어야 합니다."
        )
    }

    func testShortPromptBubbleShrinksToItsContent() {
        let host = NSHostingView(
            rootView: LiveTurnPromptBlock(
                presentation: TaskPromptPresentation(prompt: "넵"),
                sentAt: Date(timeIntervalSinceReferenceDate: 60_000)
            )
            .frame(width: 900)
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        host.layoutSubtreeIfNeeded()

        let texts = allDescendants(of: host)
            .compactMap { $0 as? NSTextField }
            .filter { !($0.stringValue.isEmpty) }
        guard let prompt = texts.first(where: { $0.stringValue == "넵" })
        else {
            XCTFail("질문 텍스트를 찾지 못했습니다.")
            return
        }
        // 짧은 질문에 넓은 말풍선을 주면 오른쪽이 허전해 보인다.
        XCTAssertLessThan(
            prompt.frame.width,
            200,
            "짧은 질문은 내용 크기로 줄어야 합니다."
        )
        XCTAssertGreaterThan(
            host.convert(prompt.bounds, from: prompt).maxX,
            host.bounds.width - 60,
            "짧은 질문도 오른쪽 끝에 붙어야 합니다."
        )
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allDescendants(of: $0) }
    }
}
