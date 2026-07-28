// 이 파일은 긴 실시간 응답의 타자 효과가 화면 갱신 속도를 따라가도록 표시량을 계산한다.

public enum StreamingTextPacer {
    public static let targetCatchUpFrameCount = 30
    public static let maximumCharactersPerFrame = 64

    public static func charactersPerFrame(
        remainingCharacterCount: Int
    ) -> Int {
        guard remainingCharacterCount > 0 else {
            return 0
        }

        let required = (
            remainingCharacterCount - 1
        ) / targetCatchUpFrameCount + 1
        return min(
            maximumCharactersPerFrame,
            max(1, required)
        )
    }
}
