// 이 파일은 Codex와 Claude의 모델 사용 한도 소진 오류를 공통 상태로 판별한다.

import Foundation

public enum AgentUsageLimitClassifier {
    public static func isLimitReached(_ message: String) -> Bool {
        let normalized = message
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")

        if normalized.contains("insufficient_quota")
            || normalized.contains("usage_limit_reached")
            || normalized.contains("no weighted tokens left")
        {
            return true
        }

        let exhaustionWords = [
            "hit",
            "reached",
            "exceeded",
            "exhausted",
            "used up",
        ]
        let limitNames = [
            "usage limit",
            "session limit",
            "weekly limit",
            "monthly limit",
            "model limit",
            "quota",
        ]
        if
            exhaustionWords.contains(where: normalized.contains),
            limitNames.contains(where: normalized.contains)
        {
            return true
        }

        if
            normalized.range(
                of: #"\b0(?:\.0+)?\s+weighted tokens left\b"#,
                options: .regularExpression
            ) != nil
        {
            return true
        }

        let koreanExhaustionWords = ["도달", "초과", "소진", "모두 사용"]
        return normalized.contains("한도")
            && koreanExhaustionWords.contains(where: normalized.contains)
    }
}
