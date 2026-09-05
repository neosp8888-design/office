import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ConversationPointerWorkloadTests: XCTestCase {
    func testPointerRoutingAcrossConversationCards() async throws {
        let host = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<12) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Response \(index)").font(.headline)
                        ConversationMarkdownView(source: """
                        This is a **selectable paragraph** with a [link](https://example.com).

                        | Item | Tokens | Cost |
                        | --- | ---: | ---: |
                        | Input | 118,672 | $1.18 |
                        | Output | 224 | $0.01 |

                        Another selectable paragraph after the table.
                        """)
                        Button("Copy") {}
                            .buttonStyle(.plain)
                            .help("Copy response")
                    }
                    .padding(14)
                    .conversationTextSelectionRegion("pointer-card-\(index)")
                }
            }
            .padding(16)
        }.frame(width: 900, height: 700))
        let window = NSWindow(
            contentRect: NSRect(x: -6_000, y: -6_000, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let documents = descendants(of: host).compactMap { $0 as? SelectableMarkdownDocumentView }
        XCTAssertEqual(documents.count, 12)
        let createdBefore = SelectableMarkdownDocumentView.createdCount
        let measuredBefore = documents.reduce(0) { $0 + $1.textLayoutMeasurementCount }
        // 같은 1초/1000개 입력 좌표를 무제한 경로와 운영 coalescer에 넣는다.
        // 가상 시계는 재현을 일정하게 하고 실제 hit-test/hover 비용을 비교한다.
        func measure(coalescing: Bool) throws -> (cpu: Double, routed: Int) {
            var time = 0.0
            var routed = 0
            let route: (NSEvent) -> Void = { event in
                if host.hitTest(event.locationInWindow) != nil { routed += 1 }
                host.mouseMoved(with: event)
            }
            let coalescer = ConversationPointerMoveCoalescer(now: { time }, deliver: route)
            defer { coalescer.cancel() }
            let cpuBefore = cpuSeconds()
            for index in 0..<1_000 {
                time = Double(index) / 1_000
                let point = NSPoint(x: 40 + index * 37 % 800, y: 20 + index * 23 % 650)
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: time, windowNumber: window.windowNumber, context: nil,
                    eventNumber: index, clickCount: 0, pressure: 0
                ))
                if !coalescing || coalescer.process(event, isInsideConversation: true) != nil {
                    route(event)
                }
            }
            time += ConversationPointerMoveCoalescer.frameInterval
            coalescer.flush()
            return (cpuSeconds() - cpuBefore, routed)
        }
        let raw = try measure(coalescing: false)
        let coalesced = try measure(coalescing: true)
        print("[pointer-routing] events=1000 raw CPU-seconds=\(raw.cpu) hits=\(raw.routed); coalesced CPU-seconds=\(coalesced.cpu) hits=\(coalesced.routed); new-documents=\(SelectableMarkdownDocumentView.createdCount - createdBefore)")
        XCTAssertEqual(raw.routed, 1_000)
        XCTAssertLessThanOrEqual(coalesced.routed, 61)
        XCTAssertLessThan(coalesced.cpu, raw.cpu * 0.5)
        XCTAssertEqual(SelectableMarkdownDocumentView.createdCount, createdBefore)
        XCTAssertEqual(documents.reduce(0) { $0 + $1.textLayoutMeasurementCount }, measuredBefore)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
