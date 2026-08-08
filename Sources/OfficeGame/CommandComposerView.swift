// 이 파일은 흔들림 없는 다중 행 명령 입력과 전송 키 동작을 제공한다.

import AppKit
import SwiftUI

struct CommandEntryDraft: Equatable {
    var text = ""

    func submissionPrompt(
        hasAttachments: Bool,
        isSubmissionAllowed: Bool
    ) -> String? {
        guard isSubmissionAllowed else {
            return nil
        }
        let enteredPrompt = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !enteredPrompt.isEmpty || hasAttachments else {
            return nil
        }
        return enteredPrompt.isEmpty
            ? "첨부 파일을 확인해줘."
            : enteredPrompt
    }

    mutating func clearAfterSubmission(accepted: Bool) {
        if accepted {
            text = ""
        }
    }
}

struct CommandEntryAvailability: Equatable {
    let isReady: Bool
    let isUpdatingConfiguration: Bool
    let hasSelectedCharacter: Bool
    let isSelectedCharacterRunning: Bool

    var canSubmit: Bool {
        isReady
            && !isUpdatingConfiguration
            && hasSelectedCharacter
            && !isSelectedCharacterRunning
    }

    func canChooseAttachments(currentCount: Int) -> Bool {
        canSubmit && currentCount < 20
    }
}

enum CommandComposerLayout {
    static let minimumHeight: CGFloat = 40
    static let maximumHeight: CGFloat = 160

    static func measuredHeight(for textView: NSTextView) -> CGFloat {
        guard
            !textView.string.isEmpty,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return minimumHeight
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        var lineHeight: CGFloat = 0
        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { lineRect, _, _, _, _ in
            lineCount += 1
            lineHeight = max(lineHeight, ceil(lineRect.height))
        }
        if textView.string.hasSuffix("\n") {
            lineCount += 1
            lineHeight = max(
                lineHeight,
                ceil(layoutManager.extraLineFragmentRect.height)
            )
        }
        let additionalLineHeight = CGFloat(max(0, lineCount - 1))
            * lineHeight
        return min(
            minimumHeight + additionalLineHeight,
            maximumHeight
        )
    }
}

struct CommandEntryRow: View {
    @ObservedObject var director: AgentDirector
    let placeholder: String
    let attachmentCount: Int
    let onChooseAttachments: () -> Void
    let onSubmit: (String) -> Bool

    @State private var draft = CommandEntryDraft()
    @State private var composerHeight = CommandComposerLayout.minimumHeight

    private var availability: CommandEntryAvailability {
        CommandEntryAvailability(
            isReady: director.isReadyForSubmissions,
            isUpdatingConfiguration: director.isUpdatingConfiguration,
            hasSelectedCharacter: director.selectedCharacter != nil,
            isSelectedCharacterRunning: director.isSelectedCharacterRunning
        )
    }

    private var submissionPrompt: String? {
        draft.submissionPrompt(
            hasAttachments: attachmentCount > 0,
            isSubmissionAllowed: availability.canSubmit
        )
    }

    private var attachmentSelectionIsDisabled: Bool {
        !availability.canChooseAttachments(currentCount: attachmentCount)
    }

    var body: some View {
        let canSubmit = submissionPrompt != nil

        HStack(spacing: 9) {
            Button(action: onChooseAttachments) {
                Image(systemName: "paperclip")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("파일 첨부")
            .help("파일 첨부 · 한 번에 최대 20개")
            .disabled(attachmentSelectionIsDisabled)
            .opacity(attachmentSelectionIsDisabled ? 0.42 : 1)

            CommandComposerView(
                text: $draft.text,
                measuredHeight: $composerHeight,
                placeholder: placeholder,
                isEnabled:
                    director.isReadyForSubmissions
                        && !director.isUpdatingConfiguration,
                onSubmit: submitDraft
            )
            .frame(height: composerHeight)

            if director.isSelectedCharacterRunning {
                Button(action: director.cancelSelectedJob) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            Color.red.opacity(0.88),
                            in: RoundedRectangle(
                                cornerRadius: 11,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("대화 중단")
                .help("현재 직원의 업무 중단")
                .disabled(director.isCancellingSelectedCharacter)
                .opacity(
                    director.isCancellingSelectedCharacter ? 0.42 : 1
                )
            } else {
                Button(action: submitDraft) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            DashboardPalette.accent,
                            in: RoundedRectangle(
                                cornerRadius: 11,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("보내기")
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.42)
            }
        }
        // 양끝이 같은 32pt 버튼이라 좌우 여백을 맞춘다.
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
    }

    private func submitDraft() {
        guard let submissionPrompt else {
            return
        }
        let accepted = onSubmit(submissionPrompt)
        draft.clearAfterSubmission(accepted: accepted)
    }
}

struct CommandComposerView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CommandComposerTextView()
        textView.delegate = context.coordinator
        textView.onMeasuredHeightChange = context.coordinator.updateMeasuredHeight
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(
            origin: .zero,
            size: scrollView.contentSize
        )
        textView.minSize = NSSize(
            width: 0,
            height: CommandComposerLayout.minimumHeight
        )
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.font = .systemFont(ofSize: 14, weight: .medium)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel("업무 입력")
        scrollView.documentView = textView

        updateTextView(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CommandComposerTextView
        else {
            return
        }
        let textChanged = updateTextView(textView)
        if textChanged {
            DispatchQueue.main.async { [weak textView] in
                textView?.reportMeasuredHeight()
            }
        }
    }

    @discardableResult
    private func updateTextView(_ textView: CommandComposerTextView) -> Bool {
        textView.onSubmit = onSubmit
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }
        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        let desiredTextColor: NSColor = isEnabled
            ? .labelColor
            : .disabledControlTextColor
        if textView.textColor != desiredTextColor {
            textView.textColor = desiredTextColor
        }

        guard textView.string != text else {
            return false
        }
        let previousLocation = textView.selectedRange().location
        textView.string = text
        textView.setSelectedRange(
            NSRange(
                location: min(previousLocation, (text as NSString).length),
                length: 0
            )
        )
        textView.needsDisplay = true
        if text.isEmpty {
            textView.scrollToBeginningOfDocument(nil)
        }
        return true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandComposerView

        init(parent: CommandComposerView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            (textView as? CommandComposerTextView)?.reportMeasuredHeight()
            guard parent.text != textView.string else {
                return
            }
            let changesPlaceholderVisibility =
                parent.text.isEmpty != textView.string.isEmpty
            parent.text = textView.string
            if changesPlaceholderVisibility {
                textView.needsDisplay = true
            }
        }

        func updateMeasuredHeight(_ newHeight: CGFloat) {
            guard abs(parent.measuredHeight - newHeight) >= 0.5 else {
                return
            }
            parent.measuredHeight = newHeight
        }
    }
}

private final class CommandComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            if placeholder != oldValue {
                needsDisplay = true
            }
        }
    }
    var onSubmit: (() -> Void)?
    var onMeasuredHeightChange: ((CGFloat) -> Void)?

    func reportMeasuredHeight() {
        onMeasuredHeightChange?(
            CommandComposerLayout.measuredHeight(for: self)
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else {
            super.keyDown(with: event)
            return
        }

        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift) {
            insertNewline(nil)
        } else {
            onSubmit?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: 0, y: textContainerInset.height),
            withAttributes: attributes
        )
    }
}
