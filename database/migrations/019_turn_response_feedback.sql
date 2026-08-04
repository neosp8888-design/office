-- 이 파일은 완료된 대화 응답의 좋아요·싫어요 평가를 선택적으로 저장한다.

CREATE TABLE IF NOT EXISTS turn_response_feedback (
    turn_id uuid PRIMARY KEY REFERENCES turns(id) ON DELETE CASCADE,
    feedback text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT turn_response_feedback_value_check CHECK (
        feedback IN ('liked', 'disliked')
    )
);

CREATE INDEX IF NOT EXISTS turn_response_feedback_value_updated_idx
ON turn_response_feedback (feedback, updated_at DESC);
