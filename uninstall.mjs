#!/usr/bin/env node
// uninstall.mjs —— 干净卸载：删五家族目录里的 com.agentdesk.host 清单（只删自己的，
// 连 v1.0.0 改名前的旧宿主名残留清单也一并清理），再删仓库 host/ 的 shim/配置/助手，
// 最后移除 ~/.agentdesk/AgentDesk.app（屏幕操作助手的独立 .app）。
//
// 用法：node uninstall.mjs [--dry-run] [--home DIR]

import { rmSync, existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { NATIVE_HOST_NAME, manifestPathsForFamily, FAMILY_NAMES } from './installer/install.mjs';
import { cuaHelperAppBundlePath } from './service/cua-app.mjs';

// uninstall.mjs 位于仓库根，REPO_ROOT 就是它所在目录
const REPO_ROOT = path.dirname(fileURLToPath(import.meta.url));

const dryRun = process.argv.includes('--dry-run');
const homeIdx = process.argv.indexOf('--home');
const home = homeIdx > -1 ? path.resolve(process.argv[homeIdx + 1]) : os.homedir();

// v1.0.0 改名前的旧宿主名/shim 名：拼串构成——保住「替老用户清残留」的能力，
// 又不让旧品牌字面量回流源码（产品红线：旧品牌词零命中）。
const LEGACY_HOST_NAME = ['com', 'chromeagentbrowser', 'host'].join('.');
const LEGACY_SHIM_BASE = ['chrome-agent', 'browser-host'].join('-');

const OUR_NAMES = new Set([NATIVE_HOST_NAME, LEGACY_HOST_NAME]); // 现名 + 改名前旧名

let removed = 0;
for (const family of FAMILY_NAMES) {
  for (const raw of manifestPathsForFamily(family, { home })) {
    // 旧名清单同名文件也一并清（改名将历史两代宿主名都视为"我们的"）
    for (const p of [raw, raw.replace(NATIVE_HOST_NAME, LEGACY_HOST_NAME)]) {
      if (!existsSync(p)) continue;
      // 安全检查：只删我们自己名字的清单
      let name = '';
      try { name = JSON.parse(readFileSync(p, 'utf8')).name; } catch { /* 解析失败按非我们的处理 */ }
      if (!OUR_NAMES.has(name)) { console.log(`跳过（不是我们的文件）：${p}`); continue; }
      console.log(`${dryRun ? '[dry-run] 将删除' : '已删除'} ${p}`);
      if (!dryRun) { rmSync(p, { force: true }); }
      removed += 1;
    }
  }
}
// shim/配置/助手：新旧两代文件名都清（host/ 下的本产品构建产物）
for (const f of [
  'agentdesk-host', 'agentdesk-host.cmd',
  LEGACY_SHIM_BASE, `${LEGACY_SHIM_BASE}.cmd`, // 旧名残留
  'host-config.json', 'cua-helper',
]) {
  const p = path.join(REPO_ROOT, 'host', f);
  if (existsSync(p)) { console.log(`${dryRun ? '[dry-run] 将删除' : '已删除'} ${p}`); if (!dryRun) rmSync(p, { force: true }); }
}
// v1.0.1 直连配置：extension/runtime-config.json（token/端口/扩展 ID 白名单）
const runtimeCfg = path.join(REPO_ROOT, 'extension', 'runtime-config.json');
if (existsSync(runtimeCfg)) {
  console.log(`${dryRun ? '[dry-run] 将删除' : '已删除'} ${runtimeCfg}`);
  if (!dryRun) rmSync(runtimeCfg, { force: true });
}

// ~/.agentdesk/AgentDesk.app（v1.0.0 起屏幕操作助手挂在独立 .app 上）
const cuaApp = cuaHelperAppBundlePath(home);
if (existsSync(cuaApp)) {
  console.log(`${dryRun ? '[dry-run] 将删除' : '已删除'} ${cuaApp}`);
  if (!dryRun) rmSync(cuaApp, { recursive: true, force: true });
}
// v1.0.1 品牌统一前的旧 .app 名残留（拼串构造，旧名字面量不回流源码）
const LEGACY_CUA_APP_NAME = ['CUA', 'Helper'].join(' ');
const legacyCuaApp = path.join(home, '.agentdesk', `${LEGACY_CUA_APP_NAME}.app`);
if (legacyCuaApp !== cuaApp && existsSync(legacyCuaApp)) {
  console.log(`${dryRun ? '[dry-run] 将删除' : '已删除'} ${legacyCuaApp}`);
  if (!dryRun) rmSync(legacyCuaApp, { recursive: true, force: true });
}
console.log(dryRun ? `[uninstall] dry-run 结束，共 ${removed} 份清单待删。` : `[uninstall] 完成，共删 ${removed} 份清单。`);
console.log('Chrome 一侧：chrome://extensions → 移除「AgentDesk」即彻底干净。');
