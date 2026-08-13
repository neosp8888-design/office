// 이 파일은 실시간 대화 흰 화면 재현을 실측으로 고정하기 위한 진단 로그를 담는다.

import Foundation
import os

/// 실시간 대화 패널의 데이터 발행·표시 결정·실체화·스크롤 기하를 한 줄씩
/// 남긴다. 흰 화면이 난 순간에 어느 계층이 먼저 무너졌는지 사후에 판정하기
/// 위한 목적이며, 원인 확정 뒤에는 제거한다.
///
/// 조회: `log show --predicate 'subsystem == "com.neo.officestra"' --last 10m`
enum LiveFeedDiagnostics {
    /// `OFFICESTRA_LIVEFEED_DIAG=0`으로 끌 수 있다. 기본은 켜짐이며, 재현이
    /// 간헐적이라 사용자가 별도 절차 없이 바로 잡을 수 있어야 한다.
    static let isEnabled =
        ProcessInfo.processInfo.environment["OFFICESTRA_LIVEFEED_DIAG"] != "0"

    private static let logger = Logger(
        subsystem: "com.neo.officestra",
        category: "livefeed"
    )

    static func log(_ event: String, _ detail: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }
        let message = detail()
        logger.log("\(event, privacy: .public) \(message, privacy: .public)")
    }

    /// 턴 목록을 로그 한 줄에 담을 수 있도록 줄인다. 앞뒤만 남기고 전체
    /// 개수를 함께 적어, 어느 카드가 빠졌는지 추적할 수 있게 한다.
    static func brief(_ ids: [String]) -> String {
        let shortened = ids.map { id -> String in
            id.count <= 8 ? id : String(id.prefix(8))
        }
        guard shortened.count > 6 else {
            return shortened.joined(separator: ",")
        }
        let head = shortened.prefix(3).joined(separator: ",")
        let tail = shortened.suffix(2).joined(separator: ",")
        return "\(head)…\(tail)"
    }
}
