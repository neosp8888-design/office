// 이 파일은 긴 실시간 응답에서 즉시 표시할 본문과 타자 효과를 줄 후행 구간을 계산한다.

public enum StreamingTextPacer {
    public static let animatedTailCharacterCount = 12

    public static func immediatelyVisibleCharacterCount(
        remainingCharacterCount: Int
    ) -> Int {
        max(
            0,
            remainingCharacterCount - animatedTailCharacterCount
        )
    }
}
