// 이 파일은 생성 이미지 탐색과 Markdown 미리보기 첨부를 검증한다.

import assert from "node:assert/strict";
import fs from "node:fs";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

import {
  appendLocalImagePreviews,
  generatedImageRoot,
  generatedImagesForTurn,
  listGeneratedImages,
} from "../src/local-artifacts.mjs";

for (const code of ["EPERM", "EACCES", "ENOENT", "ENOTDIR", "EIO", "ESTALE", "ENXIO"]) {
  test(`생성 이미지 폴더 ${code} 오류가 대화 조회를 막지 않는다`, (t) => {
    const root = mkdtempSync(join(tmpdir(), "officellm-unavailable-images-"));
    const sessionDirectory = join(root, "session-1");
    mkdirSync(sessionDirectory);
    const originalReaddir = fs.readdirSync;
    const mocked = t.mock.method(fs, "readdirSync", (path, ...args) => {
      if (path === sessionDirectory) {
        throw Object.assign(new Error(`scandir ${code}`), { code });
      }
      return originalReaddir(path, ...args);
    });
    syncBuiltinESMExports();
    try {
      assert.deepEqual(listGeneratedImages("session-1", root), []);
      const images = generatedImagesForTurn({
        sessionID: "session-1",
        startedAt: "2026-09-05T00:00:00Z",
        endedAt: "2026-09-05T01:00:00Z",
        generatedRoot: root,
      });
      assert.equal(appendLocalImagePreviews("대화 본문은 유지", images), "대화 본문은 유지");
    } finally {
      mocked.mock.restore();
      syncBuiltinESMExports();
      rmSync(root, { recursive: true, force: true });
    }
  });
}

test("이미지 탐색 후 파일이 사라져도 다른 이미지와 대화는 유지한다", (t) => {
  const root = mkdtempSync(join(tmpdir(), "officellm-disappearing-image-"));
  const sessionDirectory = join(root, "session-1");
  mkdirSync(sessionDirectory);
  const missingImage = join(sessionDirectory, "missing.png");
  const visibleImage = join(sessionDirectory, "visible.png");
  const generatedAt = new Date("2026-09-05T00:30:00Z");
  for (const image of [missingImage, visibleImage]) {
    writeFileSync(image, "png");
    utimesSync(image, generatedAt, generatedAt);
  }
  let missingImageStatCount = 0;
  const originalStat = fs.statSync;
  const mocked = t.mock.method(fs, "statSync", (path, ...args) => {
    if (path === missingImage && ++missingImageStatCount > 1) {
      throw Object.assign(new Error("image disappeared"), { code: "ENOENT" });
    }
    return originalStat(path, ...args);
  });
  syncBuiltinESMExports();
  try {
    assert.deepEqual(generatedImagesForTurn({
      sessionID: "session-1",
      startedAt: "2026-09-05T00:00:00Z",
      endedAt: "2026-09-05T01:00:00Z",
      generatedRoot: root,
    }), [visibleImage]);
  } finally {
    mocked.mock.restore();
    syncBuiltinESMExports();
    rmSync(root, { recursive: true, force: true });
  }
});

test("Antigravity 생성 이미지는 전용 brain 디렉터리에서 찾는다", () => {
  assert.match(
    generatedImageRoot("antigravity"),
    /\.gemini\/antigravity-cli\/brain$/,
  );
  assert.match(
    generatedImageRoot("codex"),
    /\.codex\/generated_images$/,
  );
});

test("절대경로 이미지 링크에 미리보기를 추가한다", () => {
  const directory = mkdtempSync(join(tmpdir(), "officellm-artifact-"));
  try {
    const image = join(directory, "sample image.png");
    writeFileSync(image, "png");

    const rendered = appendLocalImagePreviews(
      `[이미지 열기](<${image}>)`,
    );

    assert.match(
      rendered,
      /\[!\[생성 이미지 1\]\(<file:\/\/\/.*>\)\]\(<file:\/\/\//,
    );
    assert.equal(
      appendLocalImagePreviews(rendered),
      rendered,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("이미 표시된 이미지는 중복 첨부하지 않는다", () => {
  const directory = mkdtempSync(join(tmpdir(), "officellm-artifact-"));
  try {
    const image = join(directory, "sample.png");
    writeFileSync(image, "png");
    const markdown = `![결과](<${image}>)`;

    assert.equal(
      appendLocalImagePreviews(markdown, [image]),
      markdown,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("프로젝트 복사본과 생성 원본이 같으면 미리보기 하나만 붙인다", () => {
  const directory = mkdtempSync(join(tmpdir(), "officellm-artifact-"));
  try {
    const generated = join(directory, "generated.png");
    const projectCopy = join(directory, "episode-03.png");
    writeFileSync(generated, "same-image-bytes");
    writeFileSync(projectCopy, "same-image-bytes");

    const rendered = appendLocalImagePreviews(
      `[결과 파일](<${projectCopy}>)`,
      [generated],
    );

    assert.equal((rendered.match(/\[!\[생성 이미지/g) ?? []).length, 1);
    assert.ok(rendered.includes(pathToFileURL(projectCopy).href));
    assert.ok(!rendered.includes(pathToFileURL(generated).href));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("크기가 같아도 내용이 다른 이미지는 각각 미리보기를 붙인다", () => {
  const directory = mkdtempSync(join(tmpdir(), "officellm-artifact-"));
  try {
    const first = join(directory, "first.png");
    const second = join(directory, "second.png");
    writeFileSync(first, "image-a");
    writeFileSync(second, "image-b");

    const rendered = appendLocalImagePreviews("완료", [first, second]);

    assert.equal((rendered.match(/\[!\[생성 이미지/g) ?? []).length, 2);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("업무 시간에 생성된 이미지만 찾는다", () => {
  const root = mkdtempSync(join(tmpdir(), "officellm-generated-"));
  try {
    const sessionID = "session-1";
    const sessionDirectory = join(root, sessionID);
    mkdirSync(sessionDirectory);
    const image = join(sessionDirectory, "generated.png");
    writeFileSync(image, "png");
    const generatedAt = new Date("2026-07-27T12:51:32Z");
    utimesSync(image, generatedAt, generatedAt);

    assert.deepEqual(
      generatedImagesForTurn({
        sessionID: "session-1",
        startedAt: "2026-07-27T12:49:55Z",
        endedAt: "2026-07-27T12:51:36Z",
        generatedRoot: root,
      }),
      [image],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
