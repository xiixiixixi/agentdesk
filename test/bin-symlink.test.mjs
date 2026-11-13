// test/bin-symlink.test.mjs — npm bin 符号链接调用的入口守护测试
//
//   npm 全局安装后 ~/.npm-global/bin/agentdesk-mcp 是指向 service/mcp-entry.mjs 的符号链接，
//   shebang 以符号链接路径作为 argv[1] 启动。ESM 的 import.meta.url 解析为真实路径，
//   入口守护若直接比较两者 → 永不相等 → main() 不执行、进程静默退出 0。
//   本文件守护两件事：
//     1. 符号链接与真实路径两种 argv[1] 形态都必须启动 MCP（npm bin 可用）；
//     2. 被 import 时仍不得自动执行（守护存在的意义，主测试文件依赖它）。

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MCP_ENTRY = path.join(HERE, '..', 'service', 'mcp-entry.mjs');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

/** 子进程已退出时返回退出码（被信号杀死返回 signal:xxx）；未退出返回 null。 */
const exitCodeOf = (child) =>
  (child.exitCode !== null || child.signalCode !== null ? child.exitCode ?? `signal:${child.signalCode}` : null);

const exitOf = (child) => new Promise((resolve) => {
  const done = exitCodeOf(child);
  if (done !== null) { resolve(done); return; }
  child.once('exit', (code, signal) => resolve(code ?? `signal:${signal}`));
});

/** 极简 MCP-over-stdio 客户端（换行分隔 JSON-RPC），同 multi-frontend.test.mjs。 */
function mcpStdio(child) {
  const pending = new Map();
  let nextId = 1;
  let buf = '';
  child.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let idx;
    while ((idx = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, idx).replace(/\r$/, '');
      buf = buf.slice(idx + 1);
      if (!line) continue;
      let msg; try { msg = JSON.parse(line); } catch { continue; }
      const slot = pending.get(msg.id);
      if (slot) { pending.delete(msg.id); clearTimeout(slot.timer); slot.resolve(msg); }
    }
  });
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`stdio request timeout: ${method}`)); }, 10_000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
  });
  const notify = (method) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method })}\n`);
  return { request, notify };
}

test('符号链接 argv[1]（npm bin 形态）也启动 MCP：就绪日志 + 完整握手', { timeout: 60_000 }, async () => {
  const port = await freePort();
  const dir = mkdtempSync(path.join(tmpdir(), 'ab-bin-link-'));
  const linkedBin = path.join(dir, 'agentdesk-mcp'); // 与 npm 全局 bin 同名同形态：指向真实入口的符号链接
  symlinkSync(MCP_ENTRY, linkedBin);

  const child = spawn(process.execPath, [linkedBin, '--port', String(port)], { stdio: ['pipe', 'pipe', 'pipe'] });
  let err = '';
  child.stderr.on('data', (c) => { err += c.toString(); });
  try {
    await waitUntil(() => /MCP stdio ready|frontend mode/.test(err) || exitCodeOf(child) !== null);
    assert.equal(exitCodeOf(child), null,
      `符号链接启动即静默退出（exit=${exitCodeOf(child)}，stderr=${err.trim() || '(空)'}）—— npm bin agentdesk-mcp 不可用`);
    assert.match(err, /MCP stdio ready|frontend mode/);

    const client = mcpStdio(child);
    const init = await client.request('initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'bin-symlink-test', version: '0.0.1' },
    });
    assert.equal(init.result.serverInfo.name, 'agentdesk');
    client.notify('notifications/initialized');
    const tools = await client.request('tools/list', {});
    assert.ok(tools.result.tools.length > 0, '符号链接形态下工具面应为空数组之外的结果');
    child.stdin.end();
    assert.equal(await exitOf(child), 0, 'stdin EOF 后应干净退出');
  } finally {
    if (exitCodeOf(child) === null) child.kill('SIGKILL');
    rmSync(dir, { recursive: true, force: true });
  }
});

test('真实路径 argv[1]（node service/mcp-entry.mjs 形态）不被修复破坏', { timeout: 60_000 }, async () => {
  const port = await freePort();
  const child = spawn(process.execPath, [MCP_ENTRY, '--port', String(port)], { stdio: ['pipe', 'pipe', 'pipe'] });
  let err = '';
  child.stderr.on('data', (c) => { err += c.toString(); });
  try {
    await waitUntil(() => /MCP stdio ready|frontend mode/.test(err) || exitCodeOf(child) !== null);
    assert.equal(exitCodeOf(child), null, `直接路径启动失败（stderr=${err.trim()}）`);
    child.stdin.end();
    assert.equal(await exitOf(child), 0);
  } finally {
    if (exitCodeOf(child) === null) child.kill('SIGKILL');
  }
});

test('import 入口模块不自动执行（守护对 import 仍生效）', async () => {
  // 若守护被改坏为无条件执行，import 会因 main() 常驻 Promise 而挂住不返回
  const mod = await Promise.race([
    import('../service/mcp-entry.mjs'),
    sleep(3_000).then(() => assert.fail('import 挂住未返回：入口被误自动执行')),
  ]);
  assert.equal(typeof mod.main, 'function');
});
