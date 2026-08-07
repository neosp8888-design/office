// 이 파일은 실제 Codex 롤아웃 형식의 협업 시작과 완료 연결을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  CodexRolloutCollaborationTracker,
} from "../src/codex-rollout-collaboration.mjs";

test("현재 Codex 롤아웃의 협업 시작과 최종 답변을 같은 카드로 연결한다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  const encryptedPrompt = "gAAAAABencrypted-internal-prompt";

  assert.deepEqual(tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "spawn_agent",
      namespace: "collaboration",
      call_id: "call-spawn-1",
      arguments: JSON.stringify({
        task_name: "event_schema_review",
        fork_turns: "all",
        message: encryptedPrompt,
      }),
    },
  }), []);

  const started = tracker.consume({
    type: "event_msg",
    payload: {
      type: "sub_agent_activity",
      event_id: "call-spawn-1",
      agent_thread_id: "thread-review-1",
      agent_path: "/root/event_schema_review",
      kind: "started",
    },
  });

  assert.equal(started.length, 1);
  assert.equal(started[0].status, "running");
  assert.equal(started[0].eventKey, "collaboration:rollout:thread-review-1");
  assert.equal(started[0].collaboration.agentLabel, "event schema review");
  assert.equal(started[0].collaboration.prompt, "event schema review");
  assert.doesNotMatch(JSON.stringify(started), /gAAAAAB/);

  const completed = tracker.consume({
    type: "response_item",
    payload: {
      type: "agent_message",
      author: "/root/event_schema_review",
      recipient: "/root",
      content: [{
        type: "input_text",
        text: [
          "Message Type: FINAL_ANSWER",
          "Task name: /root",
          "Sender: /root/event_schema_review",
          "Payload:",
          "실제 이벤트 형식 검토를 마쳤습니다.",
        ].join("\n"),
      }],
    },
  });

  assert.equal(completed.length, 1);
  assert.equal(completed[0].status, "completed");
  assert.equal(completed[0].eventKey, started[0].eventKey);
  assert.equal(
    completed[0].collaboration.message,
    "실제 이벤트 형식 검토를 마쳤습니다.",
  );
  assert.equal(
    completed[0].collaboration.agentThreadId,
    "thread-review-1",
  );
});

test("암호화된 중간 협업 메시지는 화면 활동으로 만들지 않는다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  const activities = tracker.consume({
    type: "response_item",
    payload: {
      type: "agent_message",
      author: "/root/reviewer",
      recipient: "/root",
      content: [
        {
          type: "input_text",
          text: [
            "Message Type: MESSAGE",
            "Task name: /root",
            "Sender: /root/reviewer",
            "Payload:",
          ].join("\n"),
        },
        {
          type: "encrypted_content",
          encrypted_content: "gAAAAABprivate-progress",
        },
      ],
    },
  });

  assert.deepEqual(activities, []);
});

test("암호화된 send_message는 완료 카드를 다시 실행 중으로 만들지 않는다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "send_message",
      namespace: "collaboration",
      call_id: "call-follow-up",
      arguments: JSON.stringify({
        target: "reviewer",
        message: "gAAAAABprivate-follow-up",
      }),
    },
  });

  assert.deepEqual(tracker.consume({
    type: "event_msg",
    payload: {
      type: "sub_agent_activity",
      event_id: "call-follow-up",
      agent_thread_id: "thread-reviewer",
      agent_path: "/root/reviewer",
      kind: "interacted",
    },
  }), []);
});

test("followup_task 재호출은 같은 카드를 실행 중으로 되돌린 뒤 다시 완료한다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "spawn_agent",
      namespace: "collaboration",
      call_id: "call-spawn-follow-up",
      arguments: JSON.stringify({ task_name: "reviewer" }),
    },
  });
  const [started] = tracker.consume({
    type: "event_msg",
    payload: {
      type: "sub_agent_activity",
      event_id: "call-spawn-follow-up",
      agent_thread_id: "thread-reviewer",
      agent_path: "/root/reviewer",
      kind: "started",
    },
  });
  const [firstResult] = tracker.consume({
    type: "response_item",
    payload: {
      type: "agent_message",
      author: "/root/reviewer",
      content: [{
        type: "input_text",
        text: [
          "Message Type: FINAL_ANSWER",
          "Sender: /root/reviewer",
          "Payload:",
          "첫 검토 완료",
        ].join("\n"),
      }],
    },
  });
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "followup_task",
      namespace: "collaboration",
      call_id: "call-follow-up-task",
      arguments: JSON.stringify({
        target: "reviewer",
        message: "gAAAAABprivate-follow-up",
      }),
    },
  });
  const [followUp] = tracker.consume({
    type: "event_msg",
    payload: {
      type: "sub_agent_activity",
      event_id: "call-follow-up-task",
      agent_thread_id: "thread-reviewer",
      agent_path: "/root/reviewer",
      kind: "interacted",
    },
  });
  const [secondResult] = tracker.consume({
    type: "response_item",
    payload: {
      type: "agent_message",
      author: "/root/reviewer",
      content: [{
        type: "input_text",
        text: [
          "Message Type: FINAL_ANSWER",
          "Sender: /root/reviewer",
          "Payload:",
          "추가 검토 완료",
        ].join("\n"),
      }],
    },
  });

  assert.equal(firstResult.status, "completed");
  assert.equal(followUp.status, "running");
  assert.equal(followUp.collaboration.action, "follow_up");
  assert.equal(followUp.collaboration.prompt, "추가 검토 요청");
  assert.doesNotMatch(JSON.stringify(followUp), /gAAAAAB/);
  assert.equal(secondResult.status, "completed");
  assert.equal(secondResult.collaboration.message, "추가 검토 완료");
  assert.equal(started.eventKey, firstResult.eventKey);
  assert.equal(started.eventKey, followUp.eventKey);
  assert.equal(started.eventKey, secondResult.eventKey);
});

test("시작 이벤트 없이 실패한 spawn_agent도 안전한 실패 카드로 남긴다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "spawn_agent",
      namespace: "collaboration",
      call_id: "call-spawn-failed",
      arguments: JSON.stringify({
        task_name: "duplicate_review",
        message: "gAAAAABprivate-prompt",
      }),
    },
  });

  const activities = tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: "call-spawn-failed",
      output: "agent path `/root/duplicate_review` already exists",
    },
  });

  assert.equal(activities.length, 1);
  assert.equal(activities[0].status, "failed");
  assert.equal(activities[0].collaboration.agentLabel, "duplicate review");
  assert.equal(activities[0].collaboration.agentStatus, "errored");
  assert.equal(
    activities[0].collaboration.message,
    "협업 검토를 시작하지 못했습니다.",
  );
  assert.doesNotMatch(JSON.stringify(activities), /gAAAAAB|already exists/);
});

test("list_agents 완료 결과는 최종 회신 누락을 복구한다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "spawn_agent",
      namespace: "collaboration",
      call_id: "call-spawn-2",
      arguments: JSON.stringify({ task_name: "fallback_review" }),
    },
  });
  tracker.consume({
    type: "event_msg",
    payload: {
      type: "sub_agent_activity",
      event_id: "call-spawn-2",
      agent_thread_id: "thread-review-2",
      agent_path: "/root/fallback_review",
      kind: "started",
    },
  });
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "list_agents",
      namespace: "collaboration",
      call_id: "call-list-1",
      arguments: "{}",
    },
  });

  const activities = tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: "call-list-1",
      output: JSON.stringify({
        agents: [
          { agent_name: "/root", agent_status: "running" },
          {
            agent_name: "/root/fallback_review",
            agent_status: { completed: "누락된 결과를 복구했습니다." },
          },
        ],
      }),
    },
  });

  assert.equal(activities.length, 1);
  assert.equal(activities[0].status, "completed");
  assert.equal(
    activities[0].eventKey,
    "collaboration:rollout:thread-review-2",
  );
  assert.equal(
    activities[0].collaboration.message,
    "누락된 결과를 복구했습니다.",
  );
});

test("wait_agent 결과는 협업 카드에 관리용 기록을 만들지 않는다", () => {
  const tracker = new CodexRolloutCollaborationTracker();
  tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call",
      name: "wait_agent",
      namespace: "collaboration",
      call_id: "call-wait-1",
      arguments: JSON.stringify({ timeout_ms: 10_000 }),
    },
  });

  assert.deepEqual(tracker.consume({
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: "call-wait-1",
      output: JSON.stringify({ message: "Wait completed.", timed_out: false }),
    },
  }), []);
});
