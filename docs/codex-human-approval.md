# Codex 的“人类确认”是怎么做的（端到端逆向）

> 分析日期：2026-11-10。对象：本机 ChatGPT Desktop 26.1103.60933 / Codex CLI 0.167.0-alpha.3.2 / 已安装 ChatGPT Chrome 扩展 1.26.1102.11740 / Codex Computer Use 26.1102.1001824。
> 方法：REA（app.asar ASAR 头解析 + JS 静态分析 `ev_6f8c0ae0…` / `ev_d95e095c…`；原生 Mach-O 元数据）+ 官方 CLI 生成协议（`codex app-server generate-json-schema`、`generate-ts`）+ 已安装扩展源码静态读。
> 结论分级：**观测**（协议类型、UI 文案、代码字符串）与**推断**（组合语义）分开标注；未运行任何 Codex 服务、未读用户会话内容。

---

## 0. 一句话

Codex 的确认**不是靠提示词求模型自觉**，而是把“危险动作”变成 **agent 进程 → 用户界面的一次阻塞式请求**：模型这一轮必须停下来，等**人**在客户端点“允许/拒绝”，结果以结构化字段回传；模型**没有任何工具**可以替用户批准。agentdesk 的 `ab_confirm` 恰好相反——它是模型可调用的工具，等于模型自己盖章。

---

## 1. 全景：谁问谁

```
模型（在 app-server 里跑）
   │ 想执行：跑命令 / 改文件 / 用 MCP 工具 / 要权限 / 操作电脑
   ▼
app-server（Codex CLI 进程，JSON-RPC 服务端）
   │ 发现该动作需要人类确认 → 发「服务器→客户端请求」
   ▼
客户端（ChatGPT 桌面 app / 扩展 side panel / 远程设备）
   │ 渲染审批卡片 → 用户点「允许一次 / 允许本对话 / 总是允许 / 拒绝」
   ▼
app-server 收到 decision → 放行 / 拒绝 / 记录持久授权 → 继续或中止该动作
```

关键点：**方向是 server→client 的请求**（不是模型发起的工具调用），并带 `id` 用于关联；客户端回包后 app-server 才继续。浏览器侧的 gate 也走同一通道：Codex 的 Chrome 扩展自己**只发 elicitation 请求、不渲染 UI**（审批 UI 全在 Codex 桌面端/前端的 `approvalRequestCard`）。

---

## 2. 协议层：10 种“服务器问客户端”的请求（权威，来自生成的 TS/JSON Schema）

来源：`.codex-analysis/appserver-ts/ServerRequest.ts`（由 `codex app-server generate-ts` 生成）、`.codex-analysis/appserver-schema/*.json`。

| # | method | 用途 | 响应字段 |
|---|---|---|---|
| 1 | `item/commandExecution/requestApproval` | 要执行 shell 命令 / 写 stdin | `{decision}`，枚举见下 |
| 2 | `item/fileChange/requestApproval` | 要改文件/补丁 | `{decision: accept\|acceptForSession\|decline\|cancel}` |
| 3 | `item/permissions/requestApproval` | 要扩大沙箱权限（读写路径/网络） | `{permissions, scope: turn\|session, strictAutoReview?}` |
| 4 | `mcpServer/elicitation/request` | **MCP 工具/连接器/电脑操作等任意“问用户”**（form/url 模式） | `{action: accept\|decline\|cancel, content?, _meta?}` |
| 5 | `item/tool/requestUserInput` | 结构化提问（选择题/自由输入/密码） | `{answers: {questionId: {answers:[...]}}}` |
| 6 | `item/tool/call` | 动态工具调用审批 | 动态工具结果 |
| 7 | `account/chatgptAuthTokens/refresh` | 刷新登录令牌 | 令牌 |
| 8 | `attestation/generate` | 设备证明 | 证明 |
| 9 | `applyPatchApproval`（legacy） | 旧版补丁审批 | `{decision: ReviewDecision}` |
| 10 | `execCommandApproval`（legacy） | 旧版命令审批 | `{decision: ReviewDecision}` |

### 2.1 决策枚举（真实字段值）

- 命令审批 `CommandExecutionApprovalDecision`：
  `"accept"`（允许一次）／`"acceptForSession"`（本会话都允许）／`{acceptWithExecpolicyAmendment:{execpolicy_amendment}}`（**允许“类似命令”并写入前缀规则**）／`{applyNetworkPolicyAmendment:{network_policy_amendment}}`（允许某主机）／`"decline"`／`"cancel"`。
- 文件审批 `FileChangeApprovalDecision`：`accept | acceptForSession | decline | cancel`。
- 旧版 `ReviewDecision`：`approved` / `approved_for_session` / `approved_execpolicy_amendment` / `approved_mcp_policy_amendment` / `network_policy_amendment` / `{denied:{rejection}}`（**拒绝可带原因**）/ `timed_out` / `abort`。
- Elicitation `McpServerElicitationAction`：`accept | decline | cancel`，accept 时 `content` 携带表单值，`_meta` 可带 `persist`（持久化档位）。
- 权限审批：`scope: "turn" | "session"` + `strictAutoReview`（本 turn 每条命令都再审核一次）。

### 2.2 请求里都带什么（让用户能判断）

`CommandExecutionRequestApprovalParams`（节选）：
`kind(command|humanCommand|writeStdin)`、`threadId`、`turnId`、`itemId`、`startedAtMs`、`approvalId?`、`environmentId`、`reason?`、`networkApprovalContext?`、`command?`、`cwd?`、`commandActions?`（解析后的友好展示）、`proposedExecpolicyAmendment?`（“以后类似的命令不用再问”提案）、`proposedNetworkPolicyAmendments?`（放行哪些主机）。

`McpServerElicitationRequestParams`（节选）：
`threadId`、`turnId?`、`serverName`，以及四种模式之一：
- `mode:"form"`：`message` + `requestedSchema`（标准 MCP elicitation schema，可为字符串/数字/布尔/枚举/多选等）
- `mode:"openai/form"` / `"openaiForm"`：`message` + 自由 JSON schema
- `mode:"url"`：`message` + `url` + `elicitationId`（跳到认证/确认页面，完成后回传）

`ToolRequestUserInputParams`：`questions[]`，每项 `{id, header, question, isOther, isSecret, options?}`；`isBlocking`。响应按 question id 映射答案。

`serverRequest/resolved` 通知：任何审批被解决时广播 `{threadId, requestId}`，前端据此收起卡片。

### 2.3 自动审核（guardian）不是“代批准”

`item/autoApprovalReview/started|completed` 与 `autoApprovalReview/strictReviewRequired` 通知表明：Codex 还有一层自动 review（由另一个 reviewer 决定，`decided_by=automated_review`）。但它是**在请求到达用户之前的一道筛选**，不是模型自己批准；且可以开“严格审核”强制逐条再问。超时与取消也分别有语义（`timed_out` ≠ 拒绝、`cancel` ≠ 拒绝）。

### 2.4 “真人级”确认：`openai/userVerification`（Touch ID / 手机扫码）

Codex 在 elicitation 之上还有一层**真人证明**（来自 `.codex-analysis/05-appserver-approval.md` §6，实验性协议）：

- 服务端生成 challenge，客户端用**本机 P-256/SHA-256 私钥对 challenge 签名**（`userVerification/{status,enroll,verify,cancel,delete}`），proof = `{credentialId, signature}`；UI 文案为 **“Approve with Touch ID”** 或手机扫码接管。
- 关键：**模型既不能渲染 elicitation，也拿不到私钥**，所以无法伪造“用户已确认”。
- agentdesk 可把它当 P2 增强项（本地密钥 + Touch ID 签名），但 P0 只需要“人类点击”就已消除自批。

---

## 3. 客户端 UI：用户实际看到什么（来自 app.asar 真实字符串与代码）

从 app.asar 里抽出的 13 个真实 webview 模块中定位到 `approvalRequestCard.*` / `composer.computerUseAppApproval.*` / `composer.mcpToolCallApproval.*`：

| 按钮/元素 | 英文原文 | 中文含义 | 回传 |
|---|---|---|---|
| 主按钮 | `Allow once` | 只允许这次 | `action:"accept"`（无 persist） |
| 次按钮 | `Allow this conversation` | 本对话都允许（会话级） | `action:"accept", persist:"session"` |
| 次按钮 | `Always allow` | 总是允许（若 `persistModes` 含 `always`） | `action:"accept", persist:"always"` |
| 拒绝 | `Deny` + `Reason` 输入 | 拒绝，可写原因 | `action:"decline"`（命令类可带 rejection 文本） |
| 折叠 | `approvalOptions` / `reasonLabel` / `Elevated Risk` | 审批选项/原因/高风险标记 | — |
| 自动审核引导 | `Want fewer approval requests?` + `enable` / `keepManual` | 引导开启“自动审核”以减少弹窗，或保持手动 | 写设置 |
| 站点授权 | `allow_all_relevant_sites` / `allow_for_this_chat` | 浏览器站点访问：允许所有相关站点/只允许本对话 | 站点级持久授权 |
| 命令审批 | `allowSimilarCommands` / `allowConversation.commandPrefixInfo` | 允许“类似命令”（前缀规则） | `acceptWithExecpolicyAmendment` |
| CUA 按 App 授权 | `Allow ChatGPT to use {app}?` / `Always allow` / `Allow this conversation` | 是否允许操作某 App，可持久 | elicitation `accept` + `persist` |

代码事实（webview chunk `447401/611468` 等）：
- 客户端通过 `replyWithMcpServerElicitationResponse(conversationId, requestId, response)` 回包；`response` 由 helper 组装成 `{action, persist?}`。
- `persistModes` 由**服务端请求携带**，客户端只渲染服务端允许的档位（`persistModes.includes("always")` 才显示“总是允许”）。
- 还有 `replyWithUserInputResponse`、`replyWithOptionPickerResponse`、`thread-follower-submit-mcp-server-elicitation-response`——**远程设备（手机/另一台电脑）也能回复审批**。

---

## 4. 浏览器侧：16 道闸门 + 8 类 authority（来自 browser-service 逆向）

`browser-service.mjs`（1.6MB 打包产物）的 `assert()` 是三段式：
1. **收集**本动作命中的所有 gate；
2. **policy** 并行判定、失败即拒（fail-fast）；
3. **approval 工厂**并行预检、再**逐条串行**向用户提问。

| 项 | 内容（证据：`.codex-analysis/06-browser-gates.md`，锚点 `BS:行@字节`） |
|---|---|
| 闸门 | 16 个 provider：hostUrl / urlPolicy / siteStatus / originPolicy / originApproval / historyPolicy / historyApproval / upload×2 / download×2 / fullCdp×3 / webMcp×2 |
| authority | 8 类（谁有权批：用户、会话、持久授权、自动审核、企业策略等） |
| 审批请求 | 11 类真实形状（origin/history/upload/download/page-asset/fullCdp/webMCP/SIWC/browser_auth/email_otp/precheck），每类带 `message` + `_meta`（`tool_name`、`tool_params`、`persist`、`codex_request_type`、`codex_strict_auto_review` 等） |
| 持久化 | 不在浏览器存储，而是 Codex TOML：`~/.codex/browser/config.toml`（全局）+ `sessions/<id>.toml`（会话）；key 如 `approval_mode`、`origins{allowed,denied}`、`full_cdp`、`downloads`、`uploads`、`webmcp`、`history_approval_mode`；内存三层缓存；scope 短路链 8 级 |
| 远端裁决 | `GET https://chatgpt.com/backend-api/aura/site_status`（hostname 缓存 24h）；普通路径失败**放行**、`page_content` 路径失败**关闭**；localhost 跳过 |
| 设计细节 | 超时 ≠ 拒绝（guardian 哨兵，可重试）、取消 ≠ 拒绝、guardian 是另一个 reviewer（`decided_by=automated_review`）、security mode 三档可整体旁路 |

**扩展侧不分决策**：已安装的 Codex 扩展只发 `elicitation/create`，把 `_meta`（`codex_approval_kind=mcp_tool_call`、`codex_request_type=approval_request`、`tool_name/persist/origin` 等）交给宿主渲染；扩展内只有 3 类本地 UI（首次允许浏览器控制、下载来源页、麦克风/摄像头）。证据：`.codex-analysis/04-chrome-extension.md`。

---

## 5. 电脑操作（CUA）侧的审批（原生 + app.asar 字符串）

| 审批类型 | 触发 | 用户可见文案 | 持久化/状态 |
|---|---|---|---|
| 按 App 授权 | 第一次操作某个 App | `Allow ChatGPT to use {app}?` + `Always allow` / `Allow this conversation` | `AppApprovalStore`（once/session/turn/always；`persistModes` 由服务端给） |
| 消息读取 | 读取 iMessage/短信 | `Allow reading messages in your chat with ...` / 读取最近聊天 | `MessagesReadDecisionStore`；操作枚举 `READ_MESSAGES/SEARCH_MESSAGES/READ_IMAGE` |
| 消息发送 | 代发消息 | `Allow sending` / `Always allow sending to this chat` | `MessagesSendApprovalStore`；持久化 `ONCE/SESSION/TURN/ALWAYS` |
| 录屏/回放 | 启动 Record & Replay | 录制告知 + 开始审批（`RecordAndReplayRecordingStartApprovalRequested`） | 独立的记录授权 |
| 锁屏使用 | 打开“Locked use” | `Let ChatGPT use your Mac when it's locked` | 设置项 + 锁屏 Guardian/AuthorizationPlugin |
| 系统权限 | 首次 | 辅助功能 / 屏幕录制 / 日历 / 联系人 / Apple Events | macOS TCC（权限挂 `com.openai.sky.CUAService` 独立 App） |

补充（来自 `.codex-analysis/07-cua-approval.md`，1117 行/56 表）：

- **5 层门**：总开关 → 组织策略（`ComputerUseRequirements`）→ TCC → **per-app 首次授权** → 动作级 elicitation；共 12 类。
- **per-app 落盘**（App Group `2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/`）：
  `ComputerUseAppApprovals.json`、`MessagesReadDecisions.json`、`MessagesSendApprovals.json`；持久化枚举 `ONCE/TURN/SESSION/ALWAYS`。
- **风险档**：`low/high` + `warningSubtitle` + `allowPersistentApproval`；**高风险不给“始终允许”**（错误码 `appApprovalPersistenceUnavailable`）。
- **读写分离**（Messages）：读有全局策略 + per-chat `ReadDecision`；发送有 per-chat 持久许可 + `allowAllChats`；被拒内容标 `permission_filtered`，外发正文可被用户编辑（`user_edited`）并限速。
- **录屏回放**：一次性同意、≤30 分钟、不持久化；**锁屏使用**：设置项 + 特权 AuthorizationPlugin + 每线程自动解锁（不建议抄，见 §7）。

证据：`.codex-analysis/02-cua-channel.md`、`.codex-analysis/07-cua-approval.md`；原生类名 `AppApprovalStore`、`MessagesReadDecisionStore`、`MessagesSendApprovalStore`、`CUALockScreenGuardianClient`（REA `ev_e6df9dda…`、`ev_b48700f4…`）。

---

## 6. 一句话对照 agentdesk

| 环节 | Codex | agentdesk 现状 |
|---|---|---|
| 谁发起确认 | 服务端在**动作点**发请求 | 模型调用 `ab_confirm` 工具（**模型可自批**） |
| 谁批准 | 人（桌面 app/扩展 sidepanel/远程设备） | 模型自己 |
| 请求带什么 | action、目标、风险、原因、持久化档位、可“允许类似” | 只有 `kind` + token |
| 决策粒度 | accept / acceptForSession / 带 amendment / decline（可带原因）/ cancel / timeout | 通过/不通过 |
| 持久化 | TOML 全局+会话、origin 表、app 表、execpolicy 前缀 | 无 |
| 覆盖面 | 16 浏览器闸门 + 命令/文件/权限/CUA/消息/录屏 | 6 类动作（且 `browser_eval` 可绕过） |
| 远程审批 | 支持（thread-follower） | 无 |
| 审计 | `security_check` 形态 + `decided_by` | 有审计（这一项 agentdesk 更好：本地可查） |

**结论：Codex 的“有效”不是因为规则多，而是因为“确认请求不可能被模型自己满足”。agentdesk 只要把这一条修掉，安全叙事才成立；否则功能补得越多风险越大。**

---

## 附录：证据索引

| 内容 | 证据 |
|---|---|
| app-server 协议（10 类 server→client 请求、决策枚举、字段） | 本机 `codex app-server generate-ts -o .codex-analysis/appserver-ts` / `generate-json-schema`；文件 `ServerRequest.ts`、`ReviewDecision.ts`、`*ApprovalParams/Response.ts`、`v2/*.ts` |
| 客户端审批 UI 与回传代码 | app.asar 抽取的 webview 模块（`.codex-analysis/asar-approval/`）；REA JS 分析 `ev_6f8c0ae0…`（parent）、`ev_d95e095c…`（view）；命中 `approvalRequestCard.*`、`replyWithMcpServerElicitationResponse`、`persistModes` |
| 浏览器 16 闸门/8 authority/11 审批形状/TOML 持久化/site_status | `.codex-analysis/06-browser-gates.md`（`BS:行@字节` 锚点） |
| 扩展只发 elicitation、两套 MCP 端点、js-kernel 三层沙箱 | `.codex-analysis/04-chrome-extension.md` |
| CUA 审批/权限模型 | `.codex-analysis/02-cua-channel.md`、`.codex-analysis/07-cua-approval.md`；REA `ev_fd1b7a0b…`（权限 App plist）、`ev_2596a4ac…`（entitlements） |
| app-server 审批协议全量 | `.codex-analysis/05-appserver-approval.md`（11 类 server→client 请求、6 类审批/交互、decision 枚举、userVerification、UI 映射）；生成物 `.codex-analysis/appserver-schema/`、`appserver-ts/` |
| 浏览器 16 闸门/8 authority/11 审批形状 | `.codex-analysis/06-browser-gates.md` |
| 已安装扩展（两套 MCP 端点/三层 js-kernel 沙箱/审批外置） | `.codex-analysis/04-chrome-extension.md` |
