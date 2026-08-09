// 이 파일은 실시간 응답에서 즉시 표시할 본문과 한 글자씩 출력할 후행 구간을 계산한다.

import Foundation

public enum StreamingTextPacer {
    public static let animatedTailCharacterCount = 180
    public static let animationTickInterval = TimeInterval(0.016)
    // 메인 RunLoop 지연 여유를 남겨 실제 화면도 1초 안에 끝나게 한다.
    public static let maximumLineRevealDuration = TimeInterval(0.9)

    public static func immediatelyVisibleCharacterCount(
        remainingCharacterCount: Int
    ) -> Int {
        max(
            0,
            remainingCharacterCount - animatedTailCharacterCount
        )
    }

    public static func updatePlan(
        current: String,
        target: String,
        animates: Bool
    ) -> StreamingTextUpdatePlan {
        guard animates else {
            return StreamingTextUpdatePlan(
                immediateText: target,
                animatedCharacters: []
            )
        }

        let sharedPrefix = sharedPrefix(current, target)
        let remainingCharacters = Array(
            target.dropFirst(sharedPrefix.count)
        )
        let immediatelyVisibleCount =
            immediatelyVisibleCharacterCount(
                remainingCharacterCount: remainingCharacters.count
            )
        let immediateCharacters = remainingCharacters.prefix(
            immediatelyVisibleCount
        )

        return StreamingTextUpdatePlan(
            immediateText: sharedPrefix + String(immediateCharacters),
            animatedCharacters: Array(
                remainingCharacters.dropFirst(immediatelyVisibleCount)
            )
        )
    }

    /// 완성된 응답의 한 줄을 처음부터 보여주되 1초 안에 끝나도록
    /// 프레임당 출력량을 조절한다.
    public static func fullLineUpdatePlan(
        current: String,
        target: String,
        animates: Bool
    ) -> StreamingTextUpdatePlan {
        guard animates else {
            return StreamingTextUpdatePlan(
                immediateText: target,
                animatedCharacters: []
            )
        }

        let sharedPrefix = sharedPrefix(current, target)
        let animatedCharacters = Array(
            target.dropFirst(sharedPrefix.count)
        )
        let animationDuration = min(
            maximumLineRevealDuration,
            TimeInterval(animatedCharacters.count) * animationTickInterval
        )

        return StreamingTextUpdatePlan(
            immediateText: sharedPrefix,
            animatedCharacters: animatedCharacters,
            // 한 tick 최소 한 글자만 보장하고 실제 진도는 경과시간으로
            // 계산한다. 배치 크기 경계에서 긴 줄이 갑자기 빨라지지 않는다.
            charactersPerTick: 1,
            animationDuration: animationDuration
        )
    }

    public static func elapsedRevealCharacterCount(
        totalCharacterCount: Int,
        minimumCharacterCount: Int,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Int {
        let total = max(0, totalCharacterCount)
        guard total > 0 else {
            return 0
        }
        guard duration > 0 else {
            return total
        }
        let progress = min(1, max(0, elapsed) / duration)
        return min(
            total,
            max(
                minimumCharacterCount,
                Int(ceil(Double(total) * progress))
            )
        )
    }

    private static func sharedPrefix(
        _ current: String,
        _ target: String
    ) -> String {
        var currentIndex = current.startIndex
        var targetIndex = target.startIndex

        while
            currentIndex < current.endIndex,
            targetIndex < target.endIndex,
            current[currentIndex] == target[targetIndex]
        {
            current.formIndex(after: &currentIndex)
            target.formIndex(after: &targetIndex)
        }

        return String(current[..<currentIndex])
    }
}

public struct StreamingTextUpdatePlan: Equatable, Sendable {
    public let immediateText: String
    public let animatedCharacters: [Character]
    public let charactersPerTick: Int
    public let animationDuration: TimeInterval?

    public init(
        immediateText: String,
        animatedCharacters: [Character],
        charactersPerTick: Int = 1,
        animationDuration: TimeInterval? = nil
    ) {
        self.immediateText = immediateText
        self.animatedCharacters = animatedCharacters
        self.charactersPerTick = max(1, charactersPerTick)
        self.animationDuration = animationDuration
    }
}
