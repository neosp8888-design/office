#!/usr/bin/env node

// 앱에 포함되는 Node 백엔드 의존성의 라이선스 인덱스를 만든다.

import fs from "node:fs";
import path from "node:path";

const [lockPath, outputPath] = process.argv.slice(2);
if (!lockPath || !outputPath) {
  console.error(
    "사용법: generate-third-party-notices.mjs <package-lock.json> <output.md>",
  );
  process.exit(2);
}

const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
const lockDirectory = path.dirname(lockPath);

function embeddedLicenseFromReadme(packageDirectory) {
  const readmeFile = fs.readdirSync(packageDirectory).find((name) => {
    return /^readme(?:\.[^.]+)?$/i.test(name);
  });
  if (!readmeFile) return null;

  const readme = fs.readFileSync(path.join(packageDirectory, readmeFile), "utf8");
  const lines = readme.split(/\r?\n/);
  const headingIndex = lines.findIndex((line) => {
    return /^\s{0,3}#{1,6}\s+licen[sc]e\s*#*\s*$/i.test(line);
  });
  if (headingIndex < 0) return null;

  const nextHeadingOffset = lines.slice(headingIndex + 1).findIndex((line) => {
    return /^\s{0,3}#{1,6}\s+\S/.test(line);
  });
  const endIndex = nextHeadingOffset < 0
    ? lines.length
    : headingIndex + 1 + nextHeadingOffset;
  const text = lines.slice(headingIndex + 1, endIndex).join("\n").trim();
  if (text.length < 100) return null;

  return { source: readmeFile, text };
}

const packages = Object.entries(lock.packages ?? {})
  .filter(([packagePath]) => {
    return packagePath.startsWith("node_modules/")
      && fs.existsSync(path.join(lockDirectory, packagePath, "package.json"));
  })
  .map(([packagePath, metadata]) => {
    const packageDirectory = path.join(lockDirectory, packagePath);
    const licenseFile = fs.readdirSync(packageDirectory).find((name) => {
      return /^(?:licen[sc]e|copying|notice)/i.test(name);
    });
    const embeddedLicense = licenseFile
      ? null
      : embeddedLicenseFromReadme(packageDirectory);
    if (!licenseFile && !embeddedLicense) {
      throw new Error(`라이선스 파일이 없는 배포 의존성입니다: ${packagePath}`);
    }
    return {
      name: metadata.name ?? packagePath.replace(/^node_modules\//, ""),
      version: metadata.version ?? "unknown",
      license: metadata.license ?? "UNKNOWN",
      packagePath,
      licenseFile,
      embeddedLicense,
    };
  })
  .sort((left, right) => left.name.localeCompare(right.name));

if (packages.length === 0) {
  throw new Error("package-lock.json에서 배포 의존성을 찾지 못했습니다.");
}

const lines = [
  "# OFFICESTRA Third-Party Notices",
  "",
  "This app bundles the Node.js runtime and the production packages listed below.",
  "The complete Node.js license is included as `Node-LICENSE`. Each npm package",
  "keeps its own license file or complete license section in its README under",
  "the bundled `backend/node_modules` directory. For packages without a separate",
  "license file, that license text is also reproduced below.",
  "",
  "| Package | Version | License |",
  "| --- | --- | --- |",
  ...packages.map(
    ({ name, version, license }) => `| ${name} | ${version} | ${license} |`,
  ),
  "",
  ...packages
    .filter(({ embeddedLicense }) => embeddedLicense)
    .flatMap(({ name, version, packagePath, embeddedLicense }) => [
      `## Embedded license: ${name} ${version}`,
      "",
      `Source: \`${packagePath}/${embeddedLicense.source}\``,
      "",
      embeddedLicense.text,
      "",
    ]),
];

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${lines.join("\n")}\n`);
