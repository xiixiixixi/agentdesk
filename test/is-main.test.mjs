// test/is-main.test.mjs — shared/is-main.mjs 统一入口守护的测试
//
//   背景：npm 全局 bin 是指向入口文件的符号链接（shebang 以链接路径作 argv[1]），
//   而 ESM 的 import.meta.url 是真实路径——守护若直接比较两者则永不相等，
//   main() 不执行、进程静默退出 0（v1.1.1 在 mcp-entry.mjs 修过一处，v1.1.2 起统一走本助手）。
//   用临时目录里的夹具文件 + 子进程覆盖四种调用形态：真实路径 / 符号链接 / 相对路径 / 被 import。

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const IS_MAIN = path.join(HERE, '..', 'shared', 'is-main.mjs');

/** 夹具：与真实入口同构（isMain 为真时才执行副作用）。 */
const FIXTURE = [
  `import { isMain } from ${JSON.stringify(pathToFileURL(IS_MAIN).href)};`,
  'if (isMain(import.meta.url)) console.log("MAIN-RUNS");',
].join('\n');

function run(args, opts = {}) {
  const r = spawnSync(process.execPath, args, { encoding: 'utf8', ...opts });
  assert.equal(r.status, 0, `夹具进程异常退出：\nstderr: ${r.stderr}`);
  return r.stdout;
}

test('真实路径直接运行 → isMain 真（MAIN-RUNS）', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'ab-ismain-'));
  try {
    const fixture = path.join(dir, 'main-check.mjs');
    writeFileSync(fixture, FIXTURE);
    const out = run([fixture]);
    assert.match(out, /MAIN-RUNS/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('符号链接运行（npm bin 形态）→ isMain 仍真（回归守护）', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'ab-ismain-'));
  try {
    const fixture = path.join(dir, 'main-check.mjs');
    writeFileSync(fixture, FIXTURE);
    const linked = path.join(dir, 'agentdesk-fixture'); // 模拟 npm 全局 bin 的符号链接
    symlinkSync(fixture, linked);
    const out = run([linked]);
    assert.match(out, /MAIN-RUNS/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('相对路径直接运行（cwd 解析）→ isMain 真', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'ab-ismain-'));
  try {
    writeFileSync(path.join(dir, 'main-check.mjs'), FIXTURE);
    const out = run(['main-check.mjs'], { cwd: dir });
    assert.match(out, /MAIN-RUNS/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('被 import → isMain 假（不执行副作用）', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'ab-ismain-'));
  try {
    writeFileSync(path.join(dir, 'main-check.mjs'), FIXTURE);
    writeFileSync(path.join(dir, 'importer.mjs'),
      `import "./main-check.mjs";\nconsole.log("IMPORTER-DONE");\n`);
    const out = run([path.join(dir, 'importer.mjs')]);
    assert.doesNotMatch(out, /MAIN-RUNS/);
    assert.match(out, /IMPORTER-DONE/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
