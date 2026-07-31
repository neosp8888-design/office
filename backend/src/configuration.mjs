// 이 파일은 캐릭터 JSON 설정을 읽어 PostgreSQL 기본 데이터와 동기화한다.

import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const backendDirectory = resolve(
  fileURLToPath(new URL("..", import.meta.url)),
  "..",
);

export function characterConfigPath() {
  return resolve(
    backendDirectory,
    process.env.CHARACTER_CONFIG_PATH ??
      "Sources/OfficeCore/Resources/characters.json",
  );
}

export async function readCharacterConfiguration() {
  const source = await readFile(characterConfigPath(), "utf8");
  return JSON.parse(source);
}

export async function syncCharacters(client, configuration) {
  for (const character of configuration.characters) {
    await client.query(
      `
        INSERT INTO characters (
          id,
          name,
          seat,
          backend,
          identity_prompt,
          model,
          effort,
          fast_mode,
          permission,
          config
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)
        ON CONFLICT (id) DO UPDATE
        SET
          seat = EXCLUDED.seat,
          updated_at = now()
      `,
      [
        character.id,
        character.name,
        character.seat,
        character.backend,
        character.identityPrompt,
        character.model,
        character.effort,
        character.fastMode ?? true,
        character.permission,
        JSON.stringify(character),
      ],
    );
  }
}
