#!/usr/bin/env node
// setup.mjs —— 一条命令安装：自动算扩展 ID → 写直连配置（token/端口）→
// 打开 Chrome 扩展页（路径已进剪贴板）→ 原地等待扩展回连验证 → 打印 MCP 配置。
//
// v1.0.1：默认走「扩展直连本地 service」（WebSocket）——不再写浏览器 native messaging
// 清单，安装只剩「加载已解压扩展」这一下手动步骤。加 --native-host 可保留旧方案（兼容）。
//
// 用法：node setup.mjs [--dry-run] [--port N] [--timeout 秒] [--browser all|chrome|…|vivaldi] [--home DIR] [--native-host]
// 唯一的手动步：在 Chrome 的「加载已解压的扩展程序」里选中 extension 目录。

import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { once } from 'node:events';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import net from 'node:net';
import { fileURLToPath } from 'node:url';

import {
  computeExtensionId, parseArgs as parseInstallArgs, runInstall, FAMILY_NAMES,
  manifestPathsForFamily, NATIVE_HOST_NAME,
} from './installer/install.mjs';
import { installedBrowsers } from './installer/discovery.mjs';
import { ConnectionManager } from './service/connection.mjs';
import { compileHelper, createCua } from './service/cua.mjs';
import { ensureCuaHelperApp } from './service/cua-app.mjs';
import { missingPermissions, showGuideCards } from './service/cua-guide.mjs';
import { applyMcpConfigs } from './installer/mcp-config.mjs';

// setup.mjs 位于仓库根，REPO_ROOT 就是它所在目录（此前误用 '..' 多退一级）
const REPO_ROOT = path.dirname(fileURLToPath(import.meta.url));
const EXT_DIR = path.join(REPO_ROOT, 'extension');

const log = (s) => console.log(s);
const isMac = process.platform === 'darwin';

function parseArgs(argv) {
  const out = { dryRun: false, port: null, timeoutSec: 240, browser: null, home: null, noOpen: false, nativeHost: false, noMcpConfig: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => { const v = argv[++i]; if (v === undefined) throw new Error(`missing value for ${a}`); return v; };
    if (a === '--dry-run') out.dryRun = true;
    else if (a === '--no-open') out.noOpen = true;
    else if (a === '--native-host') out.nativeHost = true; // 兼容旧方案：写浏览器 native messaging 清单
    else if (a === '--no-mcp-config') out.noMcpConfig = true; // 不自动写 Codex/Claude/Cursor/DSH 的 MCP 配置
    else if (a === '--port') out.port = Number(next());
    else if (a === '--timeout') out.timeoutSec = Number(next());
    else if (a === '--browser') out.browser = next();
    else if (a === '--home') out.home = path.resolve(next());
    else if (a === '--help' || a === '-h') { log('usage: node setup.mjs [--dry-run] [--port N] [--timeout 秒] [--browser all|chrome|…|vivaldi] [--home DIR] [--native-host] [--no-mcp-config]'); process.exit(0); }
    else throw new Error(`unknown argument: ${a}`);
  }
  return out;
}

function existsSyncSafe(p) {
  try { return existsSync(p); } catch { return false; }
}

const freePort = () => new Promise((res, rej) => {
  const s = net.createServer();
  s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => res(p)); });
  s.on('error', rej);
});

async function main() {
  const args = parseArgs(process.argv.slice(2));

  // 1. 检测浏览器
  let families;
  if (args.browser === 'all') families = FAMILY_NAMES;
  else if (args.browser) families = [args.browser];
  else {
    const found = installedBrowsers().map((b) => b.family);
    families = found.length ? [...new Set(found)] : ['chrome'];
  }
  log('① 检测到浏览器：' + families.join(', '));

  // 2. 算扩展 ID（路径指纹——必须用最终路径算，这就是不能挪目录的原因）
  const extId = computeExtensionId(EXT_DIR);
  log(`② 本机扩展 ID：${extId}`);

  // 3. 端口：指定 > 上一轮 host-config 里的 > 空闲端口
  let port = args.port;
  if (!port) {
    try {
      const prev = JSON.parse((await import('node:fs')).readFileSync(path.join(REPO_ROOT, 'host', 'host-config.json'), 'utf8'));
      if (Number.isInteger(prev.servicePort)) port = prev.servicePort;
    } catch { /* 首次安装没有旧配置 */ }
  }
  if (!port) port = await freePort();

  // 4. 落配置：
  //    默认 → host/host-config.json（端口）+ extension/runtime-config.json（直连 token/端口/扩展 ID）
  //    --native-host → 走旧安装器写浏览器 native messaging 清单 + shim（兼容）
  const homeDir = args.home ?? os.homedir();
  const hostConfigPath = path.join(REPO_ROOT, 'host', 'host-config.json');
  const runtimeConfigPath = path.join(EXT_DIR, 'runtime-config.json');
  if (args.nativeHost) {
    const installParsed = parseInstallArgs(['--browser', families[0], '--extension-id', extId, '--port', String(port), ...(args.home ? ['--home', args.home] : []), ...(args.dryRun ? ['--dry-run'] : [])]);
    for (const f of families) {
      installParsed.browser = f;
      await runInstall(installParsed);
    }
    log(`③ ${args.dryRun ? '[dry-run] 将写入' : '已写入'}原生宿主清单（${families.length} 个浏览器）+ 服务配置（端口 ${port}）`);
  } else {
    const token = randomBytes(24).toString('hex');
    const runtimeConfig = {
      schemaVersion: 1, mode: 'ws', port, token, extensionIds: [extId],
      updatedAt: new Date().toISOString(),
      note: 'setup.mjs 生成；扩展直连 ws://127.0.0.1:<port>，不需要浏览器 native messaging 清单',
    };
    // 清掉旧安装留下的 native 清单/shim（同机迁移到直连后避免双通道）
    const cleaned = [];
    for (const family of families) {
      for (const p of manifestPathsForFamily(family, { home: homeDir })) {
        try {
          if (!existsSyncSafe(p)) continue;
          const name = JSON.parse(readFileSync(p, 'utf8')).name;
          if (name !== NATIVE_HOST_NAME) continue;
          if (!args.dryRun) rmSync(p, { force: true });
          cleaned.push(p);
        } catch { /* 解析失败/删不掉就留着，不影响直连 */ }
      }
    }
    for (const f of ['agentdesk-host', 'agentdesk-host.cmd']) {
      const p = path.join(REPO_ROOT, 'host', f);
      try { if (existsSyncSafe(p)) { if (!args.dryRun) rmSync(p, { force: true }); cleaned.push(p); } } catch { /* 忽略 */ }
    }
    if (args.dryRun) {
      log(`③ [dry-run] 将写入直连配置：${runtimeConfigPath}（端口 ${port}、扩展 ID ${extId}、token 已生成）`);
      log(`   [dry-run] 将清理旧 native 清单 ${cleaned.length} 份、写 ${hostConfigPath}`);
      const mcpEntry0 = path.join(REPO_ROOT, 'service', 'mcp-entry.mjs');
      const npxMode0 = REPO_ROOT.includes(`${path.sep}_npx${path.sep}`);
      if (!args.noMcpConfig) {
        const dry = applyMcpConfigs({ home: homeDir, nodePath: process.execPath, entryPath: mcpEntry0, npx: npxMode0, dryRun: true });
        log('   [dry-run] MCP 客户端：' + (dry.length ? dry.map((r) => `${r.label}:${r.status}`).join('，') : '未检测到已安装客户端'));
      }
      log('dry-run 结束（未落盘、未启动验证）。');
      return 0;
    }
    mkdirSync(path.dirname(hostConfigPath), { recursive: true });
    writeFileSync(hostConfigPath, JSON.stringify({ schemaVersion: 1, serviceHost: '127.0.0.1', servicePort: port }, null, 2) + '\n');
    writeFileSync(runtimeConfigPath, JSON.stringify(runtimeConfig, null, 2) + '\n');
    log(`③ 已写入直连配置（端口 ${port}、扩展 ID ${extId}、一次性 token）${cleaned.length ? `；清理旧 native 清单 ${cleaned.length} 份` : ''}`);
    log('   模式：扩展直连 ws://127.0.0.1 —— 不需要浏览器 native messaging 清单（旧方案可用 --native-host 保留）');
  }
  // 供下方「等待回连」用：runtime config 已落盘，ConnectionManager 启动时会读取同一份 token/白名单

  // 5. 助手：打开 Chrome 扩展页 + 扩展路径进剪贴板（macOS）
  log('');
  log('④ 下面是唯一的手动步骤：');
  log(`   在 Chrome 打开 chrome://extensions → 右上角打开「开发者模式」→`);
  log(`   「加载已解压的扩展程序」→ 选择目录：`);
  log(`     ${EXT_DIR}`);
  if (isMac && !args.noOpen) {
    try { spawnSync('pbcopy', { input: EXT_DIR, stdio: ['pipe', 'ignore', 'ignore'] }); log('   （目录路径已复制到剪贴板，可直接粘贴）'); } catch { /* 无剪贴板则跳过 */ }
    try { spawn('open', ['-a', 'Google Chrome', 'chrome://extensions/'], { stdio: 'ignore', detached: true }).unref(); } catch { /* 打不开就算了 */ }
  }

  // 6. 原地等待扩展回连（真验证，不是假装成功）
  log('');
  log(`⑤ 等待扩展连入验证（最长 ${args.timeoutSec} 秒，加载完扩展那一刻会自动打钩）…`);
  const manager = new ConnectionManager({ port });
  await manager.start();
  const deadline = Date.now() + args.timeoutSec * 1000;
  let ok = false;
  try {
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('timeout')), deadline - Date.now());
      manager.once('browser', (c) => { clearTimeout(t); resolve(c); });
    });
    ok = true;
    log('   ✓ 全链路验证通过：扩展 → 服务（直连 WebSocket），通信正常！');
  } catch {
    log('   ✗ 等待超时。常见原因：还没在 Chrome 里加载扩展 / 加载后又挪动了目录 / 加载的目录不是上面这个路径。');
    log('     完成后随时重跑 node setup.mjs 再验证一次。');
  } finally {
    await manager.stop().catch(() => {});
  }

  // 7. 自动写入 MCP 客户端配置（v1.0.3）：检测到谁就写谁；已存在则跳过；--no-mcp-config 可关
  const entry = path.join(REPO_ROOT, 'service', 'mcp-entry.mjs');
  const npxMode = REPO_ROOT.includes(`${path.sep}_npx${path.sep}`);
  if (!args.noMcpConfig) {
    log('');
    log('⑥ 自动接入 MCP 客户端（检测到才写，写前备份，已存在跳过）…');
    const mcpResults = applyMcpConfigs({ home: homeDir, nodePath: process.execPath, entryPath: entry, npx: npxMode, dryRun: false });
    if (!mcpResults.length) {
      log('   - 未检测到已安装的 MCP 客户端（Codex / Claude Code / Claude Desktop / Cursor / DSH）');
    }
    for (const r of mcpResults) {
      const label = r.status === 'written' ? '✓ 已写入' : r.status === 'exists' ? '✓ 已存在（跳过）'
        : r.status === 'skip' ? '- 跳过' : r.status === 'error' ? '✗ 失败' : r.status;
      log(`   ${label}：${r.label}${r.reason ? '（' + r.reason + '）' : ''}`);
    }
  }
  log('');
  log('⑦ 给 MCP 客户端的配置（上面没检测到的客户端，复制即用）：');
  log('npm 安装用户（推荐）：');
  log(JSON.stringify({ mcpServers: { agentdesk: { command: 'agentdesk-mcp' } } }));
  log('源码（git clone）用户：');
  log(JSON.stringify({ mcpServers: { agentdesk: { command: 'node', args: [entry] } } }));

  // 8. 屏幕操作（CUA）助手：可选增强，编译失败不算安装失败（B 层 osascript 兜底）
  log('');
  log('⑧ 屏幕操作助手（cua_* 工具，可选增强）：');
  const cua = compileHelper({ log: (m) => log(`   ${m}`) });
  if (cua.compiled) {
    log('   ✓ 已编译 host/cua-helper（A 层：窗口清单 / AX 元素操作 / 定向坐标点击）');
    // v1.0.0：装 AgentDesk.app——TCC 权限挂在这个 .app 上（终端是谁不再重要）。
    const app = ensureCuaHelperApp({ srcBinary: cua.path, log: (m) => log(`   ${m}`) });
    if (app.installed) {
      log(`   ✓ 已安装 ${app.appPath}（权限主体；图标=${app.iconInstalled ? '已装' : '缺'}）`);
    } else {
      log(`   - AgentDesk.app 安装失败（${app.reason}）——权限将挂到运行服务的终端上（老行为）。`);
    }
    // v1.0.0 非交互引导：不弹系统申请对话框，直接开设置面板 + 浮琥珀引导卡片。
    //   卡片贴在系统设置窗口下方、跟随移动；左侧大图标拖出的就是 AgentDesk.app 本体，
    //   拖进列表即完成授权。helper 侧 1.2s 轮询权限，一生效自动收卡（本脚本已退出也
    //   不影响——卡片是 helper 进程的窗口，stdin EOF 后留守到卡片全数收起才退）。
    const cuaCtx = createCua({});
    let cardsShown = [];
    try {
      const st = await cuaCtx.status();
      const miss = missingPermissions(st);
      if (!miss.ax && !miss.screen) {
        log('   ✓ 辅助功能与屏幕录制权限均已授予（AgentDesk），CUA 全功能就绪');
      } else {
        const bundled = Boolean(st.helperApp?.path);
        const name = bundled ? st.helperApp.name : (st.responsibleProcess || '你的终端');
        if (!bundled) {
          // 兼容路径（.app 没装上）：向系统标准申请（弹对话框），再浮卡片
          try { await cuaCtx.requestPermissions(); } catch { /* 弹窗失败不算事：卡片+文字指引兜底 */ }
        }
        cardsShown = await showGuideCards(cuaCtx, miss, name, { log: (m) => log(`   ${m}`) });
        if (cardsShown.length) {
          try { await cuaCtx.openPrivacyPane(miss.ax ? 'accessibility' : 'screen'); } catch { /* 打不开面板不算事：指引里有路径 */ }
        }
        log('');
        log('   ⚠ 屏幕操作（CUA）需要两个 macOS 权限（挂在 AgentDesk 上，与终端无关）：');
        if (cardsShown.length) {
          log('   系统设置已打开，屏幕上已浮出引导卡片——把卡片左侧的「AgentDesk」图标拖进列表即可；');
          log('   授权生效后卡片会自动消失（无需回来报到）。也可以点列表下方的 + 号选「AgentDesk」。');
        } else {
          if (miss.ax) log(`     ① 辅助功能 → 加入「${name}」`);
          if (miss.screen) log(`     ${miss.ax ? '②' : '①'} 屏幕录制 → 加入「${name}」`);
        }
        log('     完成后可运行 npm run cua-selftest 验证（不授权也能用 B 层 osascript 与窗口清单）');
      }
    } finally {
      // 留过卡片就不杀 helper（卡片与 helper 共存亡；授权后自动收卡、helper 随之自退）；否则照常收尾
      if (!cardsShown.length) cuaCtx.stop();
    }
  } else if (cua.skipped) {
    log('   - 跳过：非 macOS 平台，cua_* 工具族不可用（其余功能不受影响）。');
  } else {
    log(`   - 未编译（${cua.reason}）。cua_* 仍可用 B 层（osascript：元素读/点击/输入），只是没有坐标点击。`);
    log('     装好 Xcode 或跑 xcode-select --install 后重跑 setup 即可编译。');
  }

  log('');
  log(ok ? '安装完成 🎉 日常使用：MCP 客户端按上面的配置自动拉起服务即可。' : '安装文件已就位，完成第④步后即用。');
  log('卸载：agentdesk-uninstall（npm 安装）或 npm run uninstall（源码）');
  return ok ? 0 : 1;
}

main().then((c) => process.exit(c)).catch((e) => { console.error(`[setup] 失败: ${e.message}`); process.exit(1); });
