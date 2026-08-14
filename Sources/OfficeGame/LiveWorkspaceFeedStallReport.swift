// 이 파일은 대화 화면이 오래 비어 있는 드문 증상의 증거를 남긴다.

import Foundation

/// 증상이 발생한 순간의 판정값을 그대로 담는 한 줄 기록이다. 재현이
/// 드물어 사후 분석이 유일한 수단이므로 계산된 결론이 아니라 원자료를
/// 남긴다.
struct LiveWorkspaceFeedStallReport: Equatable, Codable {
    let kind: String
    let characterID: String
    let elapsedSeconds: Double
    let readiness: String
    let hostWidth: Double
    let hostHeight: Double
    let hasScrollView: Bool
    let documentHeight: Double
    let viewportHeight: Double
    let visibleIntersectionHeight: Double
    let turnCount: Int
    let isLoadingInitialFeed: Bool
    let readinessRevision: Int
    let preClampPassCount: Int
    let postClampPassCount: Int
    let viewportClampCount: Int
    let hasLoadingGate: Bool
    /// 증상 동안 문서 높이가 어떻게 흔들렸는지 순서대로 담는다.
    var documentHeightTrace: [Int] = []

    /// 사람이 먼저 훑고 필요할 때 필드를 보도록 한 줄 요약을 만든다.
    var summary: String {
        let seconds = String(format: "%.1f", elapsedSeconds)
        let trace = documentHeightTrace
            .map(String.init)
            .joined(separator: ">")
        return "[\(kind)] \(characterID) \(seconds)s readiness=\(readiness)"
            + " host=\(Int(hostWidth))x\(Int(hostHeight))"
            + " scroll=\(hasScrollView)"
            + " doc=\(Int(documentHeight)) viewport=\(Int(viewportHeight))"
            + " overlap=\(Int(visibleIntersectionHeight))"
            + " turns=\(turnCount) loading=\(isLoadingInitialFeed)"
            + " revision=\(readinessRevision)"
            + " pass=\(preClampPassCount)/\(postClampPassCount)"
            + " clamp=\(viewportClampCount) gate=\(hasLoadingGate)"
            + (trace.isEmpty ? "" : " trace=\(trace)")
    }
}

/// 이미 떠 있던 대화가 갑자기 비는 증상을 판정한다. 전환과 달리 예고가
/// 없으므로 문서 기하만 보고 결정한다.
struct LiveWorkspaceFeedBlankDetector: Equatable {
    /// 스크롤바가 움찔거리는 것은 문서 높이가 짧은 시간에 여러 번
    /// 바뀐다는 뜻이다. 흔들린 값을 순서대로 남겨야 원인을 좁힐 수 있다.
    static let maximumTraceCount = 24

    /// 문서가 사라졌거나 보이는 영역과 겹치지 않으면 사용자 눈에는 흰
    /// 화면이다. 대화가 있는데 이 상태면 비정상이다.
    static func isBlank(
        turnCount: Int,
        documentHeight: Double,
        viewportHeight: Double,
        visibleIntersectionHeight: Double
    ) -> Bool {
        guard turnCount > 0, viewportHeight > 1 else {
            return false
        }
        if documentHeight <= 1 {
            return true
        }
        return visibleIntersectionHeight <= 1
    }

    private(set) var documentHeightTrace: [Int] = []

    mutating func appendTrace(documentHeight: Double) {
        let value = Int(documentHeight.rounded())
        guard documentHeightTrace.last != value else {
            return
        }
        documentHeightTrace.append(value)
        if documentHeightTrace.count > Self.maximumTraceCount {
            documentHeightTrace.removeFirst(
                documentHeightTrace.count - Self.maximumTraceCount
            )
        }
    }

    mutating func reset() {
        documentHeightTrace.removeAll(keepingCapacity: true)
    }
}

/// 언제 기록을 남길지만 정한다. 뷰 계층 없이 검증할 수 있도록 순수하게
/// 유지한다.
struct LiveWorkspaceFeedStallPolicy: Equatable {
    /// 정상 전환은 보통 수백 ms 안에 끝난다. 사람이 "오래"라고 느끼는
    /// 구간부터 남겨야 기록이 잡음이 되지 않는다.
    static let firstReportDelay = TimeInterval(2.5)
    /// 한 번 걸린 전환이 계속 안 풀리면 시간에 따른 변화도 필요하다.
    /// 다만 무한정 쌓지 않는다.
    static let repeatReportInterval = TimeInterval(5)
    static let maximumReportsPerTransition = 4
    /// 눈에 띄지 않는 짧은 깜빡임까지 남기면 기록이 잡음이 된다.
    static let recoveredThreshold = TimeInterval(0.6)

    private(set) var reportCount = 0
    private(set) var lastReportedElapsed = TimeInterval(0)

    mutating func shouldReport(elapsed: TimeInterval) -> Bool {
        guard reportCount < Self.maximumReportsPerTransition else {
            return false
        }
        let threshold =
            reportCount == 0
            ? Self.firstReportDelay
            : lastReportedElapsed + Self.repeatReportInterval
        guard elapsed >= threshold else {
            return false
        }
        reportCount += 1
        lastReportedElapsed = elapsed
        return true
    }

    mutating func reset() {
        reportCount = 0
        lastReportedElapsed = 0
    }
}

/// 기록을 파일 한 줄로 덧붙인다. 앱이 꺼져도 남아야 하므로 메모리에
/// 두지 않는다.
struct LiveWorkspaceFeedStallRecorder {
    static let fileName = "live-feed-stalls.jsonl"

    let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static func live(
        fileManager: FileManager = .default
    ) -> LiveWorkspaceFeedStallRecorder? {
        guard
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            return nil
        }
        return LiveWorkspaceFeedStallRecorder(
            directoryURL: support
                .appending(path: "OFFICESTRA", directoryHint: .isDirectory)
                .appending(path: "logs", directoryHint: .isDirectory),
            fileManager: fileManager
        )
    }

    var fileURL: URL {
        directoryURL.appending(path: Self.fileName)
    }

    @discardableResult
    func record(
        _ report: LiveWorkspaceFeedStallReport,
        at timestamp: Date
    ) -> Bool {
        guard let line = Self.line(for: report, at: timestamp) else {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer {
                    try? handle.close()
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    static func line(
        for report: LiveWorkspaceFeedStallReport,
        at timestamp: Date
    ) -> String? {
        guard
            let encoded = try? JSONEncoder().encode(report),
            var fields = try? JSONSerialization.jsonObject(with: encoded)
                as? [String: Any]
        else {
            return nil
        }
        fields["recordedAt"] = ISO8601DateFormatter().string(from: timestamp)
        fields["summary"] = report.summary
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text + "\n"
    }
}
