// AgentDesk 扩展弹窗：受控权开关（多浏览器互斥）。
//   同一时刻只有一个浏览器"受控"，其余自动是"待机"（开关显示为关）。
//   勾选 = 把受控权抢到本浏览器（服务端按时间戳选一个，并通知其他浏览器）。
const $ = (id) => document.getElementById(id);

async function getState() {
  try {
    const st = await chrome.runtime.sendMessage({ type: 'ab_popup_status' });
    return st && typeof st === 'object' ? st : { enabled: true, connected: false, state: 'unknown' };
  } catch { return { enabled: true, connected: false, state: 'unknown' }; }
}

function render(st) {
  // 待机 = 服务端明确告诉"另一个浏览器受控"
  const standby = st.enabled !== false && st.connected && st.active === false && !!st.activeLabel;
  // 受控 = 服务端点名是我；或服务端还没广播（旧服务/刚连上）时先按"只有我在"乐观处理，
  // 避免出现"等待受控权分配…"这种让人懵的状态。
  const active = st.enabled !== false && (st.active === true || (st.connected && !standby));
  $('enabled').checked = active || (st.enabled !== false && !st.connected);
  let text;
  if (st.enabled === false) text = '已关闭：本浏览器不会被 AI 控制';
  else if (active) text = '受控中：AI 可以使用本浏览器';
  else if (standby) text = `待机：${st.activeLabel} 正在受控（勾选可切换过来）`;
  else text = '已启用：等待本地服务（AI 客户端启动时自动连上）';
  $('status').textContent = text;
}

async function refresh() { render(await getState()); }

$('enabled').addEventListener('change', async (e) => {
  try { await chrome.runtime.sendMessage({ type: 'ab_set_enabled', enabled: e.target.checked }); } catch { /* noop */ }
  // 给服务端选举/广播一点时间再刷新
  setTimeout(refresh, 250);
});

refresh();
setInterval(refresh, 1000); // 弹窗打开期间轮询，待机→受控切换能实时看到
