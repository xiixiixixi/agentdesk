// service/cua-guide.mjs — CUA 授权引导（v0.5.3 起；v0.5.4 悬浮卡片；v1.0.0 拖 .app + 自动检测）
//
// v1.0.0 权限模型：helper 装进 ~/.agentdesk/AgentDesk.app（com.agentdesk.cua-helper），
// TCC 权限挂在这个 .app 上——终端是谁不再重要。引导主路径从「系统弹窗+去设置拨开关」
// 升级为「拖拽授权」：自动打开系统设置对应面板，屏幕上浮一张 560×124 的琥珀引导卡片
// （贴在设置窗下沿、跟随移动），卡片左侧大图标按住拖出的就是 AgentDesk.app 本体，
// 放进列表即完成授权；同时轮询 AXIsProcessTrusted（不带 prompt）自动检测——权限一生效
// 自动收卡、重启 helper 重读 TCC grant，无需用户回来按回车报到。
//
// 兼容降级：.app 不存在（裸 CLI 运行）时退回 v0.5.3/0.5.4 行为——系统标准申请
// （弹对话框+把负责进程注册进设置列表）+ 拖负责进程 .app 的卡片，文字引导始终完整。
//
// 本模块 = 纯逻辑（missingPermissions / missingCardKinds / permissionGuideText / cTierNote / degradedNote）
//        + 可注入 IO 的引导编排（runGuidedGrant）与卡片开关（showGuideCards / hideGuideCards）。被三处共用：
//   service/cua.mjs  —— status() 的 permissionGuide 拼装（纯逻辑）
//   cua-selftest.mjs —— 互动引导（拖卡/自动检测推进；Ctrl+C 跳过并如实降级）
//   setup.mjs        —— 非交互指引（留卡片在屏上自动淡出/授权即自动消失，不等待）
// 测试直接注入 fake cua / fake io 覆盖各分支（见 test/cua.test.mjs）。

/** 引导卡片默认寿命：setup 非交互模式留卡给用户看的窗口期。 */
export const CARD_DEFAULT_SEC = 120;

/** 自动检测轮询的总窗口（拖完卡片的等待上限；到点降级为回车确认）。 */
export const GRANT_WAIT_MS = 120_000;

/** 缺权限判定：未授权或未知都算缺（引导一步到位总没错）。@returns {{ax: boolean, screen: boolean}} */
export function missingPermissions(st) {
  return { ax: st?.axGranted !== true, screen: st?.screenGranted !== true };
}

/** 缺权限 → 引导卡片 kinds（accessibility 在前、screen 在后，与 helper 的卡片排布一致）。 */
export function missingCardKinds(missing) {
  const kinds = [];
  if (missing?.ax) kinds.push('accessibility');
  if (missing?.screen) kinds.push('screen');
  return kinds;
}

/** 人话授权指引：含设置面板路径与要勾选/要拖的名字（只列缺的项）。 */
export function permissionGuideText({ responsibleProcess, ax, screen, appName } = {}) {
  const owner = appName || responsibleProcess;
  const name = owner || 'AgentDesk（跑一次 npm run setup 会自动装到 ~/.agentdesk/）';
  const steps = [];
  if (ax) steps.push(`①「辅助功能」加入/勾选「${name}」（AI 才能读界面元素并点击/输入）`);
  if (screen) steps.push(`${ax ? '②' : '①'}「屏幕录制」加入/勾选「${name}」（AI 才能截图/读到窗口标题）`);
  return `系统设置 → 隐私与安全性 → ${steps.join('；')}。跑 npm run cua-selftest 可自动打开面板并给出拖拽引导卡片。`;
}

/**
 * 显示引导卡片（每缺一项一张；失败自吞——helper 太旧/缺失时静默降级为纯文字引导）。
 * @returns {Promise<string[]>} 实际显示成功的 kinds（空数组=本机无卡片能力）
 */
export async function showGuideCards(cua, missing, appName, { durationSec = CARD_DEFAULT_SEC, log = () => {} } = {}) {
  const shown = [];
  for (const kind of missingCardKinds(missing)) {
    // 方法不存在（v0.5.3 旧二进制/无 helper 的纯 fake）= 无卡片能力：静默降级为纯文字引导
    if (typeof cua?.showPermissionCard !== 'function') continue;
    try {
      await cua.showPermissionCard({ kind, appName, durationSec });
      shown.push(kind);
    } catch { /* 旧版 helper 回 unknown-cmd 等：失败的卡不进列表（调用方据此只收已浮的卡） */ }
  }
  if (shown.length) log(`屏幕上已出现琥珀色引导卡片（已自动贴在系统设置窗口下方），把卡片左侧的「${appName || 'AgentDesk'}」图标拖进上方列表即可授权`);
  return shown;
}

/** 收起引导卡片（幂等；失败自吞）。 */
export async function hideGuideCards(cua, kinds) {
  for (const kind of Array.isArray(kinds) ? kinds : []) {
    try { await cua.hidePermissionCard?.(kind); } catch { /* 收卡失败最多多浮一会儿，无害 */ }
  }
}

/** 跳过授权 / AX 未授权时的诚实降级说明。 */
export function cTierNote() {
  return '权限未授予，CUA 限制在 C 层（仅窗口清单；截图可能只剩桌面壁纸）';
}

/** 按缺什么给诚实的降级说明（AX 缺 → C 层；只缺屏幕录制 → 截图降级但元素操作可用）。 */
export function degradedNote(st) {
  const miss = missingPermissions(st);
  if (miss.ax) return cTierNote();
  return '屏幕录制未授权：截图可能只剩桌面壁纸、窗口标题为空（界面元素操作不受影响）';
}

/** 旧版 helper 没有 request-permissions（unknown-cmd）→ 可重编译时就地重编译重试一次。 */
async function requestWithRecompile(cua, recompile, log) {
  try {
    return await cua.requestPermissions();
  } catch (err) {
    if (err.code !== 'unknown-cmd' || !recompile) throw err;
    const built = recompile();
    if (!built?.compiled) throw err; // 重编译失败按原错误报告
    cua.stop(); // 结束常驻的旧二进制，下次请求自动从新编译产物拉起
    log('检测到旧版 host/cua-helper（无 request-permissions 命令），已就地重编译 → 重试');
    return cua.requestPermissions();
  }
}

/**
 * 权限生效即自动收尾：收卡 → 结束当前 helper（下次请求自动从 .app 位置重启新实例，
 * 重读 TCC grant）→ 复测 status。拖完卡片 / 手动开完开关后的统一出口。
 */
async function settleAfterGrant(cua, cards, log) {
  await hideGuideCards(cua, cards);
  cua.stop?.(); // v1.0.0：重启 helper 重读授权（裸 CLI 模式同样受益：重读终端的 TCC 状态）
  const stAfter = await cua.status();
  log(`✓ 权限已生效：tier ${stAfter.tier}，辅助功能 ${stAfter.axGranted === true ? '✓' : '✗/未知'}，屏幕录制 ${stAfter.screenGranted === true ? '✓' : '✗/未知'}`);
  return stAfter;
}

/**
 * 互动授权引导（cua-selftest 用）。v1.0.0 两条路径：
 *   A. helper 从 .app 内运行（st.helperApp 非空，主路径）：不弹系统申请对话框——
 *      直接开面板 + 浮卡片，用户拖 AgentDesk.app 进列表；轮询自动检测（waitForGrant），
 *      生效即收卡+重启 helper+复测；回车=立即验证，Ctrl+C=跳过。
 *   B. 裸 CLI（无 .app，兼容路径）：v0.5.3 行为——回车后向系统标准申请（弹对话框），
 *      再浮卡片（拖负责进程 .app）+ 开面板，之后同样自动检测收尾。
 * @param {object} opts
 *   cua        —— createCua() 的返回值（须已编译 helper，调用方保证）
 *   st         —— 当前 status() 结果
 *   io         —— {ask(prompt): 'enter'|'skip'}；null = 非交互（stdin 非 TTY）
 *   log        —— 输出函数（默认空）
 *   recompile  —— 可选 () => {compiled:boolean}（旧 helper 就地重编译用）
 * @returns {{mode: 'already-granted'|'no-tty'|'skipped'|'error'|'requested', st: object,
 *            missing?: {ax,screen}, requested?: object, cards?: string[], error?: Error}}
 *   requested 模式的 st 为复测后的新 status（调用方以其继续后续链路）；
 *   cards 为本轮实际浮起的引导卡片 kinds（引导结束时已全部收起）。
 */
export async function runGuidedGrant({ cua, st, io, log = () => {}, recompile = null } = {}) {
  const missing = missingPermissions(st);
  if (!missing.ax && !missing.screen) return { mode: 'already-granted', st, missing };
  if (!io) return { mode: 'no-tty', st, missing };
  const bundled = Boolean(st.helperApp?.path); // helper 从 .app 内运行：拖拽授权主路径
  const ownerName = st.helperApp?.name ?? (st.responsibleProcess || '运行本命令的终端（列表里显示它的名字，如 Ghostty）');
  log('');
  log('⚠ 屏幕操作需要两个 macOS 权限，现在帮你开好引导：');
  if (bundled) {
    log(`   权限主体是「${ownerName}」（~/.agentdesk/AgentDesk.app）——终端是谁无关，授权一次永久生效。`);
  }
  if (missing.ax) {
    log('');
    log('第 1 步：辅助功能（让 AI 能看到和点击界面元素）');
    if (bundled) log('→ 马上会打开系统设置并浮出引导卡片：把卡片左侧的「AgentDesk」图标拖进列表即可');
    else {
      log('→ 马上会弹一个系统对话框，点「打开系统设置」');
      log(`→ 在列表里找到「${ownerName}」（或你看到的运行本命令的应用名），打开开关`);
    }
  }
  if (missing.screen) {
    log('');
    log(`${missing.ax ? '第 2 步' : '第 1 步'}：屏幕录制（让 AI 能截屏）`);
    log(bundled ? '→ 同一张卡片再拖一次「屏幕录制」列表（或点 + 号选「AgentDesk」）' : '→ 同上：在系统对话框/系统设置里给同一项打开开关');
  }
  log('');
  if ((await io.ask('[按回车打开系统设置并开始引导…（Ctrl+C 跳过）] ')) === 'skip') return { mode: 'skipped', st, missing };

  let requested = null; // 系统标准申请的应答（仅裸 CLI 路径有）
  if (!bundled) {
    try {
      requested = await requestWithRecompile(cua, recompile, log);
    } catch (err) {
      return { mode: 'error', st, missing, error: err };
    }
  }

  // 浮卡片（图标句柄=可拖进设置列表的 .app）+ 直接开到对应设置面板（纯增益，失败降级文字）
  const nameAfter = bundled ? ownerName : (requested?.responsibleProcess || ownerName);
  const stillMissing = bundled ? missing : { ax: requested.axGranted !== true, screen: requested.screenGranted !== true };
  const cards = await showGuideCards(cua, stillMissing, nameAfter, { log });
  if (stillMissing.ax || stillMissing.screen) {
    try { await cua.openPrivacyPane?.(stillMissing.ax ? 'accessibility' : 'screen'); } catch { /* 打不开面板不算事：文字指引里有路径 */ }
  }
  log('');
  log(cards.length
    ? `→ 系统设置已打开${bundled ? '，拖完卡片这里会自动检测到（不用回车报到）' : '；开好「${nameAfter}」的开关后这里会自动检测到'}` + '：'
    : `→ 请到系统设置里把「${nameAfter}」加进/勾选：`);
  if (stillMissing.ax) log('  ① 辅助功能');
  if (stillMissing.screen) log('  ② 屏幕录制');

  // 自动检测（v1.0.0）：轮询 waitForGrant；回车=立即验证；Ctrl+C=跳过。
  // 旧 fake cua 无 waitForGrant（测试注入的简化桩）→ 退化为回车确认。
  if (typeof cua.waitForGrant === 'function') {
    const waitPromise = cua.waitForGrant({
      ax: stillMissing.ax,
      screen: stillMissing.screen,
      timeoutMs: GRANT_WAIT_MS,
      onPoll: ({ waitedMs }) => log(`   …自动检测中（${Math.round(waitedMs / 1000)}s，拖完/开完开关即自动继续）`),
    });
    const answer = await Promise.race([waitPromise, io.ask('[自动检测中… 按回车立即验证 / Ctrl+C 跳过] ')]);
    if (answer === 'skip') {
      await hideGuideCards(cua, cards); // 引导中止也要收卡（不然要等自动淡出）
      return { mode: 'skipped', st, missing, ...(requested ? { requested } : {}), cards };
    }
    const wait = answer === 'enter' // 用户等不及：立即做一次新鲜探测（~1s 内返回）
      ? await cua.waitForGrant({ ax: stillMissing.ax, screen: stillMissing.screen, timeoutMs: 1_000 })
      : answer;
    if (wait.granted) {
      const stAfter = await settleAfterGrant(cua, cards, log);
      return { mode: 'requested', st: stAfter, missing: missingPermissions(stAfter), ...(requested ? { requested } : {}), cards };
    }
    // 超时仍缺：降级为回车确认（用户可能走开了）
    log('   自动检测窗口已到时，权限尚未全部生效——完成后按回车再验证一次。');
  }
  if ((await io.ask('[开好后按回车继续验证…（Ctrl+C 跳过）] ')) === 'skip') {
    await hideGuideCards(cua, cards);
    return { mode: 'skipped', st, missing, ...(requested ? { requested } : {}), cards };
  }
  const stAfter = await settleAfterGrant(cua, cards, log);
  return { mode: 'requested', st: stAfter, missing: missingPermissions(stAfter), ...(requested ? { requested } : {}), cards };
}
