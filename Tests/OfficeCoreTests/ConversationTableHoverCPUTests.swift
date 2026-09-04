// 표가 든 대화 카드 위에서 커서를 움직일 때 무엇이 반복 실행되는지 재현·측정한다.

import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ConversationTableHoverCPUTests: XCTestCase {
    private static let regionID = "table-hover-measure"

    // 사용자 재현과 같은 구성이다. 본문 사이에 폭이 넓고 긴 표가 있어
    // 표 세그먼트는 가로 뷰포트 안에 들어간다.
    private static let tableSource: String = {
        let header = "| 항목 | 상태 | 담당 | 시작 | 종료 | 비고 |"
        let delimiter = "| --- | --- | --- | --- | --- | --- |"
        let rows = (0..<30).map { index in
            "| 작업 \(index) | 진행 | 직원 \(index % 5) | 09:\(String(format: "%02d", index)) | 10:\(String(format: "%02d", index)) | 표 위에서 커서를 움직이는 재현용 행 |"
        }
        return """
        표 위 문단입니다. 커서가 위아래로 지나갑니다.

        \(([header, delimiter] + rows).joined(separator: "\n"))

        표 아래 문단입니다. 선택과 복사는 그대로 동작해야 합니다.
        """
    }()

    private static let proseSource = String(
        repeating: "표가 없는 대조용 본문 문단입니다. 같은 이벤트를 넣습니다.\n\n",
        count: 40
    )

    private struct Measurement {
        var cpu = 0.0
        var created = 0
        var layoutPasses = 0
        var heightRequests = 0
        var textMeasurements = 0
        var publishes = 0
        var events = 0

        var description: String {
            "cpu=\(String(format: "%.3f", cpu)) created=\(created) "
                + "layoutPasses=\(layoutPasses) heightRequests=\(heightRequests) "
                + "textMeasurements=\(textMeasurements) publishes=\(publishes) "
                + "events=\(events)"
        }
    }

    private final class Host {
        let window: NSWindow
        let host: NSHostingView<AnyView>

        init(source: String, regionID: String) {
            host = NSHostingView(
                rootView: AnyView(
                    ConversationMarkdownView(source: source)
                        .conversationTextSelectionRegion(regionID)
                        .frame(width: 720)
                )
            )
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 1_400)
            window = NSWindow(
                contentRect: NSRect(x: -6_000, y: -6_000, width: 720, height: 1_400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.acceptsMouseMovedEvents = true
            window.contentView = host
        }

        func tearDown() {
            window.contentView = nil
        }
    }

    // 1. 커서가 카드에 들어왔다 나가기를 반복할 때 표 뷰가 다시 만들어지는지.
    //    뷰가 새로 만들어지면 화면에서는 표가 깜빡인다.
    // 2. 선택이 켜진 상태에서 표 위를 오르내리는 mouseMoved가 무엇을 반복시키는지.
    // 3. 선택이 꺼진 상태의 같은 이동(대조).
    // 4. 표 없는 본문 카드의 같은 이동(대조).
    func testMeasureTableHoverWorkload() async throws {
        let coordinator = ConversationTextSelectionCoordinator.shared
        coordinator.reset()
        defer { coordinator.reset() }

        let tableHost = Host(source: Self.tableSource, regionID: Self.regionID)
        defer { tableHost.tearDown() }
        tableHost.host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))

        let hoverFlap = try await measureHoverFlap(
            in: tableHost,
            regionID: Self.regionID,
            cycles: 60,
            samplePath: "/tmp/hovermeasure/table-hover-flap-sample.txt"
        )
        print("[table-hover] 1.hover 진입/이탈 60회: \(hoverFlap.description)")
        // 수정 전에는 전환마다 표 전체를 다시 조판·그려 코어 하나를 가득
        // 썼다(약 0.96). 스택을 이어받은 뒤 약 0.26이다.
        XCTAssertLessThan(
            hoverFlap.cpu,
            0.5,
            "hover 진입·이탈 반복에 CPU를 \(Int(hoverFlap.cpu * 100))% 씁니다. "
                + "전환마다 표를 다시 조판·그릴 때의 수치입니다."
        )

        coordinator.activate(Self.regionID)
        tableHost.host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))
        let activeStorm = try await measureMouseMovedStorm(
            in: tableHost,
            events: 300,
            samplePath: "/tmp/hovermeasure/table-active-sample.txt"
        )
        print("[table-hover] 2.선택 켜짐 + 표 위 mouseMoved 300회: \(activeStorm.description)")

        coordinator.deactivate(Self.regionID)
        tableHost.host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))
        let inactiveStorm = try await measureMouseMovedStorm(
            in: tableHost,
            events: 300,
            samplePath: nil
        )
        print("[table-hover] 3.선택 꺼짐 + 표 위 mouseMoved 300회: \(inactiveStorm.description)")

        coordinator.reset()
        let proseHost = Host(source: Self.proseSource, regionID: "prose-hover-measure")
        defer { proseHost.tearDown() }
        proseHost.host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))
        coordinator.activate("prose-hover-measure")
        proseHost.host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))
        let proseStorm = try await measureMouseMovedStorm(
            in: proseHost,
            events: 300,
            samplePath: nil
        )
        print("[table-hover] 4.본문만 + 선택 켜짐 + mouseMoved 300회: \(proseStorm.description)")

        XCTAssertEqual(activeStorm.events, 300)
        XCTAssertEqual(inactiveStorm.events, 300)
    }

    private func measureHoverFlap(
        in host: Host,
        regionID: String,
        cycles: Int,
        samplePath: String? = nil
    ) async throws -> Measurement {
        let coordinator = ConversationTextSelectionCoordinator.shared
        var result = Measurement()
        var publishes = 0
        let observation = coordinator.objectWillChange.sink { publishes += 1 }
        defer { observation.cancel() }
        let createdBefore = SelectableMarkdownDocumentView.createdCount
        let tableViewBefore = tableDocumentView(in: host.host)

        var sampler: Process?
        if let samplePath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(getpid()), "3", "-file", samplePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            sampler = process
        }
        defer { sampler?.waitUntilExit() }

        result.cpu = try await measureCPUUtilization {
            for _ in 0..<cycles {
                coordinator.handleHover(true, in: regionID)
                host.host.layoutSubtreeIfNeeded()
                try await settle(for: .milliseconds(25))
                coordinator.handleHover(false, in: regionID)
                host.host.layoutSubtreeIfNeeded()
                try await settle(for: .milliseconds(25))
            }
        }
        result.created = SelectableMarkdownDocumentView.createdCount - createdBefore
        result.publishes = publishes
        result.events = cycles * 2
        let tableViewAfter = tableDocumentView(in: host.host)
        if let before = tableViewBefore, let after = tableViewAfter {
            print(
                "[table-hover] 표 뷰 동일 인스턴스 유지 여부: \(before === after), "
                    + "NSTextView 스택 유지 여부: \(before.textView === after.textView), "
                    + "스택 재사용 횟수: \(after.textStackReuseCount)"
            )
            XCTAssertTrue(
                before.textView === after.textView,
                "hover 전환 뒤 표의 NSTextView가 다시 만들어졌습니다. "
                    + "표 전체를 다시 조판·그리게 되어 깜빡임과 CPU 급등이 납니다."
            )
        }
        return result
    }

    private func measureMouseMovedStorm(
        in host: Host,
        events: Int,
        samplePath: String?
    ) async throws -> Measurement {
        let coordinator = ConversationTextSelectionCoordinator.shared
        var result = Measurement()
        var publishes = 0
        let observation = coordinator.objectWillChange.sink { publishes += 1 }
        defer { observation.cancel() }

        guard let target = tableDocumentView(in: host.host)
            ?? allDescendants(of: host.host)
                .compactMap({ $0 as? SelectableMarkdownDocumentView })
                .first
        else {
            XCTFail("측정할 문서 뷰를 찾지 못했습니다.")
            return result
        }
        let frameInWindow = target.convert(target.bounds, to: nil)
        let createdBefore = SelectableMarkdownDocumentView.createdCount
        let layoutBefore = target.layoutPassCount
        let heightBefore = target.heightRequestCount
        let measureBefore = target.textLayoutMeasurementCount

        var sampler: Process?
        if let samplePath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(getpid()), "3", "-file", samplePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            sampler = process
        }

        result.cpu = try await measureCPUUtilization {
            let top = frameInWindow.minY + 4
            let bottom = frameInWindow.maxY - 4
            let x = frameInWindow.midX
            var y = top
            var direction: CGFloat = 1
            let step = max(2, (bottom - top) / 40)
            for index in 0..<events {
                y += direction * step
                if y >= bottom { y = bottom; direction = -1 }
                if y <= top { y = top; direction = 1 }
                if let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: NSPoint(x: x, y: y),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: host.window.windowNumber,
                    context: nil,
                    eventNumber: index,
                    clickCount: 0,
                    pressure: 0
                ) {
                    host.window.sendEvent(event)
                    result.events += 1
                }
                host.host.layoutSubtreeIfNeeded()
                // 실제 커서는 초당 약 100회 이벤트를 만든다.
                try await settle(for: .milliseconds(10))
            }
        }
        sampler?.waitUntilExit()

        result.created = SelectableMarkdownDocumentView.createdCount - createdBefore
        result.layoutPasses = target.layoutPassCount - layoutBefore
        result.heightRequests = target.heightRequestCount - heightBefore
        result.textMeasurements = target.textLayoutMeasurementCount - measureBefore
        result.publishes = publishes
        return result
    }

    private func tableDocumentView(in root: NSView) -> SelectableMarkdownDocumentView? {
        allDescendants(of: root)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
            .first { view in
                view.subviews.contains { $0 is NSClipView }
            }
    }

    private func measureCPUUtilization(
        _ body: () async throws -> Void
    ) async rethrows -> Double {
        let clock = ContinuousClock()
        let startedCPU = processCPUSeconds()
        let startedAt = clock.now
        try await body()
        let elapsed = startedAt.duration(to: clock.now)
        let wallSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard wallSeconds > 0 else { return 0 }
        return (processCPUSeconds() - startedCPU) / wallSeconds
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private func settle(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
        await Task.yield()
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + allDescendants(of: subview)
        }
    }
}
