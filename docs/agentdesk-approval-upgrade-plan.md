# agentdesk 安全确认改造蓝图（对标 Codex 的人类回路）

> 目标：把 agentdesk 的“确认令牌”从**模型可自批**改成**必须由人操作**，并对齐 Codex 已验证的机制（请求-响应协议、风险分类、持久授权、审计）。
> 前置证据：`docs/codex-human-approval.md`、`.codex-analysis/06-browser-gates.md`、`.codex-analysis/04-chrome-extension.md`、`.codex-analysis/03-agentdesk-inventory.md`。
> 验收口径（非技术）：**AI 要做危险动作时必须弹出一个窗口等你点；你不点，它做不了；它没有任何工具能自己批。** 所有批准/拒绝都留本地审计。

---

## 1. 现状问题（代码可证）

| # | 问题 | 证据 |
|---|---|---|
| 1 | `ab_confirm` 是普通 MCP 工具，模型自己调用即可拿到 token → 人类回路不存在 | `.codex-analysis/03` §4.2；`service/mcp.mjs` 注册、`service/policy.mjs` token 校验 |
| 2 | token 只绑 `kind`，不绑具体动作/参数；重放窗口 5 分钟 | `service/policy.mjs` |
| 3 | 策略门只覆盖 6 类动作；`tab_eval`/`tab_click`/`cua_click` 等副作用动作不过门 | `.codex-analysis/03` §4.3 |
| 4 | `browser_eval` 可经 `tab._cmd` / `tab.eval` 绕过策略门 | `.codex-analysis/03` §4.8 |
| 5 | 本机 WS 无鉴权，任意本机进程可冒充 frontend 读 Cookie | `.codex-analysis/03` §1.7/§4 |
| 6 | `session_finalize` 无生产调用方，turn/会话结束不清理租约 | `.codex-analysis/03` §6.3 |

---

## 2. 目标架构（对标 Codex 的“服务器问客户端”）

```
模型调用工具（click / navigate / delete / send …）
        │
service/mcp.mjs ──► service/approval.mjs（审批代理，单咽喉点）
        │                 │ 1. 计算 risk + actionHash + persistModes
        │                 │ 2. 发起“人类确认请求”（阻塞）
        │                 ▼
        │        审批 UI（三选一，按环境自动降级）
        │         A. 本机一次性网页：http://127.0.0.1:<port>/approve/<rand>
        │            （service 自动 `open`，页面含动作详情 + 允许一次/本会话/总是/拒绝）
        │         B. MCP elicitation（客户端声明支持时）
        │         C. osascript 系统对话框（无浏览器/无客户端 UI 的兜底）
        │                 │ 3. 用户点击 → {decision, persist?, reason?}
        │                 ▼
        └──── 4. 校验（actionHash/TTL/单次）→ 放行或返回“用户拒绝”
                            │
                            └──► audit.jsonl：approval_decided（decided_by=user, risk, persist）
```

与 Codex 的映射：

| Codex | agentdesk 对应实现 |
|---|---|
| `item/commandExecution/requestApproval` 等 5 类请求 | 一个统一 `approval.request`（内部）；MCP 面对模型保持“工具调用阻塞直到人点” |
| `CommandExecutionApprovalDecision` 五值 | `accept` / `acceptForSession` / `acceptWithPersist(scope)` / `decline(reason)` / `cancel`（超时=fail-closed `timed_out`） |
| `mcpServer/elicitation/request`（form/url） | 方案 B 直接复用 MCP elicitation（SDK 需升级）；方案 A 用本地网页表单 |
| `persist` / TOML 持久授权 | `~/.agentdesk/approvals.json`：`origins{allowed}`、`apps{allowed}`、`sessions{...}` |
| `site_status` 云端裁决 | **不抄**（不联网）；用本地 URL 规则 + 风险分类替代 |
| guardian 自动审核 | 可选 P2：本地规则自动放行低风险项，但**默认关闭**，且审计标注 `decided_by=auto` |
| 远程审批（手机） | P2 可选：一次性链接可发给任意设备；P0 不做 |

---

## 3. 协议与数据结构（P0 具体设计）

### 3.1 内部审批对象

```js
// service/approval.mjs
const request = {
  approvalId: 'apr_<uuid>',
  risk: 'low' | 'medium' | 'high',          // 见 §3.2 分类
  action: {
    tool: 'ab_navigate' | 'cua_click' | 'browser_eval' | 'ab_login' | ...,
    summary: '访问 https://example.com/delete 并点击「删除」',  // 人话，给 UI
    target: { kind: 'origin'|'app'|'url'|'path'|'command', value: '...' },
    details: { ... },                        // 可展示的 JSON（按键、选择器、坐标…）
  },
  persistModes: ['once','session','always'], // 由 risk 决定可选项
  expiresAtMs: Date.now() + 120_000,         // 默认 2 分钟，超时 fail-closed
  sessionId, turnId,
};
// actionHash = sha256(JSON.stringify(action) + AGENTDESK_APPROVAL_SALT)
```

### 3.2 风险分类（照抄 Codex `confirmations.md` 的 4 档，落到 agentdesk 工具）

| 档位 | 例子（agentdesk 工具） | 默认策略 |
|---|---|---|
| **必须人接管** | 绕过 HTTPS 警告/付费墙、改密码最后一步 | 直接拒绝 + 指引（不弹确认） |
| **动作时必确认** | 删除数据、发消息/评论/表单提交、付款/订阅、装软件/扩展、传敏感数据、改权限/系统设置、`ab_login` 提交、`ab_download_open`、`cua_key` 危险组合、`browser_eval` 首次执行 | 每次弹窗（可选“本会话/总是”） |
| **可预授权** | 上传文件、登录（“去某站”隐含）、站内移动文件、接收浏览器权限弹窗、Cookie/ToS | 首次确认后可持久（origin/app 级） |
| **免确认** | 读页面、截图、滚动、导航到普通页面、Cookie 同意 | 直接执行（仍审计） |

### 3.2.1 高风险不提供“始终允许”

照抄 Codex 的风险档：`risk: low | high`（Codex 实际只有两档 + `warningSubtitle` + `allowPersistentApproval`）。规则：
- `high`（删数据、发送、付款、装软件、敏感数据传输、改权限、登录提交、`browser_eval`）：`persistModes = ["session"]`，**不给“总是允许”**；拒绝时返回错误码 `APPROVAL_PERSISTENCE_UNAVAILABLE`。
- `low`（导航到普通页面、上传、Cookie）：`persistModes = ["session","always"]`，可持久到 origin/app。
- 任何 `high` 动作即便已有持久授权，只要 `policy_snapshot_hash` 不一致（目标/参数变了）仍需重新确认 —— 防“批准一次后被偷换目标”。

### 3.2.2 per-app 授权（CUA，P1）

对标 Codex 的 `Allow ChatGPT to use {app}?`：

| 项 | 设计 |
|---|---|
| 触发 | 首次 `cua_click/type/key/app_focus` 命中某 App（用 bundleId） |
| 选项 | `Allow once` / `Allow this conversation`（session） / `Always allow`（always，仅在 `allowPersistentApproval` 时）/ `Deny` |
| 存储 | `~/.agentdesk/approvals/apps.json`：`{ "com.apple.Safari": { "mode": "always", "grantedAt": ..., "risk": "low" } }`；session/turn 存在内存 |
| 高风险 App 目录 | 默认内置保守名单（密码管理器/银行/终端/系统设置），这些 App **永远不允许“always”**，且可配置 |
| 撤销 | `agentdesk-doctor --revoke-app <bundleId>` 或审批中心页面 |
| 错误码 | `APP_NOT_APPROVED` / `APP_APPROVAL_PERSISTENCE_UNAVAILABLE` / `APP_APPROVAL_DENIED` |
| 验收 | 首次操作弹窗；拒绝后动作不执行；always 后同 app 不再弹；换 app 再弹；高风险 app 无 always 选项 |

### 3.3 持久化文件（等价 Codex TOML）

```json
// ~/.agentdesk/approvals.json  (0600)
{
  "version": 1,
  "origins": { "allowed": ["https://github.com"] },
  "apps":    { "allowed": ["com.apple.Safari"] },
  "sessions":{ "<sessionId>": { "untilMs": 1790000000000, "origins": [...] } },
  "turns":   { "<turnId>":    { "origins": [...] } }
}
```
- `once` 不落盘；`session` 写 `sessions[sessionId]`；`turn` 写 `turns[turnId]`；`always` 写 `origins/apps`。
- 文件权限 0600；删除/清空通过 `agentdesk-doctor --reset-approvals`。
- 读取时校验：路径在 `$HOME/.agentdesk`，禁止软链。

### 3.4 MCP 工具面变化（对模型）

- **删除** `ab_confirm`（保留名字但返回错误：`"确认必须由用户在弹窗中完成；工具不可代批"`）。
- 所有副作用工具：调用先过 `approval.request()`；用户拒绝 → 返回 `{error:"USER_DENIED", approvalId}`；超时 → `{error:"APPROVAL_TIMEOUT"}`（fail-closed）。
- `browser_eval`/`tab_eval`：P0 起**整体作为 high risk**（首调弹窗，说明“将执行任意页面脚本”），并把内部 `_cmd`/`eval` 也纳入策略（禁止在未批准的 eval 里再发 CDP 敏感命令）。
- 工具结果中不再返回任何可用于后续放行的 token（模型拿不到凭证）。

### 3.5 审批通道与字段（与 Codex elicitation 对齐）

**通道选择**（P0 默认 A，P1 增加 B，P2 增加签名）：

| 方案 | 做法 | 依赖 | 建议 |
|---|---|---|---|
| **A. 宿主 UI（本机网页，推荐 P0）** | service 起 loopback 审批页：`http://127.0.0.1:<port>/approve/<rand>`；自动 `open`；页面渲染结构化字段；POST 决策 | 无（浏览器自带） | ★ P0 |
| **B. MCP elicitation** | 若 MCP 客户端声明 elicitation 能力，则发 server→client `elicitation/create`，由宿主 GUI 渲染 | SDK 升级 + 客户端支持 | ★ P1 |
| **C. 系统对话框** | `osascript` 弹窗（含动作摘要） | macOS 自带 | 兜底（无浏览器环境） |

**请求载荷（A/B 共用，照抄 Codex 语义，命名空间 `agentdesk/approval`）**：

```jsonc
// server → client
{
  "method": "elicitation/create",           // 方案 B；方案 A 是 HTTP GET 渲染同一份 JSON
  "params": {
    "mode": "form",
    "message": "允许 agentdesk 执行：打开下载文件 (downloadId=42)？",
    "requestedSchema": { "type": "object", "properties": {} },   // 空 schema = 纯是/否
    "_meta": {
      "agentdesk/approval": {
        "request_id": "apr_01J...",
        "thread_id": "s_...", "turn_id": "t_...", "item_id": "i_...",
        "tool": "ab_download_open",
        "action_kind": "download_open",
        "risk": "high",
        "reason": "Open downloaded file in the system viewer",
        "params_preview": { "downloadId": 42 },
        "params_display": [ { "name": "downloadId", "value": 42 } ],
        "persist_modes": ["session"],
        "expires_at_ms": 1730000000000,
        "policy_snapshot_hash": "sha256:..."   // 防 TOCTOU
      }
    }
  },
  "id": 17
}
```

```jsonc
// 人类 UI 回包（服务端只接受来自审批通道的内部调用，模型面不可达）
{ "id": 17, "result": {
    "action": "accept",                       // accept | decline | cancel
    "content": { "persist": "session" },      // session | always | null
    "_meta": { "agentdesk/approver": { "source": "gui", "gesture": "click", "at_ms": 1730000000123 } }
} }
```

**服务端状态机**：

| 事件 | 处理 |
|---|---|
| `accept` | 校验 `request_id` 存在/未过期 → 校验 `policy_snapshot_hash` 与当前动作一致 → 铸一次性执行令牌（绑定 `tool+action_kind+params_hash`，TTL ≤ 5 min）→ 执行 → 审计 `decided_by:"user"` |
| `decline` | 不执行；返回 `{allowed:false, outcome:"declined"}`；agent 可继续 |
| `cancel` | 不执行并中止当前 turn/会话动作 |
| 超时 / 断连 | 丢弃请求，不铸令牌；审计 `expired`；动作失败 |
| 重复响应 | 以 `request_id` 幂等；第二次返回 `already_resolved` |
| 动作参数变化 | `policy_snapshot_hash` 不匹配 → 拒绝（重新请求） |

**命名对照**（直接对齐 Codex，避免二次翻译）：`action=accept|decline|cancel`；`content.persist=session|always|null`；`risk=low|medium|high|critical`；审计 `outcome=accepted|declined|cancelled|expired|applied`。

---

## 4. 改动清单（文件级）

| 文件 | 改动 | 说明 |
|---|---|---|
| `service/approval.mjs` **新增** | 审批代理：pending 表、actionHash、TTL、单次消费、持久化读写、三种 UI 适配 | P0 核心 |
| `service/approval-ui.mjs` **新增** | 本机 HTTP 审批页：`/approve/<rand>`（GET 渲染、POST 决策）、Host/Origin 校验、一次性路径、倒计时 | A 方案 |
| `service/policy.mjs` | 重写为“风险分类 + authority + 持久授权查询”；移除 token 自批 | 参考 `.codex-analysis/06` 的 authority/scope 设计 |
| `service/mcp.mjs` | 删除 `ab_confirm` 注册；在 `ab_*`/`cua_*`/`browser_eval` 入口调用 approval；结果/错误结构化 | 覆盖全部副作用工具 |
| `service/api.mjs` | `browser_eval` 的 `tab._cmd`/`tab.eval` 经过同一 policy；`tab_eval` 入审计/审批 | 堵绕过 |
| `service/audit.mjs` | 新增事件：`approval_requested` / `approval_decided`（`decided_by:"user"`、`risk`、`persist`、`reason`、`approval_id`）；`ab_audit` 可过滤 | 对齐 Codex `security_check` |
| `service/mcp-entry.mjs` | `session_finalize` 接线：stdin EOF / 客户端断开 → finalize（关 agent 页、清会话级批准、清角标） | 修 §1.6 |
| `shared/protocol.mjs` | 新命令：`approval_pending` 事件、`approval_resolve`（仅本地 UI/宿主调用，非模型面）；协议文档同步 | 单一事实来源 |
| `extension/background.js` | 无需改动（批准在 service 侧完成）；仅确认 `tab_mark` 语义 | — |
| `service/policy-defaults.json` | 新配置：`approval.riskRules`、`approval.persistModes`、`approval.timeoutMs`、`approval.requireFor` | 可配置 |
| `test/approval.test.mjs` **新增** | 见 §6 | CI |

---

## 5. 分阶段实施

### P0（建议第一个 PR，1–2 天）
0. **审批方向修正**：新增 `approvalChannel` 抽象（`host-ui` 默认 / `mcp-elicitation` / `helper-ui`），`ab_confirm` 从工具面移除（保留只读 `ab_confirm_status` 查 pending）。
1. `approval.mjs` + `approval-ui.mjs`：本机网页审批，`actionHash` 绑定、TTL 2 分钟、单次消费、fail-closed。
2. 删除 `ab_confirm` 自批路径；所有 high-risk 工具走审批（先覆盖：`ab_navigate`（仅高风险 URL/提交）、`ab_login`、`ab_download_open`、`cua_click`、`cua_type`、`cua_key`、`browser_eval`、`ab_cdp` 敏感方法）。
3. 审计事件 + `ab_audit` 过滤。
4. `session_finalize` 接线 + 会话级批准清理。
5. 测试与文档。

### P1（2–4 天）
1. 风险分类完整落地（§3.2），覆盖全部 30 个工具。
2. 持久授权：origin/app/session/turn；`approvals.json` 管理命令。
3. `browser_eval`/`tab_eval` 策略改造（堵 `_cmd`/`eval`）。
4. CUA per-app 授权（首用某 App 弹窗，可“总是允许”）。
5. 审计 schema 对齐 Codex `security_check`（含 `decided_by`、`reason`、`risk`）。

### P2（可选）
1. MCP elicitation 通道（客户端支持时优先，升级 SDK 并探测 capability）。
2. 本机 WS 鉴权（per-start 随机 token + 对端进程校验）。
3. 远程审批链接（一次性 HTTPS/反代可另行设计；默认不做）。
4. 低风险自动放行规则（默认关闭，审计标注 auto）。
5. **审批账本 + 撤销 + `cua_session_stop`**（对标 Codex `approval-log` 与 session stop：可查看/撤销已授授权、一键停止 CUA 会话）。

---

## 6. 验收测试（可自动化，写进 `test/approval.test.mjs`）

| # | 断言 | 方法 |
|---|---|---|
| 1 | **模型无法自批**：工具面不存在任何能返回“已批准”的工具（`ab_confirm` 返回错误） | 列举 `server` 工具 → 调 `ab_confirm` 期望错误 |
| 2 | 高风险动作在用户未响应时**阻塞**，超时后返回 `APPROVAL_TIMEOUT` 且动作未执行 | 起 service + mock UI 不响应 → 调用工具 → 断言未执行 |
| 3 | 用户点“拒绝” → 返回 `USER_DENIED` 且动作未执行、审计有 `decided_by:user` | mock UI POST deny |
| 4 | 用户点“允许一次” → 动作执行一次；再调用需再次批准 | 两次调用断言 |
| 5 | “本会话允许” → 同 session 第二次不再弹窗；新 session 仍弹 | 两 session |
| 6 | 令牌**不可重放**：同一 `approvalId` 第二次使用被拒 | 直接调内部接口 |
| 7 | `actionHash` 绑定：批准后篡改动作参数 → 拒绝 | 修改 payload 重试 |
| 8 | `browser_eval` 内部 `_cmd`/`eval` 不能绕过 high-risk 审批 | 构造脚本 |
| 9 | 审计含 `approval_id`、`risk`、`persist`、`reason`；`ab_audit` 可按 `cmd=approval` 过滤 | 查询审计文件 |
| 10 | 本机 UI 只监听 127.0.0.1，路径一次性，Host/Origin 校验 | HTTP 测试 |
| 11 | `session_finalize` 后租约释放、agent 页关闭、会话级批准清空 | 模拟 stdin EOF |

---

## 7. 不抄清单（避免引入 Codex 的代价）

- ❌ 云端 `site_status` 裁决（agentdesk 卖点是纯本地）
- ❌ 锁屏解锁 / AuthorizationPlugin（红线，且审核风险极高）
- ❌ 全时活动录制（Skysight / Computer History）
- ❌ 强制遥测（审计留在本地即可）
- ❌ 742MB 多进程 Electron UI（用本机网页/系统对话框即可）

---

## 8. 一句话给决策者

**先把“门”修好（P0），再谈补功能（P1）。** Codex 的可信度来自“模型碰不到批准按钮”，不是来自规则多；agentdesk 现有代码里 `ab_confirm` 把按钮交给了模型，这一步不改，后面补的浏览器/屏幕能力都会放大风险。P0 只动 6 个文件 + 1 个新文件，不改扩展，不引入云依赖。
