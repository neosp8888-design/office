// 이 파일은 캐릭터 실행 설정 변경에 따른 CLI 세션 유지 정책을 검증한다.

import assert from "node:assert/strict";
import test from "node:test";

import {
  characterSettingsRequireNewSession,
} from "../src/configuration.mjs";

const current = {
  backend: "codex",
  model: "gpt-5.6-sol",
  effort: "high",
  fastMode: true,
  permission: "workspace-write",
};

test("Fast·모델·추론 변경은 기존 CLI 세션을 유지한다", () => {
  for (const changed of [
    { fastMode: false },
    { model: "gpt-5.6-terra" },
    { effort: "xhigh" },
    {
      model: "gpt-5.6-luna",
      effort: "max",
      fastMode: false,
    },
  ]) {
    assert.equal(
      characterSettingsRequireNewSession(current, {
        ...current,
        ...changed,
      }),
      false,
    );
  }
});

test("권한 변경도 기존 CLI 세션을 유지한다", () => {
  assert.equal(
    characterSettingsRequireNewSession(current, {
      ...current,
      permission: "danger-full-access",
    }),
    false,
  );
});

test("CLI 종류 변경만 새 세션을 요구한다", () => {
  assert.equal(
    characterSettingsRequireNewSession(current, {
      ...current,
      backend: "claude",
    }),
    true,
  );
});
