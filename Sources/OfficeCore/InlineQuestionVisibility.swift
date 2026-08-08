// 이 파일은 확인 질문 답변란을 어느 대화 카드에 보일지 판단한다.

import Foundation

public enum InlineQuestionVisibility {
    /// 답변란은 아직 답하지 않은 그 턴에만 붙는다.
    /// 예전에 답을 마친 턴도 기록상 `needsInput`이 남으므로 턴 ID까지 맞춰본다.
    public static func showsAnswerComposer(
        turnNeedsInput: Bool,
        turnID: String,
        pendingQuestionTurnID: String?
    ) -> Bool {
        guard turnNeedsInput, let pendingQuestionTurnID else {
            return false
        }
        return pendingQuestionTurnID == turnID
    }
}
