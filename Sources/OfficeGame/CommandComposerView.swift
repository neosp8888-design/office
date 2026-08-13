// 이 파일은 흔들림 없는 다중 행 명령 입력과 전송 키 동작을 제공한다.

import AppKit
import OfficeCore
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
    let canQueueForSelectedCharacter: Bool

    var canSubmit: Bool {
        isReady
            && !isUpdatingConfiguration
            && hasSelectedCharacter
            && !isSelectedCharacterRunning
    }

    /// 응답 생성 중에는 같은 입력이 다음 턴 예약으로 넘어간다.
    var canQueue: Bool {
        isReady
            && !isUpdatingConfiguration
            && hasSelectedCharacter
            && isSelectedCharacterRunning
            && canQueueForSelectedCharacter
    }

    var acceptsInput: Bool {
        canSubmit || canQueue
    }

    func canChooseAttachments(currentCount: Int) -> Bool {
        acceptsInput && currentCount < 20
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
    let isPreparingAttachments: Bool
    let onChooseAttachments: () -> Void
    let onSubmit: (String) -> Bool

    @State private var draft = CommandEntryDraft()
    @State private var composerHeight = CommandComposerLayout.minimumHeight

    private var availability: CommandEntryAvailability {
        CommandEntryAvailability(
            isReady: director.isReadyForSubmissions,
            isUpdatingConfiguration: director.isUpdatingConfiguration,
            hasSelectedCharacter: director.selectedCharacter != nil,
            isSelectedCharacterRunning: director.isSelectedCharacterRunning,
            canQueueForSelectedCharacter:
                director.canQueueForSelectedCharacter
        )
    }

    private var submissionPrompt: String? {
        draft.submissionPrompt(
            hasAttachments: attachmentCount > 0,
            isSubmissionAllowed:
                availability.acceptsInput && !isPreparingAttachments
        )
    }

    private var attachmentSelectionIsDisabled: Bool {
        isPreparingAttachments
            || !availability.canChooseAttachments(
                currentCount: attachmentCount
            )
    }

    var body: some View {
        let canSubmit = submissionPrompt != nil

        HStack(spacing: 9) {
            Button(action: onChooseAttachments) {
                Group {
                    if isPreparingAttachments {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isPreparingAttachments ? "첨부 준비 중" : "파일 첨부"
            )
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

                Button(action: submitDraft) {
                    Image(systemName: "clock.badge.checkmark.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(
                            DashboardPalette.accent.opacity(0.82),
                            in: RoundedRectangle(
                                cornerRadius: 11,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("다음 턴에 예약")
                .help(
                    availability.canQueue
                        ? "지금 응답이 끝나면 이어서 보냅니다 · 최대 "
                            + "\(QueuedCommandQueue.maximumCount)개"
                        : "예약이 가득 찼습니다 · 최대 "
                            + "\(QueuedCommandQueue.maximumCount)개"
                )
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.42)
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

/// 예약된 다음 업무를 보여주고 취소·즉시 적용을 받는다.
struct QueuedCommandStrip: View {
    @ObservedObject var director: AgentDirector
    let character: OfficeCharacter

    private var commands: [QueuedCommand] {
        director.queuedCommands(for: character)
    }

    var body: some View {
        if !commands.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(
                    "다음 턴 예약 \(commands.count)/"
                        + "\(QueuedCommandQueue.maximumCount)"
                )
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

                ForEach(Array(commands.enumerated()), id: \.element.id) {
                    index, command in
                    chip(index: index, command: command)
                }
            }
        }
    }

    private func chip(
        index: Int,
        command: QueuedCommand
    ) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(
                    .system(size: 9.5, weight: .black, design: .rounded)
                )
                .foregroundStyle(DashboardPalette.accent)
                .frame(width: 15, height: 15)
                .background(
                    DashboardPalette.accent.opacity(0.16),
                    in: Circle()
                )

            Text(command.summary)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            if !command.attachments.isEmpty {
                Label(
                    "\(command.attachments.count)",
                    systemImage: "paperclip"
                )
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                director.applyQueuedCommandNow(
                    id: command.id,
                    for: character
                )
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(DashboardPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(command.summary) 바로 적용")
            .help("지금 작업을 중단하고 이 예약으로 다시 질문")

            Button {
                director.cancelQueuedCommand(
                    id: command.id,
                    for: character
                )
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(command.summary) 예약 취소")
            .help("예약 취소")
        }
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(
            DashboardPalette.accent.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
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
