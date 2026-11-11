// test/mcp-config.test.mjs —— v1.0.3 setup 自动写 MCP 客户端配置
//
// 覆盖：检测已有客户端 → 幂等写入（Codex TOML / Claude JSON / Cursor JSON / DSH YAML）、
// 备份文件、dry-run 不落盘、坏 JSON 不破坏原文件、npx 临时安装用 npx 命令形式。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { applyMcpConfigs, buildServerCommand, detectMcpClients } from '../installer/mcp-config.mjs';

const NODE = '/usr/local/bin/node';
const ENTRY = '/opt/agentdesk/service/mcp-entry.mjs';

function makeHome(files) {
  const home = mkdtempSync(path.join(os.tmpdir(), 'agentdesk-mcpcfg-'));
  for (const [rel, content] of Object.entries(files)) {
    const p = path.join(home, rel);
    mkdirSync(path.dirname(p), { recursive: true });
    writeFileSync(p, content);
  }
  return home;
}

test('buildServerCommand：node 安装用 node+入口，npx 安装用 npx 拉包', () => {
  assert.deepEqual(buildServerCommand({ nodePath: NODE, entryPath: ENTRY, npx: false }), { command: NODE, args: [ENTRY] });
  assert.deepEqual(buildServerCommand({ entryPath: ENTRY, npx: true }), { command: 'npx', args: ['-y', '--package=@xiixiixixi/agentdesk', 'agentdesk-mcp'] });
});

test('检测并写入 4 个客户端；重复执行幂等；留备份', () => {
  const home = makeHome({
    '.codex/config.toml': 'model = "gpt-test"\n',
    '.claude.json': JSON.stringify({ mcpServers: { other: { command: 'x' } } }),
    '.cursor/mcp.json': '{}',
    '.dsh/cordis.patch.yml': '- insert:\n  - id: existing-mcp\n    name: x\n',
  });
  const clients = detectMcpClients(home).map((c) => c.label);
  assert.deepEqual(clients.sort(), ['Claude Code', 'Codex', 'Cursor', 'DeepSeek Harness']);

  const r1 = applyMcpConfigs({ home, nodePath: NODE, entryPath: ENTRY });
  assert.deepEqual(r1.map((r) => r.status), ['written', 'written', 'written', 'written']);

  const codex = readFileSync(path.join(home, '.codex/config.toml'), 'utf8');
  assert.match(codex, /\[mcp_servers\.agentdesk\]/);
  assert.match(codex, new RegExp(`command = ${JSON.stringify(NODE).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
  assert.match(codex, /args = \[ "\/opt\/agentdesk\/service\/mcp-entry\.mjs" \]/);
  assert.match(codex, /model = "gpt-test"/); // 原有内容保留

  const claude = JSON.parse(readFileSync(path.join(home, '.claude.json'), 'utf8'));
  assert.equal(claude.mcpServers.agentdesk.type, 'stdio');
  assert.equal(claude.mcpServers.agentdesk.command, NODE);
  assert.deepEqual(claude.mcpServers.agentdesk.args, [ENTRY]);
  assert.ok(claude.mcpServers.other, '原有 MCP 配置保留');

  const cursor = JSON.parse(readFileSync(path.join(home, '.cursor/mcp.json'), 'utf8'));
  assert.equal(cursor.mcpServers.agentdesk.command, NODE);

  const dsh = readFileSync(path.join(home, '.dsh/cordis.patch.yml'), 'utf8');
  assert.match(dsh, /- id: agentdesk-mcp/);
  assert.match(dsh, /serverName: agentdesk/);
  assert.match(dsh, /- id: existing-mcp/); // 原有条目保留

  // 备份文件存在
  for (const rel of ['.codex/config.toml', '.claude.json', '.cursor/mcp.json', '.dsh/cordis.patch.yml']) {
    const dir = path.dirname(path.join(home, rel));
    assert.ok(readdirSync(dir).some((f) => f.includes('.bak-agentdesk-')), `${rel} 应有备份`);
  }

  // 幂等：再跑一遍全部 exists，且不重复追加
  const r2 = applyMcpConfigs({ home, nodePath: NODE, entryPath: ENTRY });
  assert.deepEqual(r2.map((r) => r.status), ['exists', 'exists', 'exists', 'exists']);
  assert.equal((readFileSync(path.join(home, '.codex/config.toml'), 'utf8').match(/\[mcp_servers\.agentdesk\]/g) || []).length, 1);
  assert.equal((readFileSync(path.join(home, '.dsh/cordis.patch.yml'), 'utf8').match(/id: agentdesk-mcp/g) || []).length, 1);
});

test('dry-run 只报告不落盘', () => {
  const home = makeHome({ '.codex/config.toml': 'a = 1\n', '.cursor/mcp.json': '{}' });
  const before = readFileSync(path.join(home, '.codex/config.toml'), 'utf8');
  const r = applyMcpConfigs({ home, nodePath: NODE, entryPath: ENTRY, dryRun: true });
  assert.deepEqual(r.map((x) => x.status), ['would-write', 'would-write']);
  assert.equal(readFileSync(path.join(home, '.codex/config.toml'), 'utf8'), before);
  assert.equal(readFileSync(path.join(home, '.cursor/mcp.json'), 'utf8'), '{}');
});

test('坏 JSON 不碰原文件；DSH 结构不符则跳过', () => {
  const home = makeHome({ '.claude.json': '{ broken', '.dsh/cordis.patch.yml': 'foo: bar\n' });
  const r = applyMcpConfigs({ home, nodePath: NODE, entryPath: ENTRY });
  assert.deepEqual(r.map((x) => x.status), ['skip', 'skip']);
  assert.equal(readFileSync(path.join(home, '.claude.json'), 'utf8'), '{ broken');
  assert.equal(readFileSync(path.join(home, '.dsh/cordis.patch.yml'), 'utf8'), 'foo: bar\n');
});

test('npx 模式写入 npx 命令', () => {
  const home = makeHome({ '.cursor/mcp.json': '{}' });
  applyMcpConfigs({ home, nodePath: NODE, entryPath: ENTRY, npx: true });
  const cursor = JSON.parse(readFileSync(path.join(home, '.cursor/mcp.json'), 'utf8'));
  assert.equal(cursor.mcpServers.agentdesk.command, 'npx');
  assert.deepEqual(cursor.mcpServers.agentdesk.args, ['-y', '--package=@xiixiixixi/agentdesk', 'agentdesk-mcp']);
});
