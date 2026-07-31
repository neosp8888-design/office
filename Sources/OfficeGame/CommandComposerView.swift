// 이 파일은 흔들림 없는 다중 행 명령 입력과 전송 키 동작을 제공한다.

import AppKit
import SwiftUI

struct CommandComposerView: NSViewRepresentable {
    @Binding var text: String
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
        textView.minSize = NSSize(width: 0, height: 40)
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
        updateTextView(textView)
    }

    private func updateTextView(_ textView: CommandComposerTextView) {
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textColor = isEnabled
            ? .labelColor
            : .disabledControlTextColor

        guard textView.string != text else {
            return
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
            textView.needsDisplay = true
            guard parent.text != textView.string else {
                return
            }
            parent.text = textView.string
        }
    }
}

private final class CommandComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            needsDisplay = true
        }
    }
    var onSubmit: (() -> Void)?

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
