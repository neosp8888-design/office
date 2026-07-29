// 이 파일은 실시간 응답에서 즉시 표시할 본문과 한 글자씩 출력할 후행 구간을 계산한다.

public enum StreamingTextPacer {
    public static let animatedTailCharacterCount = 180

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

    public init(
        immediateText: String,
        animatedCharacters: [Character]
    ) {
        self.immediateText = immediateText
        self.animatedCharacters = animatedCharacters
    }
}
