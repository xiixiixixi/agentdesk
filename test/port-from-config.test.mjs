// test/port-from-config.test.mjs — 无 --port 参数时从 host/host-config.json 取端口的测试
//
//   端口优先级：--port 参数 > setup 写入的 host/host-config.json > 默认 7331。
//   v1.1.3 前的 bug：mcp-entry.mjs 的读取段用了 path.dirname 却只 import 了 { resolve }，
//   ReferenceError 被空 catch 吞掉 → 永远回落默认 7331；而浏览器扩展按 host-config 拨号，
//   两边端口不一致 = MCP 客户端拉起的服务永远连不上浏览器（setup 验证能过是因为它显式传 --port）。
//   本文件临时写一份 host-config 到仓库 host/ 目录（平时不存在、不入库），spawn 无 --port 的
//   mcp-entry 进程，断言就绪日志报配置端口；结束恢复原状。
//   注意：仓库其他测试 spawn mcp-entry 时都显式带 --port，不受本文件临时配置影响。

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MCP_ENTRY = path.join(HERE, '..', 'service', 'mcp-entry.mjs');
const HOST_CONFIG = path.join(HERE, '..', 'host', 'host-config.json');

const freePort = () => new Promise((resolve, reject) => {
  const srv = net.createServer();
  srv.listen(0, '127.0.0.1', () => { const { port } = srv.address(); srv.close(() => resolve(port)); });
  srv.once('error', reject);
});

function waitUntil(predicate, { timeoutMs = 15_000, intervalMs = 25 } = {}) {
  return new Promise((resolve, reject) => {
    const startedAt = Date.now();
    const tick = () => {
      let ok;
      try { ok = predicate(); } catch (err) { reject(err); return; }
      if (ok) { resolve(); return; }
      if (Date.now() - startedAt > timeoutMs) { reject(new Error('waitUntil timed out')); return; }
      setTimeout(tick, intervalMs);
    };
    tick();
  });
}

test('无 --port：host-config.json 存在时服务监听配置端口（而非默认 7331）', { timeout: 30_000 }, async () => {
  const port = await freePort();
  const hadConfig = existsSync(HOST_CONFIG);
  const backup = hadConfig ? readFileSync(HOST_CONFIG, 'utf8') : null;
  writeFileSync(HOST_CONFIG, JSON.stringify({ schemaVersion: 1, serviceHost: '127.0.0.1', servicePort: port }));

  const child = spawn(process.execPath, [MCP_ENTRY], { stdio: ['pipe', 'pipe', 'pipe'] });
  let err = '';
  child.stderr.on('data', (c) => { err += c.toString(); });
  try {
    await waitUntil(() => /MCP stdio ready|frontend mode|fatal/.test(err) || child.exitCode !== null);
    // bug 形态：就绪日志报默认 7331（或读取段异常被吞后照常起服务），而非 host-config 里的端口
    assert.match(err, new RegExp(`MCP stdio ready; service ws://127\\.0\\.0\\.1:${port}`),
      `应监听 host-config 配置的端口 ${port}，实际日志：${err.trim().split('\n').pop() || '(空)'}`);
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL');
    if (backup !== null) writeFileSync(HOST_CONFIG, backup); // 恢复原文件
    else rmSync(HOST_CONFIG); // 原本不存在 → 删除临时配置
  }
});
