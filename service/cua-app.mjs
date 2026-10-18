// service/cua-app.mjs — CUA Helper.app：屏幕操作助手的独立 .app 安装（v1.0.0）
//
// 为什么要有这个 .app（照成熟桌面操控产品的通行做法）：
//   macOS 的 TCC 权限（辅助功能/屏幕录制）按「持权 App」记账。CLI 二进制直接跑时，
//   负责进程是它的宿主（终端）——换终端/换宿主就要重新授权，权限永远漂在别人身上。
//   把 helper 包成带 Info.plist 的 .app（com.agentdesk.cua-helper，LSUIElement 后台 App），
//   权限就固定挂在这个 .app 上：终端是谁不再重要，授权一次永久生效，helper 可独立重启
//   重读 TCC grant 而无需重启整个服务。
//
// 安装形态（setup / cua-selftest 自动创建，勿手改）：
//   ~/.agentdesk/CUA Helper.app/
//   └── Contents/
//       ├── Info.plist        CFBundleIdentifier=com.agentdesk.cua-helper；LSUIElement=true（无 Dock 图标）
//       │                     NSAppleEventsUsageDescription="AgentDesk screen control"
//       ├── MacOS/cua-helper  ← 从仓库 host/cua-helper 拷贝（swift/cua-helper.swift 编译产物）
//       └── Resources/AppIcon.icns ← 仓库 assets/AppIcon.icns（琥珀色品牌图标）
//
// 本模块为纯逻辑 + 可注入 home/iconSrc 的安装函数（测试用临时目录覆盖，见 test/cua.test.mjs）。

import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export const CUA_APP_BUNDLE_ID = 'com.agentdesk.cua-helper';
export const CUA_APP_NAME = 'CUA Helper';
export const AGENTDESK_HOME_DIRNAME = '.agentdesk';
export const CUA_HELPER_VERSION = '1.0.0';

/** 仓库内品牌图标（随包分发；缺它也能装，只是 Finder 里没图标）。 */
export const CUA_APP_ICON_SRC = path.join(ROOT, 'assets', 'AppIcon.icns');

/** ~/.agentdesk（可注入 home 供测试）。 */
export function agentdeskHome(home = os.homedir()) { return path.join(home, AGENTDESK_HOME_DIRNAME); }

/** ~/.agentdesk/CUA Helper.app */
export function cuaHelperAppBundlePath(home = os.homedir()) { return path.join(agentdeskHome(home), `${CUA_APP_NAME}.app`); }

/** ~/.agentdesk/CUA Helper.app/Contents/MacOS/cua-helper —— cua.mjs 默认优先启动的二进制。 */
export function cuaHelperAppBinaryPath(home = os.homedir()) {
  return path.join(cuaHelperAppBundlePath(home), 'Contents', 'MacOS', 'cua-helper');
}

/** Info.plist 内容（XML；固定字段，版本随包）。 */
export function buildCuaHelperInfoPlist({ version = CUA_HELPER_VERSION } = {}) {
  const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>${esc(CUA_APP_NAME)}</string>
	<key>CFBundleExecutable</key>
	<string>cua-helper</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${esc(CUA_APP_BUNDLE_ID)}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${esc(CUA_APP_NAME)}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${esc(version)}</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>AgentDesk screen control</string>
</dict>
</plist>
`;
}

/**
 * 安装是否已最新：Contents/agentdesk-stamp.json 记录上次安装的二进制指纹（size+mtime 微秒）
 * 与 Info.plist 全文；三者一致且二进制在位 → 跳过重拷（TCC 对二进制按身份记账，没变就别动）。
 * （copyFileSync 每次都会刷新目标 mtime，不能拿源/目标 mtime 直接比。）
 */
function isUpToDate(stampPath, wantStamp, binaryPath) {
  try {
    return safeRead(stampPath) === wantStamp && existsSync(binaryPath);
  } catch { return false; }
}

/**
 * 创建/刷新 CUA Helper.app（幂等：内容未变不重写，避免 TCC 对二进制的无谓失效）。
 * @param {{srcBinary?: string, home?: string, iconSrc?: string, version?: string,
 *          codesign?: boolean, log?: Function}} [opts]
 *   srcBinary —— helper 二进制（默认仓库 host/cua-helper）
 *   codesign  —— 是否尝试 adhoc 签名 .app（默认自动：macOS 且本机有 codesign；测试可关）
 * @returns {{installed: boolean, appPath: string, binaryPath: string, reason?: string,
 *            iconInstalled: boolean, copiedBinary: boolean, signed: boolean|string}}
 */
export function ensureCuaHelperApp({ srcBinary, home = os.homedir(), iconSrc = CUA_APP_ICON_SRC, version, codesign, log = () => {} } = {}) {
  const appPath = cuaHelperAppBundlePath(home);
  const binaryPath = cuaHelperAppBinaryPath(home);
  const src = srcBinary ?? path.join(ROOT, 'host', 'cua-helper');
  if (process.platform !== 'darwin') {
    return { installed: false, appPath, binaryPath, reason: 'CUA Helper.app 仅支持 macOS', iconInstalled: false, copiedBinary: false, signed: 'skipped' };
  }
  if (!existsSync(src)) {
    return { installed: false, appPath, binaryPath, reason: `helper 二进制不存在: ${src}（先编译 swift/cua-helper.swift）`, iconInstalled: false, copiedBinary: false, signed: 'skipped' };
  }

  mkdirSync(path.dirname(binaryPath), { recursive: true });
  mkdirSync(path.join(appPath, 'Contents', 'Resources'), { recursive: true });

  const plistPath = path.join(appPath, 'Contents', 'Info.plist');
  const plist = buildCuaHelperInfoPlist(version ? { version } : {});
  const srcStat = statSync(src);
  // 构建戳放 Resources/ 内（Contents/ 根下的未知文件会让 codesign 拒签）
  const stampPath = path.join(appPath, 'Contents', 'Resources', 'agentdesk-stamp.json');
  const wantStamp = JSON.stringify({ binSize: srcStat.size, binMtimeUs: Math.round(srcStat.mtimeMs * 1000), plist });
  const copiedBinary = !isUpToDate(stampPath, wantStamp, binaryPath);
  if (copiedBinary) {
    copyFileSync(src, binaryPath);
    chmodSync(binaryPath, 0o755);
    writeFileSync(plistPath, plist);
    writeFileSync(stampPath, wantStamp);
  }

  let iconInstalled = false;
  let iconCopied = false;
  if (iconSrc && existsSync(iconSrc)) {
    const dstIcon = path.join(appPath, 'Contents', 'Resources', 'AppIcon.icns');
    try {
      if (!existsSync(dstIcon) || statSync(dstIcon).size !== statSync(iconSrc).size) { copyFileSync(iconSrc, dstIcon); iconCopied = true; }
    } catch { copyFileSync(iconSrc, dstIcon); iconCopied = true; }
    iconInstalled = true;
  }

  // adhoc 签名（尽力而为）：本机 codesign 可用就签，让 .app 有稳定签名身份；
  // 失败不致命（TCC 退化为按路径记账，功能不受影响）。注意：签名密封了 Resources/
  // 整树（含构建戳与图标）——内容有变（dirty）或校验不过时重签。
  let signed = 'skipped';
  const dirty = copiedBinary || iconCopied;
  const wantSign = codesign === undefined ? true : codesign;
  if (wantSign) {
    try {
      const probe = dirty ? { status: 1 } : spawnSync('codesign', ['-v', appPath], { encoding: 'utf8', timeout: 15_000 });
      if (probe.status !== 0) {
        const r = spawnSync('codesign', ['--force', '--sign', '-', appPath], { encoding: 'utf8', timeout: 30_000 });
        signed = r.status === 0;
        if (r.status !== 0) log(`codesign adhoc 签名跳过（不影响使用）: ${(r.stderr || '').slice(0, 160)}`);
      } else {
        signed = true; // 已有有效签名（内容未变）
      }
    } catch { signed = 'skipped'; }
  }

  return { installed: true, appPath, binaryPath, iconInstalled, copiedBinary, signed };
}

function safeRead(p) { try { return existsSync(p) ? readFileSync(p, 'utf8') : null; } catch { return null; } }
