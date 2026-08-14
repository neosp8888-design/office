// 이 파일은 명령 입력 초안의 전송 가능 여부와 초기화 규칙을 검증한다.

import AppKit
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class CommandEntryDraftTests: XCTestCase {
    func testAvailabilityAllowsReadyIdleSelectedCharacter() {
        let availability = CommandEntryAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: false,
            canQueueForSelectedCharacter: false
        )

        XCTAssertTrue(availability.canSubmit)
        XCTAssertTrue(availability.canChooseAttachments(currentCount: 19))
        XCTAssertFalse(availability.canChooseAttachments(currentCount: 20))
    }

    func testAvailabilityRejectsEveryBlockedState() {
        let blockedStates = [
            CommandEntryAvailability(
                isReady: false,
                isUpdatingConfiguration: false,
                hasSelectedCharacter: true,
                isSelectedCharacterRunning: false,
                canQueueForSelectedCharacter: false
            ),
            CommandEntryAvailability(
                isReady: true,
                isUpdatingConfiguration: true,
                hasSelectedCharacter: true,
                isSelectedCharacterRunning: false,
                canQueueForSelectedCharacter: false
            ),
            CommandEntryAvailability(
                isReady: true,
                isUpdatingConfiguration: false,
                hasSelectedCharacter: false,
                isSelectedCharacterRunning: false,
                canQueueForSelectedCharacter: false
            ),
            CommandEntryAvailability(
                isReady: true,
                isUpdatingConfiguration: false,
                hasSelectedCharacter: true,
                isSelectedCharacterRunning: true,
                canQueueForSelectedCharacter: false
            ),
        ]

        for availability in blockedStates {
            XCTAssertFalse(availability.canSubmit)
            XCTAssertFalse(availability.canQueue)
            XCTAssertFalse(
                availability.canChooseAttachments(currentCount: 0)
            )
        }
    }

    func testRunningCharacterAcceptsInputAsQueuedReservation() {
        let availability = CommandEntryAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: true,
            canQueueForSelectedCharacter: true
        )

        XCTAssertFalse(
            availability.canSubmit,
            "응답 생성 중에는 즉시 제출이 아니라 예약이어야 합니다."
        )
        XCTAssertTrue(availability.canQueue)
        XCTAssertTrue(availability.acceptsInput)
        XCTAssertTrue(
            availability.canChooseAttachments(currentCount: 0),
            "예약에도 첨부를 실을 수 있어야 합니다."
        )
    }

    func testFullQueueStopsAcceptingMoreInputWhileRunning() {
        let availability = CommandEntryAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: true,
            canQueueForSelectedCharacter: false
        )

        XCTAssertFalse(availability.canQueue)
        XCTAssertFalse(availability.acceptsInput)
        XCTAssertFalse(
            availability.canChooseAttachments(currentCount: 0)
        )
    }

    func testEmptyDraftWithoutAttachmentsCannotSubmit() {
        let draft = CommandEntryDraft(text: "  \n ")

        XCTAssertNil(
            draft.submissionPrompt(
                hasAttachments: false,
                isSubmissionAllowed: true
            )
        )
    }

    func testAttachmentOnlyDraftUsesDefaultPrompt() {
        let draft = CommandEntryDraft(text: " \n ")

        XCTAssertEqual(
            draft.submissionPrompt(
                hasAttachments: true,
                isSubmissionAllowed: true
            ),
            "첨부 파일을 확인해줘."
        )
    }

    func testDraftTrimsPromptBeforeSubmission() {
        let draft = CommandEntryDraft(text: "  업무를 확인해줘. \n")

        XCTAssertEqual(
            draft.submissionPrompt(
                hasAttachments: false,
                isSubmissionAllowed: true
            ),
            "업무를 확인해줘."
        )
    }

    func testUnavailableDraftDoesNotSubmit() {
        let draft = CommandEntryDraft(text: "업무")

        XCTAssertNil(
            draft.submissionPrompt(
                hasAttachments: true,
                isSubmissionAllowed: false
            )
        )
    }

    func testDraftClearsOnlyAfterAcceptedSubmission() {
        var draft = CommandEntryDraft(text: "업무")

        draft.clearAfterSubmission(accepted: false)
        XCTAssertEqual(draft.text, "업무")

        draft.clearAfterSubmission(accepted: true)
        XCTAssertEqual(draft.text, "")
    }

    func testTypingWithinNonemptyDraftDoesNotRequestRedraw() {
        let (coordinator, textBox) = makeCoordinator(initialText: "업")
        let textView = TrackingTextView()
        textView.string = "업무"
        textView.resetDisplayRequestCount()

        coordinator.textDidChange(
            Notification(
                name: NSText.didChangeNotification,
                object: textView
            )
        )

        XCTAssertEqual(textBox.value, "업무")
        XCTAssertEqual(textView.displayRequestCount, 0)
    }

    func testPlaceholderVisibilityChangesRequestRedraw() {
        for (oldValue, newValue) in [("", "업무"), ("업무", "")] {
            let (coordinator, textBox) = makeCoordinator(
                initialText: oldValue
            )
            let textView = TrackingTextView()
            textView.string = newValue
            textView.resetDisplayRequestCount()

            coordinator.textDidChange(
                Notification(
                    name: NSText.didChangeNotification,
                    object: textView
                )
            )

            XCTAssertEqual(textBox.value, newValue)
            XCTAssertEqual(textView.displayRequestCount, 1)
        }
    }

    func testSwiftUIUpdatePreservesMarkedKoreanComposition() {
        let textBox = TextBox(value: "")
        let composer = makeComposer(textBox: textBox)
        let textView = CommandComposerTextView()
        textView.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertFalse(composer.updateTextView(textView))
        XCTAssertEqual(textView.string, "한")
        XCTAssertTrue(
            textView.hasMarkedText(),
            "SwiftUI의 이전 draft가 한글 조합을 취소하면 안 됩니다."
        )
    }

    func testReturnSubmitsWithoutInsertingNewline() throws {
        let textView = CommandComposerTextView()
        textView.string = "업무"
        var submittedText: String?
        textView.onSubmit = { submittedText = $0 }

        textView.keyDown(with: try makeReturnEvent())

        XCTAssertEqual(submittedText, "업무")
        XCTAssertEqual(textView.string, "업무")
    }

    func testReturnCommitsMarkedKoreanTextAndSubmits() async throws {
        let textView = CommandComposerTextView()
        textView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        var submittedText: String?
        let didSubmit = expectation(description: "조합 완료 뒤 전송")
        textView.onSubmit = {
            submittedText = $0
            didSubmit.fulfill()
        }

        textView.keyDown(with: try makeReturnEvent())

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertNil(
            submittedText,
            "한글 조합 완료 이벤트보다 전송이 먼저 실행되면 안 됩니다."
        )
        await fulfillment(of: [didSubmit], timeout: 1)
        XCTAssertEqual(submittedText, "한글")
        XCTAssertEqual(textView.string, "한글")
    }

    func testLateKoreanCompositionChangeCannotRestoreSubmittedFinalSyllable()
        async throws
    {
        let textBox = TextBox(value: "요청")
        let didSubmit = expectation(description: "마지막 음절 확정 뒤 전송")
        let composer = makeComposer(textBox: textBox) {
            textBox.value = ""
            didSubmit.fulfill()
        }
        let coordinator = composer.makeCoordinator()
        let textView = CommandComposerTextView()
        textView.delegate = coordinator
        textView.string = "요청"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.setMarkedText(
            "됨",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        _ = composer.updateTextView(textView)

        textView.keyDown(with: try makeReturnEvent())
        coordinator.textDidChange(
            Notification(
                name: NSText.didChangeNotification,
                object: textView
            )
        )

        XCTAssertEqual(textBox.value, "요청됨")
        await fulfillment(of: [didSubmit], timeout: 1)
        XCTAssertEqual(
            textBox.value,
            "",
            "늦은 IME 변경이 전송 뒤 마지막 음절을 초안에 복원했습니다."
        )
    }

    func testShiftReturnIsTheOnlyReturnThatInsertsNewline() throws {
        let textView = CommandComposerTextView()
        textView.string = "업무"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        var submittedText: String?
        textView.onSubmit = { submittedText = $0 }

        textView.keyDown(with: try makeReturnEvent(modifiers: [.shift]))

        XCTAssertNil(submittedText)
        XCTAssertEqual(textView.string, "업무\n")
    }

    func testComposerHeightGrowsAfterTrailingNewlineAndCapsAtMaximum() {
        let textView = makeComposerTextView()

        textView.string = "첫째 줄"
        let singleLineHeight = CommandComposerLayout.measuredHeight(
            for: textView
        )

        textView.string = "첫째 줄\n"
        let twoLineHeight = CommandComposerLayout.measuredHeight(
            for: textView
        )

        textView.string = Array(repeating: "여러 줄", count: 30)
            .joined(separator: "\n")
        let cappedHeight = CommandComposerLayout.measuredHeight(for: textView)

        XCTAssertEqual(
            singleLineHeight,
            CommandComposerLayout.minimumHeight
        )
        XCTAssertGreaterThan(twoLineHeight, singleLineHeight)
        XCTAssertEqual(cappedHeight, CommandComposerLayout.maximumHeight)
    }

    private func makeCoordinator(
        initialText: String
    ) -> (CommandComposerView.Coordinator, TextBox) {
        let textBox = TextBox(value: initialText)
        let composer = makeComposer(textBox: textBox)
        return (composer.makeCoordinator(), textBox)
    }

    private func makeComposer(
        textBox: TextBox,
        onSubmit: @escaping () -> Void = {}
    ) -> CommandComposerView {
        CommandComposerView(
            text: Binding(
                get: { textBox.value },
                set: { textBox.value = $0 }
            ),
            measuredHeight: .constant(CommandComposerLayout.minimumHeight),
            placeholder: "업무를 입력하세요",
            isEnabled: true,
            onSubmit: onSubmit
        )
    }

    private func makeReturnEvent(
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
    }

    private func makeComposerTextView() -> NSTextView {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 40)
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.font = .systemFont(ofSize: 14, weight: .medium)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 400,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 12)
        return textView
    }
}

private final class TextBox {
    var value: String

    init(value: String) {
        self.value = value
    }
}

private final class TrackingTextView: NSTextView {
    private(set) var displayRequestCount = 0

    override var needsDisplay: Bool {
        get {
            super.needsDisplay
        }
        set {
            if newValue {
                displayRequestCount += 1
            }
            super.needsDisplay = newValue
        }
    }

    func resetDisplayRequestCount() {
        displayRequestCount = 0
    }
}
