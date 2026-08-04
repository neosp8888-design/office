// 이 파일은 완료된 대화의 사용자 평가를 검증하고 PostgreSQL에 저장한다.

const allowedFeedback = new Set(["liked", "disliked"]);

export class TurnFeedbackValidationError extends Error {}

export function normalizeTurnFeedback(value) {
  if (value === null) {
    return null;
  }
  if (typeof value !== "string" || !allowedFeedback.has(value)) {
    throw new TurnFeedbackValidationError(
      "feedback 값은 liked, disliked 또는 null이어야 합니다.",
    );
  }
  return value;
}

export async function replaceTurnFeedback(client, turnID, feedback) {
  const turn = await client.query(
    `
      SELECT id, status
      FROM turns
      WHERE id = $1
      FOR UPDATE
    `,
    [turnID],
  );
  if (turn.rowCount === 0) {
    return { outcome: "missing" };
  }
  if (turn.rows[0].status !== "completed") {
    return { outcome: "unavailable" };
  }

  if (feedback === null) {
    await client.query(
      "DELETE FROM turn_response_feedback WHERE turn_id = $1",
      [turnID],
    );
    return { outcome: "stored", feedback: null };
  }

  const stored = await client.query(
    `
      INSERT INTO turn_response_feedback (
        turn_id,
        feedback
      )
      VALUES ($1, $2)
      ON CONFLICT (turn_id) DO UPDATE
      SET
        feedback = EXCLUDED.feedback,
        updated_at = now()
      RETURNING feedback
    `,
    [turnID, feedback],
  );
  return {
    outcome: "stored",
    feedback: stored.rows[0].feedback,
  };
}
