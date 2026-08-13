// 임시 진단용. 커밋하지 않는다.

import AppKit
import MarkdownUI
import SwiftUI
import XCTest

@testable import OfficeGame

@MainActor
final class ZZProbeSelectionTests: XCTestCase {
    private func allViews(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allViews($0) }
    }

    private func describeFields(_ root: NSView, label: String) {
        print("=== \(label) ===")
        for view in allViews(root)
        where String(describing: type(of: view)).contains("SelectionTextField")
        {
            var chain: [String] = []
            var cls: AnyClass? = type(of: view)
            while let current = cls {
                chain.append(NSStringFromClass(current))
                cls = class_getSuperclass(current)
            }
            print("[F] \(chain.joined(separator: " -> "))")
            print("[F]   frame=\(view.frame)")
            if let field = view as? NSTextField {
                print(
                    "[F]   isSelectable=\(field.isSelectable) "
                        + "isEditable=\(field.isEditable) "
                        + "isEnabled=\(field.isEnabled) "
                        + "refuses=\(field.refusesFirstResponder) "
                        + "value=\(field.stringValue.prefix(30))"
                )
                print(
                    "[F]   cellSelectable="
                        + "\(String(describing: field.cell?.isSelectable)) "
                        + "allowsEditingTextAttributes="
                        + "\(field.allowsEditingTextAttributes)"
                )
            } else if let text = view as? NSText {
                print("[F]   NSText isSelectable=\(text.isSelectable)")
            } else {
                print("[F]   (NSTextField/NSText 아님)")
            }
            print(
                "[F]   hitTest(center)="
                    + "\(String(describing: view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY))))"
            )
        }
    }

    private func host(
        _ view: some View,
        width: CGFloat,
        height: CGFloat
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let root = NSHostingView(rootView: AnyView(view))
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        root.layoutSubtreeIfNeeded()
        return (root, window)
    }

    func testProbeFieldsForBothTrees() async throws {
        let (plainRoot, plainWindow) = host(
            VStack(alignment: .leading) {
                Text("첫 번째 문단입니다. 이 문장에서 일부만 선택되는지 봅니다.")
                Text("두 번째 문단입니다.")
            }
            .frame(width: 600, alignment: .leading)
            .textSelection(.enabled),
            width: 600,
            height: 200
        )
        try await Task.sleep(for: .milliseconds(300))
        describeFields(plainRoot, label: "PLAIN Text")
        plainWindow.contentView = nil

        let (mdRoot, mdWindow) = host(
            ConversationMarkdownView(
                source: "첫 번째 문단입니다. 이 문장에서 일부만 선택되는지 봅니다.\n\n두 번째 문단입니다."
            )
            .frame(width: 600, alignment: .leading)
            .textSelection(.enabled),
            width: 600,
            height: 200
        )
        try await Task.sleep(for: .milliseconds(400))
        describeFields(mdRoot, label: "MARKDOWN")
        mdWindow.contentView = nil
    }

    func testProbeDragSelectionWithinParagraph() async throws {
        let (root, window) = host(
            ConversationMarkdownView(
                source: "첫 번째 문단입니다. 이 문장에서 일부만 선택되는지 봅니다.\n\n두 번째 문단입니다."
            )
            .frame(width: 600, alignment: .leading)
            .textSelection(.enabled),
            width: 600,
            height: 200
        )
        try await Task.sleep(for: .milliseconds(400))

        guard
            let field = allViews(root).first(where: {
                String(describing: type(of: $0))
                    .contains("SelectionTextField")
            })
        else {
            print("[DRAG] SelectionTextField 없음")
            window.contentView = nil
            return
        }

        let startInField = NSPoint(x: 20, y: field.bounds.midY)
        let endInField = NSPoint(x: 120, y: field.bounds.midY)
        let start = field.convert(startInField, to: nil)
        let end = field.convert(endInField, to: nil)

        func event(
            _ type: NSEvent.EventType,
            at point: NSPoint
        ) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        if let down = event(.leftMouseDown, at: start) {
            window.sendEvent(down)
        }
        try await Task.sleep(for: .milliseconds(30))
        for step in 1...5 {
            let x = start.x + (end.x - start.x) * CGFloat(step) / 5
            if let drag = event(
                .leftMouseDragged,
                at: NSPoint(x: x, y: start.y)
            ) {
                window.sendEvent(drag)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let up = event(.leftMouseUp, at: end) {
            window.sendEvent(up)
        }
        try await Task.sleep(for: .milliseconds(120))

        print("[DRAG] firstResponder=\(String(describing: window.firstResponder))")
        if let textField = field as? NSTextField {
            let editor = textField.currentEditor()
            print(
                "[DRAG] currentEditor=\(String(describing: editor)) "
                    + "selectedRange="
                    + "\(String(describing: editor?.selectedRange)) "
                    + "selectedString="
                    + "\((editor?.string as NSString?)?.substring(with: editor?.selectedRange ?? NSRange(location: 0, length: 0)) ?? "-")"
            )
        }
        if let responder = window.firstResponder as? NSText {
            print(
                "[DRAG] responderSelected="
                    + "\((responder.string as NSString).substring(with: responder.selectedRange))"
            )
        }
        window.contentView = nil
    }
}
