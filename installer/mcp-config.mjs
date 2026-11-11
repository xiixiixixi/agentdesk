// installer/mcp-config.mjs —— 把 agentdesk 自动接进本机已安装的 AI 客户端。
//
// v1.0.3：setup 一条命令除了装扩展/助手/配置，还会检测并写入这些客户端的 MCP 配置：
//   - Codex            ~/.codex/config.toml              （追加 [mcp_servers.agentdesk]）
//   - Claude Code      ~/.claude.json                    （mcpServers.agentdesk）
//   - Claude Desktop   ~/Library/Application Support/Claude/claude_desktop_config.json
//   - Cursor           ~/.cursor/mcp.json
//   - DeepSeek Harness ~/.dsh/cordis.patch.yml           （YAML 追加 dsh-mcp-client 条目）
//
// 原则：只改检测到的文件；写前留 .bak-agentdesk-<ts> 备份；已存在同名条目就跳过（幂等）；
// 解析失败/格式不对 → 报 skip 不碰原文件。--dry-run 只报告不落盘。

import { existsSync, readFileSync, writeFileSync, copyFileSync } from 'node:fs';
import path from 'node:path';

export const MCP_SERVER_NAME = 'agentdesk';
export const MCP_PACKAGE = '@xiixiixixi/agentdesk';

/** MCP 客户端里该怎么拉起服务：npm 全局安装用 node+入口；npx 临时安装用 npx 拉包。 */
export function buildServerCommand({ nodePath, entryPath, npx = false } = {}) {
  if (npx) return { command: 'npx', args: ['-y', '--package=' + MCP_PACKAGE, 'agentdesk-mcp'] };
  return { command: nodePath || 'node', args: [entryPath] };
}

/** 本机存在哪些客户端的配置文件（存在即视为已安装）。 */
export function detectMcpClients(home) {
  const specs = [
    { label: 'Codex', file: path.join(home, '.codex', 'config.toml'), kind: 'codex' },
    { label: 'Claude Code', file: path.join(home, '.claude.json'), kind: 'json' },
    { label: 'Claude Desktop', file: path.join(home, 'Library', 'Application Support', 'Claude', 'claude_desktop_config.json'), kind: 'json' },
    { label: 'Cursor', file: path.join(home, '.cursor', 'mcp.json'), kind: 'json' },
    { label: 'DeepSeek Harness', file: path.join(home, '.dsh', 'cordis.patch.yml'), kind: 'dsh' },
  ];
  return specs.filter((s) => existsSync(s.file));
}

const tomlStr = (v) => JSON.stringify(String(v));
const yamlStr = (v) => JSON.stringify(String(v)); // JSON 双引号字符串是合法 YAML

function backup(file, ts, dryRun, results, label) {
  if (dryRun) return;
  try { copyFileSync(file, `${file}.bak-agentdesk-${ts}`); } catch (e) {
    results.push({ label, file, status: 'error', reason: '备份失败: ' + e.message });
  }
}

function writeJsonClient(client, server, opts, results) {
  const { dryRun, ts } = opts;
  let doc;
  try { doc = JSON.parse(readFileSync(client.file, 'utf8')); } catch {
    results.push({ label: client.label, file: client.file, status: 'skip', reason: '不是合法 JSON，未改动' });
    return;
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    results.push({ label: client.label, file: client.file, status: 'skip', reason: 'JSON 顶层不是对象，未改动' });
    return;
  }
  const servers = (doc.mcpServers && typeof doc.mcpServers === 'object' && !Array.isArray(doc.mcpServers)) ? doc.mcpServers : {};
  if (servers[MCP_SERVER_NAME]) {
    results.push({ label: client.label, file: client.file, status: 'exists' });
    return;
  }
  servers[MCP_SERVER_NAME] = { type: 'stdio', command: server.command, args: server.args };
  doc.mcpServers = servers;
  if (!dryRun) {
    backup(client.file, ts, dryRun, results, client.label);
    writeFileSync(client.file, JSON.stringify(doc, null, 2) + '\n');
  }
  results.push({ label: client.label, file: client.file, status: dryRun ? 'would-write' : 'written' });
}

function writeCodex(client, server, opts, results) {
  const { dryRun, ts } = opts;
  const text = readFileSync(client.file, 'utf8');
  if (/^\s*\[mcp_servers\.agentdesk\]/m.test(text)) {
    results.push({ label: client.label, file: client.file, status: 'exists' });
    return;
  }
  const block = [
    '',
    `[mcp_servers.${MCP_SERVER_NAME}]`,
    `command = ${tomlStr(server.command)}`,
    `args = [ ${server.args.map(tomlStr).join(', ')} ]`,
    'startup_timeout_sec = 60',
    '',
  ].join('\n');
  if (!dryRun) {
    backup(client.file, ts, dryRun, results, client.label);
    writeFileSync(client.file, text.replace(/\n*$/, '\n') + block);
  }
  results.push({ label: client.label, file: client.file, status: dryRun ? 'would-write' : 'written' });
}

function writeDsh(client, server, opts, results) {
  const { dryRun, ts } = opts;
  const text = readFileSync(client.file, 'utf8');
  if (/\bid:\s*agentdesk-mcp\b/.test(text)) {
    results.push({ label: client.label, file: client.file, status: 'exists' });
    return;
  }
  if (!/^\s*-\s*insert:/m.test(text)) {
    results.push({ label: client.label, file: client.file, status: 'skip', reason: '不是预期的 DSH 配置结构，未改动' });
    return;
  }
  const block = [
    '  - id: agentdesk-mcp',
    "    name: '@deepseek-ai/dsh-mcp-client'",
    '    config:',
    '      serverName: agentdesk',
    '      transport: stdio',
    `      command: ${yamlStr(server.command)}`,
    '      args:',
    `      - ${yamlStr(server.args[0])}`,
    '      toolCallTimeoutMs: 120000',
    '',
  ].join('\n');
  if (!dryRun) {
    backup(client.file, ts, dryRun, results, client.label);
    writeFileSync(client.file, text.replace(/\n*$/, '\n') + block);
  }
  results.push({ label: client.label, file: client.file, status: dryRun ? 'would-write' : 'written' });
}

/**
 * 写入（或 dry-run 报告）各客户端 MCP 配置。
 * @returns {Array<{label,file,status:'written'|'would-write'|'exists'|'skip'|'error',reason?}>}
 */
export function applyMcpConfigs({ home, nodePath, entryPath, npx = false, dryRun = false, now = Date.now() }) {
  const clients = detectMcpClients(home);
  const results = [];
  if (!clients.length) return results;
  const server = buildServerCommand({ nodePath, entryPath, npx });
  const ts = new Date(now).toISOString().replace(/[:.]/g, '-');
  const opts = { dryRun, ts };
  for (const client of clients) {
    try {
      if (client.kind === 'codex') writeCodex(client, server, opts, results);
      else if (client.kind === 'dsh') writeDsh(client, server, opts, results);
      else writeJsonClient(client, server, opts, results);
    } catch (e) {
      results.push({ label: client.label, file: client.file, status: 'error', reason: e.message });
    }
  }
  return results;
}
