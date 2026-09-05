// 보관함 시트의 응답 페이지를 스크롤할 때 무엇이 반복 실행되는지 재현·측정한다.

import AppKit
import Combine
import Darwin
import OfficeCore
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ArchiveBookScrollCPUTests: XCTestCase {
    private struct Measurement {
        var cpu = 0.0
        var created = 0
        var layoutPasses = 0
        var heightRequests = 0
        var textMeasurements = 0
        var publishes = 0
        var events = 0
        var scrolledBy = CGFloat.zero

        var description: String {
            "cpu=\(String(format: "%.3f", cpu)) created=\(created) "
                + "layoutPasses=\(layoutPasses) heightRequests=\(heightRequests) "
                + "textMeasurements=\(textMeasurements) publishes=\(publishes) "
                + "events=\(events) scrolledBy=\(Int(scrolledBy))"
        }
    }

    // 실제 기록과 비슷하게 본문·목록·표·코드 블록이 섞인 긴 응답이다.
    private static let response: String = {
        let table = (["| 항목 | 상태 | 담당 | 비고 |", "| --- | --- | --- | --- |"]
            + (0..<12).map { "| 작업 \($0) | 진행 | 직원 \($0 % 5) | 시트 스크롤 재현용 행 |" })
            .joined(separator: "\n")
        let code = """
        ```swift
        struct Example {
            let value: Int
            func doubled() -> Int { value * 2 }
        }
        ```
        """
        return (0..<10).map { index in
            """
            ### 절 \(index)

            드래그로 선택해 복사할 수 있어야 하는 **본문 문단**입니다. 시트에서 \
            스크롤할 때 이 문단이 다시 조판되면 안 됩니다.

            - 첫 번째 항목 \(index)
            - 두 번째 항목 \(index)

            \(index % 3 == 0 ? table : "")

            \(index % 4 == 1 ? code : "")
            """
        }.joined(separator: "\n\n")
    }()

    // ARCHIVE_SCROLL_SOURCE에 파일 경로를 주면 실제 기록의 응답으로 잰다.
    private static var responseSource: String {
        if
            let path = ProcessInfo.processInfo.environment["ARCHIVE_SCROLL_SOURCE"],
            let text = try? String(contentsOfFile: path, encoding: .utf8),
            !text.isEmpty
        {
            return text
        }
        return response
    }

    func testMeasureArchiveBookScrollWorkload() async throws {
        let coordinator = ConversationTextSelectionCoordinator.shared
        coordinator.reset()
        defer { coordinator.reset() }

        let turn = makeTurn()
        print("[archive-scroll] 응답 길이 \(turn.response.count)자")
        let host = NSHostingView(
            rootView: AnyView(
                ArchiveOpenBook(
                    turn: turn,
                    navigation: ArchiveBookNavigation(
                        index: 0,
                        total: 1,
                        canGoPrevious: false,
                        canGoNext: false
                    ),
                    onPrevious: {},
                    onNext: {},
                    onClose: {}
                )
                .frame(width: 1_160, height: 760)
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 1_160, height: 760)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(250))

        let scrollViews = allDescendants(of: host).compactMap { $0 as? NSScrollView }
        for scrollView in scrollViews {
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            print(
                "[archive-scroll] scrollView frame=\(Int(frame.minX)),\(Int(frame.minY)) "
                    + "\(Int(frame.width))x\(Int(frame.height)) "
                    + "document=\(Int(scrollView.documentView?.bounds.height ?? 0))"
            )
        }
        guard let firstResponseScroll = responseScrollView(in: host) else {
            XCTFail("응답 페이지 scroll view를 찾지 못했습니다.")
            return
        }
        let documentViews = allDescendants(of: host)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
        print("[archive-scroll] 문서 뷰 \(documentViews.count)개")

        let inactive = try await measureScrollStorm(
            host: host,
            scrollView: firstResponseScroll,
            events: 160,
            samplePath: "/tmp/archivescroll/inactive-sample.txt"
        )
        print("[archive-scroll] 1.기본 상태 + 휠 160회: \(inactive.description)")

        // 다른 대화의 선택 coordinator가 바뀌어도 팝업의 뷰는 그대로여야 한다.
        coordinator.activate("archive-book-\(turn.id)")
        host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(200))
        guard let activeResponseScroll = responseScrollView(in: host) else {
            XCTFail("선택이 켜진 뒤 응답 페이지 scroll view를 찾지 못했습니다.")
            return
        }
        print(
            "[archive-scroll] 공용 선택 변경 뒤 같은 scroll view 인스턴스: "
                + "\(activeResponseScroll === firstResponseScroll)"
        )
        XCTAssertTrue(activeResponseScroll === firstResponseScroll)
        let active = try await measureScrollStorm(
            host: host,
            scrollView: activeResponseScroll,
            events: 160,
            samplePath: "/tmp/archivescroll/active-sample.txt"
        )
        print("[archive-scroll] 2.공용 선택 변경 + 휠 160회: \(active.description)")

        // 화면에 올라간 창만 실제로 그린다. 창을 화면 오른쪽 아래 구석에
        // 거의 다 가려지게 두어 사용자 눈에 띄지 않게 하면서 그리기 비용을 잰다.
        if let screen = NSScreen.main {
            window.setFrameOrigin(
                NSPoint(
                    x: screen.frame.maxX - 24,
                    y: screen.frame.minY - 740
                )
            )
        }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(300))
        defer { window.orderOut(nil) }
        if let onscreenScroll = responseScrollView(in: host) {
            let onscreen = try await measureScrollStorm(
                host: host,
                scrollView: onscreenScroll,
                events: 160,
                samplePath: "/tmp/archivescroll/onscreen-sample.txt"
            )
            print("[archive-scroll] 4.화면에 올린 창 + 선택 켜짐 + 휠 160회: \(onscreen.description)")
            let onscreenIdle = try await measureCPUUtilization {
                try await settle(for: .milliseconds(600))
            }
            print("[archive-scroll] 5.화면 창 스크롤 뒤 유휴 600ms: cpu=\(String(format: "%.3f", onscreenIdle))")

            // 트랙패드처럼 시작·진행·종료 단계와 관성 단계를 붙인 이벤트다.
            // 반응형 스크롤의 미리 그리기가 여기서만 켜진다.
            let trackpad = try await measureScrollStorm(
                host: host,
                scrollView: onscreenScroll,
                events: 160,
                samplePath: "/tmp/archivescroll/trackpad-sample.txt",
                usesTrackpadPhases: true
            )
            print("[archive-scroll] 6.화면 창 + 트랙패드 단계 160회: \(trackpad.description)")
            let trackpadIdle = try await measureCPUUtilization {
                try await settle(for: .milliseconds(600))
            }
            print("[archive-scroll] 7.트랙패드 스크롤 뒤 유휴 600ms: cpu=\(String(format: "%.3f", trackpadIdle))")
        }

        var idle = 0.0
        idle = try await measureCPUUtilization {
            try await settle(for: .milliseconds(600))
        }
        print("[archive-scroll] 3.스크롤 뒤 유휴 600ms: cpu=\(String(format: "%.3f", idle))")

        XCTAssertGreaterThan(abs(inactive.scrolledBy), 0, "휠 이벤트가 scroll view에 닿지 않았습니다.")
    }

    func testArchiveHoverKeepsScrollViewsAndSelectedText() async throws {
        let coordinator = ConversationTextSelectionCoordinator.shared
        coordinator.reset()
        defer { coordinator.reset() }

        let turn = makeTurn()
        let host = NSHostingView(rootView: ArchiveOpenBook(
            turn: turn,
            navigation: ArchiveBookNavigation(
                index: 0,
                total: 1,
                canGoPrevious: false,
                canGoNext: false
            ),
            onPrevious: {},
            onNext: {},
            onClose: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1_160, height: 760)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))

        let documents = allDescendants(of: host)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
        let scrollViews = allDescendants(of: host)
            .compactMap { $0 as? NSScrollView }
        let firstDocument = try XCTUnwrap(documents.first)
        let selection = NSRange(location: 0, length: min(8, firstDocument.textView.string.utf16.count))
        XCTAssertGreaterThan(selection.length, 0)
        firstDocument.textView.setSelectedRange(selection)
        let selectedText = (firstDocument.textView.string as NSString)
            .substring(with: selection)
        let responseScroll = try XCTUnwrap(responseScrollView(in: host))
        responseScroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        responseScroll.reflectScrolledClipView(responseScroll.contentView)
        let scrollOrigin = responseScroll.contentView.bounds.origin
        let createdBefore = SelectableMarkdownDocumentView.createdCount

        let cpu = try await measureCPUUtilization {
            for index in 0..<20 {
                if index.isMultiple(of: 2) {
                    coordinator.handleHover(true, in: "archive-book-\(turn.id)")
                } else {
                    coordinator.handleHover(false, in: "archive-book-\(turn.id)")
                    coordinator.activate("another-conversation")
                }
                host.layoutSubtreeIfNeeded()
                try await settle(for: .milliseconds(8))
            }
        }

        let currentDocuments = allDescendants(of: host)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
        let currentScrollViews = allDescendants(of: host)
            .compactMap { $0 as? NSScrollView }
        let created = SelectableMarkdownDocumentView.createdCount - createdBefore
        print("[archive-hover] changes=20 cpu=\(String(format: "%.3f", cpu)) created=\(created)")
        XCTAssertEqual(created, 0, "호버 때문에 보관함 본문을 다시 만들면 안 됩니다.")
        XCTAssertEqual(currentDocuments.map(ObjectIdentifier.init), documents.map(ObjectIdentifier.init))
        XCTAssertEqual(currentScrollViews.map(ObjectIdentifier.init), scrollViews.map(ObjectIdentifier.init))
        XCTAssertEqual(currentDocuments.first?.textView.selectedRange(), selection)
        XCTAssertTrue(currentDocuments.allSatisfy { $0.textView.isSelectable })
        XCTAssertEqual(responseScrollView(in: host)?.contentView.bounds.origin, scrollOrigin)

        let textView = try XCTUnwrap(currentDocuments.first?.textView)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), selectedText)

        // 뷰를 유지하더라도 이전·다음으로 넘어가면 새 기록의 내용은 갱신돼야 한다.
        host.rootView = ArchiveOpenBook(
            turn: makeTurn(id: "next-record", response: "새 기록 검증: 다음 페이지의 응답입니다."),
            navigation: ArchiveBookNavigation(
                index: 1,
                total: 2,
                canGoPrevious: true,
                canGoNext: false
            ),
            onPrevious: {},
            onNext: {},
            onClose: {}
        )
        host.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(100))
        let nextPageText = allDescendants(of: host)
            .compactMap { ($0 as? SelectableMarkdownDocumentView)?.textView.string }
            .joined(separator: "\n")
        XCTAssertEqual(nextPageText.trimmingCharacters(in: .whitespacesAndNewlines), "새 기록 검증: 다음 페이지의 응답입니다.")
    }

    // 앱과 같은 SwiftUI 시트로 띄운다. 시트 창은 부모 창 위쪽 가운데에 붙으므로
    // 부모를 화면 오른쪽 아래 밖에 두면 시트도 거의 보이지 않는다.
    private struct SheetHarnessRoot: View {
        let turn: LiveFeedTurn
        @State private var isPresented = true

        var body: some View {
            Color.clear
                .frame(width: 1_200, height: 800)
                .sheet(isPresented: $isPresented) {
                    ArchiveOpenBook(
                        turn: turn,
                        navigation: ArchiveBookNavigation(
                            index: 0,
                            total: 1,
                            canGoPrevious: false,
                            canGoNext: false
                        ),
                        onPrevious: {},
                        onNext: {},
                        onClose: { isPresented = false }
                    )
                    .frame(
                        minWidth: ArchiveBookSheetLayout.minimumWidth,
                        idealWidth: ArchiveBookSheetLayout.idealWidth,
                        minHeight: ArchiveBookSheetLayout.minimumHeight,
                        idealHeight: ArchiveBookSheetLayout.idealHeight
                    )
                }
        }
    }

    func testMeasureArchiveSheetScrollWorkload() async throws {
        let coordinator = ConversationTextSelectionCoordinator.shared
        coordinator.reset()
        defer { coordinator.reset() }

        let turn = makeTurn()
        let host = NSHostingView(rootView: AnyView(SheetHarnessRoot(turn: turn)))
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        if let screen = NSScreen.main {
            window.setFrameOrigin(
                NSPoint(x: screen.frame.maxX - 24, y: screen.frame.minY - 780)
            )
        }
        window.orderFrontRegardless()
        defer {
            for sheet in window.sheets {
                window.endSheet(sheet)
            }
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()

        var sheetWindow: NSWindow?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while sheetWindow == nil, clock.now < deadline {
            try await settle(for: .milliseconds(50))
            sheetWindow = window.sheets.first
        }
        guard let sheetWindow, let sheetHost = sheetWindow.contentView else {
            XCTFail("시트 창이 뜨지 않았습니다.")
            return
        }
        try await settle(for: .milliseconds(300))
        print(
            "[archive-sheet] 시트 창 \(Int(sheetWindow.frame.width))x\(Int(sheetWindow.frame.height)) "
                + "at \(Int(sheetWindow.frame.minX)),\(Int(sheetWindow.frame.minY)) "
                + "visible=\(sheetWindow.isVisible)"
        )
        XCTAssertGreaterThanOrEqual(sheetWindow.frame.width, ArchiveBookSheetLayout.minimumWidth)
        guard let firstScroll = responseScrollView(in: sheetHost) else {
            XCTFail("시트 안 응답 scroll view를 찾지 못했습니다.")
            return
        }

        let inactive = try await measureScrollStorm(
            host: sheetHost,
            scrollView: firstScroll,
            events: 160,
            samplePath: "/tmp/archivescroll/sheet-inactive-sample.txt"
        )
        print("[archive-sheet] 1.시트 기본 상태 + 휠 160회: \(inactive.description)")

        coordinator.activate("archive-book-\(turn.id)")
        sheetHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(200))
        guard let activeScroll = responseScrollView(in: sheetHost) else {
            XCTFail("선택이 켜진 뒤 시트 안 scroll view를 찾지 못했습니다.")
            return
        }
        XCTAssertTrue(activeScroll === firstScroll)
        let active = try await measureScrollStorm(
            host: sheetHost,
            scrollView: activeScroll,
            events: 160,
            samplePath: "/tmp/archivescroll/sheet-active-sample.txt"
        )
        print("[archive-sheet] 2.시트 공용 선택 변경 + 휠 160회: \(active.description)")

        let trackpad = try await measureScrollStorm(
            host: sheetHost,
            scrollView: activeScroll,
            events: 160,
            samplePath: "/tmp/archivescroll/sheet-trackpad-sample.txt",
            usesTrackpadPhases: true
        )
        print("[archive-sheet] 3.시트 + 선택 켜짐 + 트랙패드 160회: \(trackpad.description)")

        let idle = try await measureCPUUtilization {
            try await settle(for: .milliseconds(600))
        }
        print("[archive-sheet] 4.스크롤 뒤 유휴 600ms: cpu=\(String(format: "%.3f", idle))")
        XCTAssertGreaterThan(abs(inactive.scrolledBy), 0, "휠 이벤트가 시트 scroll view에 닿지 않았습니다.")
        for measurement in [inactive, active, trackpad] {
            XCTAssertEqual(measurement.created, 0)
            XCTAssertEqual(measurement.textMeasurements, 0)
        }
    }

    // 오른쪽 페이지의 세로 scroll view다. 코드 블록의 가로 스크롤러는
    // 폭이 좁고 문서 높이가 뷰포트와 같아 제외된다.
    private func responseScrollView(in host: NSView) -> NSScrollView? {
        allDescendants(of: host)
            .compactMap { $0 as? NSScrollView }
            .filter {
                $0.convert($0.bounds, to: nil).minX > 400
                    && ($0.documentView?.bounds.height ?? 0)
                        > $0.bounds.height + 1
            }
            .max {
                $0.bounds.width * $0.bounds.height
                    < $1.bounds.width * $1.bounds.height
            }
    }

    private func measureScrollStorm(
        host: NSView,
        scrollView: NSScrollView,
        events: Int,
        samplePath: String?,
        usesTrackpadPhases: Bool = false
    ) async throws -> Measurement {
        let coordinator = ConversationTextSelectionCoordinator.shared
        var result = Measurement()
        var publishes = 0
        let observation = coordinator.objectWillChange.sink { publishes += 1 }
        defer { observation.cancel() }

        guard let window = scrollView.window else {
            return result
        }
        let documentViews = allDescendants(of: host)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
        let createdBefore = SelectableMarkdownDocumentView.createdCount
        let layoutBefore = documentViews.map(\.layoutPassCount).reduce(0, +)
        let heightBefore = documentViews.map(\.heightRequestCount).reduce(0, +)
        let measureBefore = documentViews.map(\.textLayoutMeasurementCount).reduce(0, +)
        let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
        let point = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
        let startY = scrollView.contentView.bounds.minY
        var farthestY = startY

        var sampler: Process?
        if let samplePath {
            try? FileManager.default.createDirectory(
                atPath: (samplePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(getpid()), "3", "-file", samplePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            sampler = process
        }

        var sendsDirectly = false
        result.cpu = try await measureCPUUtilization {
            for index in 0..<events {
                // 앞 절반은 아래로, 뒤 절반은 위로 굴린다.
                let delta: CGFloat = index < events / 2 ? -24 : 24
                // 트랙패드 흐름: 손가락 40회(시작·진행·종료), 관성 40회(시작·진행·종료).
                let phase: ScrollPhase = {
                    guard usesTrackpadPhases else { return .none }
                    let step = index % (events / 2)
                    switch step {
                    case 0: return .began
                    case 1..<39: return .changed
                    case 39: return .ended
                    case 40: return .momentumBegan
                    case (events / 2 - 1): return .momentumEnded
                    default: return .momentumChanged
                    }
                }()
                if let event = makeScrollEvent(
                    deltaY: delta,
                    at: point,
                    in: window,
                    phase: phase
                ) {
                    if index == 0 {
                        print(
                            "[archive-scroll] 이벤트 locationInWindow="
                                + "\(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) "
                                + "target=\(Int(point.x)),\(Int(point.y))"
                        )
                    }
                    if sendsDirectly {
                        scrollView.scrollWheel(with: event)
                    } else {
                        window.sendEvent(event)
                    }
                    result.events += 1
                    // 창 경로로 닿지 않으면 scroll view에 직접 넣는다.
                    if index == 0, scrollView.contentView.bounds.minY == startY {
                        sendsDirectly = true
                        print("[archive-scroll] 창 경로로 닿지 않아 scroll view에 직접 보냅니다.")
                        scrollView.scrollWheel(with: event)
                    }
                }
                host.layoutSubtreeIfNeeded()
                let currentY = scrollView.contentView.bounds.minY
                if abs(currentY - startY) > abs(farthestY - startY) {
                    farthestY = currentY
                }
                try await settle(for: .milliseconds(8))
            }
        }
        sampler?.waitUntilExit()

        let documentViewsAfter = allDescendants(of: host)
            .compactMap { $0 as? SelectableMarkdownDocumentView }
        result.created = SelectableMarkdownDocumentView.createdCount - createdBefore
        result.layoutPasses =
            documentViewsAfter.map(\.layoutPassCount).reduce(0, +) - layoutBefore
        result.heightRequests =
            documentViewsAfter.map(\.heightRequestCount).reduce(0, +) - heightBefore
        result.textMeasurements =
            documentViewsAfter.map(\.textLayoutMeasurementCount).reduce(0, +)
            - measureBefore
        result.publishes = publishes
        result.scrolledBy = farthestY - startY
        return result
    }

    private enum ScrollPhase {
        case none, began, changed, ended, momentumBegan, momentumChanged, momentumEnded
    }

    // 창 원점이 화면 (0,0)이라 창 좌표와 화면 좌표가 같다. CGEvent는
    // 왼쪽 위 원점이므로 y만 뒤집는다.
    private func makeScrollEvent(
        deltaY: CGFloat,
        at windowPoint: NSPoint,
        in window: NSWindow,
        phase: ScrollPhase = .none
    ) -> NSEvent? {
        guard
            let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: Int32(deltaY),
                wheel2: 0,
                wheel3: 0
            )
        else {
            return nil
        }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: screenHeight - screenPoint.y)
        if phase != .none {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let (scrollPhase, momentumPhase): (Int64, Int64) = {
                switch phase {
                case .began: return (1, 0)
                case .changed: return (2, 0)
                case .ended: return (4, 0)
                case .momentumBegan: return (0, 1)
                case .momentumChanged: return (0, 2)
                case .momentumEnded: return (0, 3)
                case .none: return (0, 0)
                }
            }()
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        }
        return NSEvent(cgEvent: cgEvent)
    }

    private func makeTurn(
        id: String = "archive-scroll-measure",
        response: String? = nil
    ) -> LiveFeedTurn {
        let timestamp = Date(timeIntervalSinceReferenceDate: 10_000)
        return LiveFeedTurn(
            id: id,
            characterId: OfficeCharacter.boss.rawValue,
            characterName: "백부장",
            characterBackend: .claude,
            backend: .claude,
            model: "claude-fable-5-1",
            effort: "xhigh",
            fastMode: false,
            externalSessionId: "0123456789abcdef",
            conversationWorkdir: "/repo",
            prompt: "시트 스크롤 재현용 업무입니다.",
            response: response ?? Self.responseSource,
            feedback: nil,
            status: .completed,
            needsInput: false,
            errorMessage: nil,
            responseSourceWarning: nil,
            wikiProposalWarning: nil,
            startedAt: timestamp,
            endedAt: timestamp,
            updatedAt: timestamp,
            estimatedCostUsd: nil,
            sessionContext: nil,
            activities: [],
            sources: nil,
            workspace: nil
        )
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
