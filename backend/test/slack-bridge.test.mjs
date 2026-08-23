// 이 파일은 Slack 직원 선택과 진행 메시지 및 로컬 설정 해석을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  employeeSelectionBlocks,
  markSlackTurnDeliveryCompleted,
  parseEnvironmentFile,
  pendingSlackTurnTargets,
  readSlackConfiguration,
  recordSlackTurnLaunch,
  renderSlackTurn,
  slackPreference,
  splitSlackMessage,
  stripSlackMention,
} from "../src/slack-bridge.mjs";

test("Slack 설정은 토큰을 노출하지 않고 허용 사용자와 팀을 분리한다", () => {
  const configuration = readSlackConfiguration({
    environment: {
      SLACK_BOT_TOKEN: "xoxb-test",
      SLACK_APP_TOKEN: "xapp-test",
      OFFICE_SLACK_ALLOWED_USER_IDS: "U1, U2",
      OFFICE_SLACK_ALLOWED_TEAM_IDS: "T1 T2",
    },
    filePath: "/not-present/officestra-slack.env",
  });

  assert.equal(configuration.botToken, "xoxb-test");
  assert.equal(configuration.appToken, "xapp-test");
  assert.deepEqual([...configuration.allowedUserIDs], ["U1", "U2"]);
  assert.deepEqual([...configuration.allowedTeamIDs], ["T1", "T2"]);
});

test("Slack 환경 파일은 주석과 따옴표를 안전하게 읽는다", () => {
  assert.deepEqual(
    parseEnvironmentFile(`
      # local only
      SLACK_BOT_TOKEN="xoxb-value"
      SLACK_APP_TOKEN='xapp-value'
      invalid-line
    `),
    {
      SLACK_BOT_TOKEN: "xoxb-value",
      SLACK_APP_TOKEN: "xapp-value",
    },
  );
});

test("직원 선택 버튼은 DB 이름과 현재 선택을 그대로 반영한다", () => {
  const blocks = employeeSelectionBlocks([
    { id: "boss", name: "백부장" },
    { id: "right-woman", name: "코대리" },
  ], "right-woman");
  const buttons = blocks[1].elements;

  assert.equal(buttons[0].text.text, "백부장");
  assert.equal(buttons[1].text.text, "✓ 코대리");
  assert.equal(buttons[1].style, "primary");
  assert.equal(buttons[1].value, "right-woman");
  assert.equal(new Set(buttons.map((button) => button.action_id)).size, 2);
});

test("Slack 멘션은 업무 원문에서 제거한다", () => {
  assert.equal(
    stripSlackMention("<@UBOT>   상태를 확인해줘", "UBOT"),
    "상태를 확인해줘",
  );
});

test("실시간 진행은 최근 활동만 간결하게 표시한다", () => {
  const text = renderSlackTurn({
    characterName: "코과장",
    status: "running",
    activities: [
      { text: "첫 단계" },
      { text: "둘째 단계" },
      { text: "셋째 단계" },
      { text: "넷째 단계" },
      { text: "다섯째 단계" },
    ],
    response: "응답 작성 중",
  });

  assert.match(text, /코과장/);
  assert.doesNotMatch(text, /첫 단계/);
  assert.match(text, /둘째 단계/);
  assert.match(text, /다섯째 단계/);
  assert.match(text, /응답 작성 중/);
});

test("Slack은 과거 workspace 메타데이터 대신 턴 상태만 표시한다", () => {
  const completed = renderSlackTurn({
    characterName: "백부장",
    status: "completed",
    workspace: { status: "awaiting_approval" },
  });

  assert.match(completed, /완료/);
  assert.doesNotMatch(completed, /통합|병합/);
});

test("긴 Slack 최종 응답은 내용 손실 없이 여러 메시지로 나눈다", () => {
  const chunks = splitSlackMessage("첫째 줄\n둘째 줄\n셋째 줄", 10);
  assert.ok(chunks.length > 1);
  assert.equal(chunks.join("\n"), "첫째 줄\n둘째 줄\n셋째 줄");
});

test("Slack 직원 선택은 같은 팀의 사용자 설정만 조회한다", async () => {
  let receivedParameters;
  const pool = {
    async query(_statement, parameters) {
      receivedParameters = parameters;
      return { rows: [{ characterId: "left-man" }] };
    },
  };

  const preference = await slackPreference(pool, "T-current", "U1");

  assert.equal(preference.characterId, "left-man");
  assert.deepEqual(receivedParameters, ["T-current", "U1"]);
});

test("Slack 업무 시작은 백엔드가 반환한 실제 대화 ID를 저장한다", async () => {
  let receivedStatement;
  let receivedParameters;
  const pool = {
    async query(statement, parameters) {
      receivedStatement = statement;
      receivedParameters = parameters;
      return {
        rowCount: 1,
        rows: [{ conversationId: parameters[3] }],
      };
    },
  };

  const saved = await recordSlackTurnLaunch(pool, {
    teamID: "T1",
    channelID: "C1",
    threadTS: "100.1",
    conversationID: "11111111-1111-4111-8111-111111111111",
    turnID: "22222222-2222-4222-8222-222222222222",
    statusMessageTS: "100.2",
  });

  assert.match(receivedStatement, /conversation_id = \$4/);
  assert.match(receivedStatement, /delivery_completed_at = NULL/);
  assert.deepEqual(receivedParameters, [
    "T1",
    "C1",
    "100.1",
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "100.2",
  ]);
  assert.equal(
    saved.conversationId,
    "11111111-1111-4111-8111-111111111111",
  );
});

test("미전달 Slack 업무는 재시작 뒤 복구 대상으로 조회하고 완료 처리한다", async () => {
  const statements = [];
  const pool = {
    async query(statement, parameters) {
      statements.push({ statement, parameters });
      if (statement.includes("SELECT")) {
        return {
          rows: [{
            channelID: "C1",
            threadTS: "100.1",
            messageTS: "100.2",
            turnID: "22222222-2222-4222-8222-222222222222",
          }],
        };
      }
      return { rowCount: 1, rows: [] };
    },
  };

  const targets = await pendingSlackTurnTargets(pool);
  await markSlackTurnDeliveryCompleted(pool, targets[0].turnID);

  assert.equal(targets.length, 1);
  assert.match(statements[0].statement, /delivery_completed_at IS NULL/);
  assert.deepEqual(statements[1].parameters, [
    "22222222-2222-4222-8222-222222222222",
  ]);
});
