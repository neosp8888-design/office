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
            rootView: LiveTurnPromptBlock(presentation: presentation)
                .frame(width: 520)
        )
        return controller.sizeThatFits(
            in: NSSize(width: 520, height: proposedHeight)
        ).height
    }
}
