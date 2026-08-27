// Antigravity 1.1.x가 요구하는 Playwright 1.57 드라이버를 번들 의존성으로 제공한다.

import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ANTIGRAVITY_PLAYWRIGHT_VERSION = "1.57.0";

export function antigravityPlaywrightDriverDirectory() {
  return resolve(
    dirname(fileURLToPath(import.meta.url)),
    `playwright-driver-${ANTIGRAVITY_PLAYWRIGHT_VERSION}`,
  );
}

export function antigravityPlaywrightEnvironment(
  baseEnvironment = process.env,
  {
    driverDirectory = antigravityPlaywrightDriverDirectory(),
    nodeExecutable = process.execPath,
  } = {},
) {
  const environment = { ...baseEnvironment };
  if (!existsSync(resolve(driverDirectory, "package", "cli.js"))) {
    return environment;
  }
  environment.PLAYWRIGHT_DRIVER_PATH ??= driverDirectory;
  environment.PLAYWRIGHT_NODEJS_PATH ??= nodeExecutable;
  return environment;
}
