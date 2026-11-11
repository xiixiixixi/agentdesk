# Codex vs agentdesk —— 逐子系统逆向对比与代码级证据

> 分析时间：2026-11-10　分析对象：本机安装的 OpenAI Codex（ChatGPT Desktop 26.1103.60933 + Codex CLI 0.167.0-alpha.3.2 + Codex Computer Use 26.1102.1001824）vs 本仓库 agentdesk v1.0.0。
> 方法：REA MCP 6.8.0（`open_binary` / `inspect_macho` / `inspect_native_dispatch_metadata` / `inspect_signature` / `inspect_plist` / `inspect_rust_binary` / `inspect_desktop_application`）+ 三路静态代码审计（见附录 A）。
> 边界：**没有执行任何 Codex 程序**（未启动 CUA 服务、未运行 MCP 服务器、未读用户会话/记忆内容）；本机没有 Ghidra/Hopper，原生部分只有 Mach-O 元数据/符号/依赖/签名/Info.plist 级证据，**没有反编译伪代码**，因此涉及“某函数具体怎么写”的结论一律标注为推断或未知。

---

## 0. 一页结论

| 问题 | 结论 |
|---|---|
| Codex 这套东西和 agentdesk 是同一类产品吗？ | **不完全是**。agentdesk 是“给任意 MCP 客户端用的本地双通道桥”；Codex 是“一个完整 agent 运行时，自带浏览器/屏幕执行体”。可比的是**执行体底座**，不可比的是**agent 运行时之上的一切**。 |
| 只比“浏览器 + 屏幕操控底座”，谁强？ | **Codex 强一个量级**。差距最大的不是动作数量，而是：审批权威体系、系统级权限/锁屏集成、远程流式 CUA、插件/记忆/多 MCP 服务、持久 REPL 语义。 |
| agentdesk 还有活路吗？ | 有，而且定位清晰：**纯本地、凭据零进模型、动作级可查审计、前后证据对、轻量可审计**。这些 Codex 要么没有、要么是云依赖的反面。 |
| 结论一句话 | Codex 是“工业级 agent 执行体”，agentdesk 是“本地透明可审计的操控桥”。前者功能面碾压，后者隐私/审计/轻量/可控性占优；agentdesk 当前最该补的是**审批的人类回路与策略覆盖面**（这是 Codex 做得最深、agentdesk 最薄的一环）。 |

**Codex 强在哪（Top 7）**：① 15 道审批 gate + 8 类 authority + 持久授权 + MCP elicitation + guardian auto-review；② 浏览器 API 表达力（Playwright 34 方法 + `frameLocator`/iframe + 剪贴板 + AX 9 动作 + 内容导出 + 页面内 CUA）；③ 屏幕动作面（`setValue`/`selectText`/`paste(format)`/`performSecondaryAction`/音频/跨平台/AX diff）；④ 多 TCC 权限 + per-app 策略 + URL blocklist + **锁屏 Guardian/自动解锁 + AuthorizationPlugin**；⑤ 远程投递 CUA（H.264 帧 + operation fence + 光标同步 + Remote PIP）；⑥ 持久 REPL + 文档/UI state 注入 + `completion_summary` + 每 turn `get_app_state` 纪律；⑦ 插件/hooks/skills/code mode/多 agent/记忆（Skysight/Computer History）生态。

**agentdesk 仍强在哪（Top 7）**：① 真实登录态 + 凭据仓（钥匙串 + 双锁 + 本地 TOTP，凭据零进模型/日志/审计）；② 动作级本地 JSONL 审计 + 脱敏 + `ab_audit` 可查；③ `cua_verify` 动作前后截图证据对；④ 幽魂光标（不移动真实光标、可关、不入审计）；⑤ A/B/C 显式降级 + capabilities 矩阵 + guidance；⑥ 纯本地/零云/无账号 + 批量隐形读页 + 实时投屏帧；⑦ 多客户端 frontend 共享 + 端口接管自愈 + 158 单测/伪扩展自检/e2e/verify。

---

## 0.1 第二轮深挖的增量结论（同日，审批机制专题）

第一轮留的最大空白——**Codex 已安装 Chrome 扩展本体**与**人类确认的端到端协议**——已补齐，结论对前文有 3 处修正/加强：

| # | 新发现 | 影响 |
|---|---|---|
| 1 | **审批方向是 server→client 请求，模型没有任何批准入口**。app-server 有 11 种服务器→客户端请求（6 类审批/交互），含 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval`、`item/permissions/requestApproval`、`mcpServer/elicitation/request`、`item/tool/requestUserInput`、`item/tool/call`；决策枚举含 `accept/acceptForSession/acceptWithExecpolicyAmendment/…/decline/cancel`。**agentdesk 的 `ab_confirm` 是模型可调工具 → 自批，这是优先级最高的差距** | 前文 §3.2 判断加强：不只“更全”，是**机制方向相反** |
| 2 | **“真人级”确认确实存在**：`openai/userVerification` 用本机 P-256/SHA-256 对 challenge 签名（Touch ID/手机扫码），模型既不能渲染 elicitation 也拿不到私钥 | 给 agentdesk 提供了可选的“真人证明”升级路径（见改造蓝图 §3.3） |
| 3 | **已安装扩展源码已完整分析**（v1.26.1102.11740，3.5MB，build sha `52add2ca…`）：扩展有**两套 MCP 端点 + 一个 app-server 代理**；模型代码跑在 **offscreen→js-kernel-host→sandbox iframe→Blob Worker** 四层；**审批完全外置**（扩展只发 `elicitation/create`，UI 在 Codex 桌面端）；另有 **per-tab DNR 网络策略 + agent 请求头 + turn-scoped kernel** | 前文“扩展本体不可见”的未知项已消除；agentdesk 可对齐的机制更多 |

新增详细文档：`docs/codex-human-approval.md`（Codex 确认机制端到端）、`docs/agentdesk-approval-upgrade-plan.md`（agentdesk 落地蓝图）。新增证据台账：`.codex-analysis/04-chrome-extension.md`、`05-appserver-approval.md`、`06-browser-gates.md`、`07-cua-approval.md`，以及生成物 `.codex-analysis/appserver-schema/`、`appserver-ts/`、`asar-approval/`。

---

## 1. 分析对象与方法

### 1.1 制品清单（全部为本机已安装的发布物）

| 制品 | 版本/大小 | 证据（REA / 静态） |
|---|---|---|
| `Codex Computer Use.app`（权限主体） | 26.1102.1001824 / 65 MB | `inspect_plist`：`com.openai.sky.CUAService`、`LSUIElement=true`、`LSMinimumSystemVersion=14.4`、Sparkle 自动更新；EID `ev_fd1b7a0b…689b92f` |
| `SkyComputerUseService`（CUA 服务主二进制） | 21,633,216 B、arm64、43,876 exports / 4,692 imports / **70 dylibs** | `inspect_macho` EID `ev_35ad8752…dc186d`；依赖含 `ScreenCaptureKit`、`ApplicationServices`(AX)、`AVFoundation`、`WebKit`、`Contacts`、`EventKit`、`MapKit`、`Intents`、`SwiftUI`、`SwiftProtobuf` |
| `SkyComputerUseClient`（MCP 宿主） | 12,145,792 B、27,557 exports / 50 dylibs | `inspect_macho` EID `ev_70c2a169…5dc61d8`；`inspect_native_dispatch_metadata` EID `ev_e6df9dda…bc58bd2` |
| `CUALockScreenGuardian.app` | 21,279,792 B、43,877 exports | `inspect_macho` EID `ev_7c4c1f5e…a94245`；XPC 协议见 §3.4 |
| `CodexComputerUseAuthorizationPlugin.bundle` | 67,872 B、5 dylibs / 32 imports | `inspect_macho` EID `ev_078cfb45…a676b9`；`inspect_signature` EID `ev_3473fc03…f44c7e`（硬运行时、无 entitlements、Developer ID OpenAI） |
| Chrome 插件 `openai-bundled/chrome/26.1103.60933` | browser-service.mjs 1,618,954 B；api.json 66,655 B（22 interfaces / 148 members / 67 types）；native host `ChatGPT for Chrome` 1,059,472 B（Rust） | `inspect_macho` EID `ev_8d6b018c…86eb01`；`strings` 见附录 B |
| 已安装 Chrome 扩展 `hehggadaopoacecdllhhajmbjkdcmajg` **1.26.1102.11740** | 3.5 MB 源码已分析：background.js 546 KB、js-kernel-host 1.3 MB、js-kernel 201 KB、sidepanel、content scripts；build sha `52add2ca…`；native host 清单 `com.openai.codexextension.json` | 第二轮静态源码审计（`.codex-analysis/04-chrome-extension.md`） |
| `@oai/cua` / `@oai/cua-repl` / `@oai/sky` / `@oai/browser-desktop` | 0.2.6 / 0.1.3 / 0.7.17 / 0.1.1（cua_node 272 MB） | 静态读 d.ts/docs（附录 A 02） |
| Codex CLI（ChatGPT 内置） | `0.167.0-alpha.3.2`，主二进制 270,814,880 B；`codex-code-mode-host` 70,309,840 B；`codex-exec-server` 61,037,552 B | 只读执行 `--version/--help/features list`；`inspect_rust_binary`（无 cargo-auditable 元数据，EID `ev_5d66e721…35dfcf`） |
| ChatGPT Desktop | 26.1103.60933，app.asar 742 MB，Electron | `inspect_desktop_application` EID `ev_1558763d…32a97`（候选：Electron） |
| agentdesk | v1.0.0，12,391 行，158 个 test | 仓库审计（附录 A 03） |

### 1.2 证据分级（本文遵守）

- **观测（observed）**：Mach-O 元数据、符号/类/协议/selector、dylib/imports/exports 计数、签名与 entitlements、Info.plist、JS/文档源码、CLI `--help/features`。
- **推断（inferred）**：由类名/XPC 协议/字符串组合出的架构语义（如“远程投递 CUA”“锁屏自动解锁租约”）。
- **未知（unknown）**：没有反编译得到的函数体行为、服务端 gate 判定逻辑的实现细节、defaults（用户本机 `~/.codex/browser/config.toml` 是个人配置，不代表默认值）。第二轮已补齐 Codex Chrome 扩展本体与服务端审批协议（见 §0.1）。

REA 证据 ID 全表见附录 B。

---

## 2. 双方架构总览

### 2.1 agentdesk（5 层，全部本地）

```
MCP 客户端 ──stdio──> service/mcp-entry.mjs（MCP 30 工具 + browser_eval）
                        service/api + policy + audit + connection（WS 服务端 / 租约镜像）
                          ▲ ws://127.0.0.1 JSON-RPC 2.0
                        host/host.mjs（哑中继，无浏览器逻辑）
                          ▲ Chrome Native Messaging
                        extension/background.js（MV3：租约权威 + chrome.debugger CDP）
屏幕通道：service/cua.mjs → ~/.agentdesk/CUA Helper.app（swift/cua-helper.swift，TCC 主体）/ osascript 兜底
```

关键事实：协议单一事实来源 `shared/protocol.mjs`（43 命令/11 事件/73 项 CDP 白名单）；租约权威在扩展；多实例 EADDRINUSE 自动转 frontend 共享；service 死亡端口接管；**本机 WS 无鉴权**。

### 2.2 Codex（本机可见的 6 层，云端是其中一层）

```
ChatGPT 云端 / backend-api（模型 + site_status 裁决 + remote control websocket）
   │
ChatGPT Desktop（Electron，app.asar 742MB）── codex app-server（Rust，CLI 0.167.0-alpha.3.2）
   │     ├ plugins：browser / chrome / unified-computer-use / computer-use / codex-app-tools
   │     ├ hooks：Stop / Interrupt / SubagentStop → mcp_tool turn_ended
   │     └ node_repl（Rust）── cua_repl MCP（js / js_reset / turn_ended）── trusted worker
   │            ├ @oai/browser-desktop（浏览器 API：Playwright + AX + CUA + content export）
   │            └ @oai/sky（macOS 原生 CUA 客户端）
   ├ SkyComputerUseClient（Swift，充当 5 个 MCP server：computer use / messages / calendar /
   │        computer history / event stream）─ XPC（protobuf + file descriptors）→
   │        SkyComputerUseService（ScreenCaptureKit + AX + 70 frameworks）
   │             ├ CUALockScreenGuardian + AuthorizationPlugin（锁屏/解锁）
   │             └ RemoteHostedPIP：publishFrame(H.264) + operation fence + cursor 同步
   └ Chrome native host `ChatGPT for Chrome`（Rust，1MB，WebSocket ↔ NativeMessaging，
          校验对端代码签名 team=2DC432GLL2，代理 app-server）
                └ Chrome/Edge 扩展（Web Store "ChatGPT"/Codex）── CDP + Playwright 风格 API
```

**架构性差异**：Codex 是“**云端/桌面 agent 的薄本地执行体**”（屏幕以编码帧外发、权限/审批在服务与 UI、浏览器操作走 API+gate）；agentdesk 是“**厚本地 MCP 服务**”（决策、凭据、审计、策略全在本地）。

---

## 3. 逐子系统对比

> 每节格式：双方实现事实（带代码/证据引用）→ 判定。三份台账合计给出 **41 + 19 个对比维度**（浏览器侧：Codex 更强 23、agentdesk 更强 12、平手 6；CUA 侧另计），完整证据见 `.codex-analysis/01-browser-channel.md`、`02-cua-channel.md`、`03-agentdesk-inventory.md`。

### 3.1 浏览器工具面 / API 表达力

| 能力 | Codex（chrome 插件 + browser-service） | agentdesk（21 个浏览器 MCP 工具 + browser_eval） | 判定 |
|---|---|---|---|
| API 规模 | `docs/api.json`：22 interfaces / 148 members / 67 types；模型侧由 node_repl `setup` 下发 manifest，Proxy 按 `disabledMemberIds` 过滤 | 21 个 ab_* 工具 + browser_eval 注入的 Agent API（browsers/tabs/tab.playwright/tab.eval…） | Codex |
| 定位器 | **Playwright 全量**：`frameLocator`（iframe）、`getByRole/Text/Label/Placeholder/TestId/locator/filter/and/or/nth/first/last/all/waitFor/check/selectOption/setChecked/uncheck/fill/type/pressSequentially/downloadMedia` 等 34 方法 | 自研 locator：css/role/text/label/testid/placeholder；`nth/first` 被忽略、`and` 无实现、`textContent` 返回对象、无 actionability 检查；**iframe 不支持** | **Codex（代差级）** |
| AX/无障碍 | `Tab.ax`：click/drag/get/paste/performSecondaryAction/pressKey/scroll/selectText/setValue/typeText/write（9 动作 + 4MB brotli wasm 做 revision/diff/identity/isValueSettable；但 4 个后端默认禁用，需要 `apiSupportOverrides`） | `ab_ax_state` 只读文本树；扩展有 `tab_ax_action` 但 service/api 未暴露 → **实际只读** | Codex |
| 剪贴板 | `Tab.clipboard.read/readText/write/writeText` | 无（`tab_clipboard_write_text` 恒返回不支持） | Codex |
| 内容导出 | `Tab.content.export / exportGsuite / exportYouTubeTranscript` | 只有 `ab_read_urls` 批量读正文 + recipes 里的 YouTube 字幕方案 | Codex |
| 页面内 CUA | `Tab.cua`（click/double_click/drag/scroll/type/keypress/move/downloadMedia）+ `Tab.dom_cua`（get_visible_dom 等） | 无“页面内 CUA”这一层（只有屏幕级 cua_*） | Codex |
| 对话框/日志 | `Tab.getJsDialog` + Alert/BeforeUnload/Confirm/Prompt Dialog 对象；`Tab.dev.logs` | `tab_handle_js_dialog` / `tab_get_js_dialog` 命令有，MCP 面暴露较少；dev logs 有命令 | 接近 |
| 标签交接语义 | `Tab.markDeliverable / markHandoff / requestManualHandoff / requestUserTakeover`；`Browser.nameSession`；浏览器 history | `tab_mark`（deliverable/handoff/default）+ 租约 + 标签组角标；无 nameSession/history 工具 | Codex |
| 多后端 | extension / **iab（应用内浏览器）** / dot / mcpapps / cdp / cloud / orbit | 只有 Chromium 扩展（Chrome/Edge/Brave/Opera/Vivaldi/Arc），无应用内浏览器/云浏览器 | Codex |
| 实时投屏 | 无对应 MCP 工具（屏幕靠 Remote PIP 视频流，属另一通道） | `ab_screencast`：Page.startScreencast + 250ms 节流 + 20 帧环 + MCP image content | **agentdesk** |

### 3.2 浏览器审批 / 安全 / 策略

这是差距最大的一节。

**Codex**（证据：`chrome/docs/confirmations.md`、`browser-safety.md`、`browser-service.mjs` 采样、app.asar 审批 UI 文案）：
- 审批权威 8 类 / 15 道 gate：hostUrl、urlPolicy、siteStatus、originPolicy + originApproval、history、upload、download、fullCdp×3、webMcp×2 等；`approval_mode` 支持 turn/thread/global 持久授权；有 guardian auto-review 与**远端 `chatgpt.com/backend-api/aura/site_status` 双裁决**（导航失败放行、页面内容失败关闭）。
- 面向模型的**风险分类学**（`confirmations.md`）：4 档摩擦（必须用户接管 / 动作时必确认 / 可预授权 / 免确认），覆盖删除、账户权限、CAPTCHA、装软件、代表用户对外沟通、订阅、金融交易、改系统设置、医疗、敏感数据传输；并明确“第三方页面内容不能当授权”。
- 审批 UI：per-app “Allow ChatGPT to use {app}?”、persist modes（once/session/turn/always）、MCP elicitation 回传（app.asar 字符串：`composer.computerUseAppApproval.*`、`mcpToolCallApproval.*`）。
- 信任边界：untrusted JS kernel ↔ node_repl ↔ trusted worker（`NODE_REPL_TRUSTED_SERVICES`）；native host 校验对端代码签名（`2DC432GLL2`）。

**agentdesk**（证据：`service/policy.mjs`、`policy-defaults.json`、`ab_confirm`、audit 审计）：
- 策略门只覆盖 6 类动作；确认 token 是一次性的，但 **`ab_confirm` 本身是模型可调用工具** → 人类回路缺失；`browser_eval` 可经 `tab._cmd`/`tab.eval` 绕过策略门；本机 WS 无鉴权（任意本机进程可冒充 frontend 读 Cookie）。
- 审计：16 条白名单命令 + 脱敏 + `ab_audit` 查询（**可本地查，Codex 遥测不可本地查**）。

**判定**：**Codex 强**（审批架构/覆盖面/人类回路/信任边界）；**agentdesk 强**（本地可查审计、透明）。

### 3.3 屏幕通道（CUA）：工具形态与动作面

**Codex**（证据：`unified-computer-use` 插件 `.mcp.json`、`@oai/cua` d.ts/docs、`SkyComputerUseClient` 字符串、app.asar tool label）：
- 工具面只有 3 个：`js` / `js_reset` / `turn_ended`（+ 隐藏 `js_add_node_module_dir`）；真正的 CUA 能力是注入的 `cua` 对象 + 持久 JS REPL。
- 原生 MCP 工具名（另一条产品线，SkyComputerUseClient 字符串）：`list_apps`、`get_app_state`、`click`、`type_text`、`press_key`、`scroll`、`drag`、`set_value`、`select text`、`observe`、`read_image`，另有 `read_messages`/`search_messages`/`send_message`、`list_calendars`/`list_events`/`get_event`、`computer_history_*`。
- 动作面覆盖：`setValue`、`selectText`、`paste(text,{format:text|md|html})`、`performSecondaryAction`、音频录制、拖拽、剪贴板、AX diff、截图+状态一次返回、跨 mac/linux/windows。
- 状态纪律：`get_app_state` “每个 assistant turn 必须先调一次”；动作完成提示“Call `get_app_state` to fetch the updated UI state”。
- 文档注入：首次调用只允许一个入口 API，结果自动带“文档 + 初始 UI state”；`nodeRepl.write(text,itemId)` 分栏 + 按 requestMeta 去重 + `rewriteDocumentation()`；`completion_summary` 强制“CUA 子任务结束立刻且仅一次”。
- 多 MCP server：Computer Use / Messages / Calendar / Computer History / Event Stream 五个，加 Record&Replay（类名 + 审批文案可见）。

**agentdesk**（证据：`service/cua.mjs`、`swift/cua-helper.swift`、`service/mcp.mjs`）：
- 15 个细粒度工具：`cua_status/windows/ax_tree/screenshot/click/set_value/action/select_text/paste/scroll/drag/type/key/app_focus/verify`。
- 无持久 REPL 状态；无音频；只 macOS；浏览器与屏幕两套工具分离。

**判定**：**Codex 强**（动作面/编排效率/跨平台/多服务）；agentdesk 的可发现性与单步可策略性更强。

### 3.4 屏幕通道：权限、锁屏、远程投递

**Codex**（REA 观测 + 字符串推断）：
- 权限主体是独立签名的后台 App（`com.openai.sky.CUAService`，`LSUIElement=true`，Developer ID OpenAI 2DC432GLL2，hardened runtime）；entitlements 含 AppleEvents、AddressBook、Calendars、keychain-access-groups；Info.plist 有 AppleEvents/Calendars/Contacts 用途声明与 Sparkle 更新源。
- TCC 覆盖：Accessibility、Screen Recording（ScreenCaptureKit）、AppleEvents、Calendars、Contacts、Appshot（`Package_Appshot.bundle` + Appshot.wav）。
- **锁屏 Guardian**：`CUALockScreenGuardian.app` 与主服务共享 70 dylibs/43k exports；XPC 协议 `SAILockScreenGuardianXPCProtocol` 有 `beginUnlockGuardForThreadID:`、`completeUnlockGuardForThreadID:didUnlock:`、**`retainAutoUnlockedLeaseForThreadID:` / `releaseAutoUnlockedLeaseForThreadID:`**；另有 `lockScreenGuardianDetectedPhysicalInput` 回调 → 检测到用户物理输入时中止/释放。
- **AuthorizationPlugin**：`CodexComputerUseMechanism : NSObject` 实现 macOS AuthorizationPlugin 回调（`AuthorizationCallbacks`/`__OpaqueAuthorizationEngine`），imports `SecTaskCreateWithAuditToken`、`SecTaskCopySigningIdentifier/TeamIdentifier` + `socket/connect/getsockopt` → 解锁时校验校验者身份并与服务 IPC 判定。这是“锁屏/登录时可授权 CUA”的纵深集成。
- **远程投递 CUA**：`SAIRemoteHostedPIPContentHostXPCProtocol` 暴露 `publishPresentationWithID:threadID:turnID:contextID:width:height:`、`publishFrameWithPresentationID:videoData:decoderConfiguration:codec:timestamp:isKeyFrame:`、`prepareOperation…fencePayload`、`completeOperation`、`setSourceProcessIdentifier`、`noteInteraction`、`setComputerUseCursorLocationWithX:y:isActive:`；`SCStreamOutput/SCStreamDelegate`（ScreenCaptureKit）→ 屏幕以**编码视频帧 + operation fence + 光标同步**外发（Remote PIP）。
- 其他原生能力（类名证据）：`RecordAndReplayOverlayController`（录制/回放整套 UI）、`ComputerUseAudioRecorder`、`AppUsageCatalog`、`AssertionManager`、`ForegroundObserver`、`ChromeExtensionInstaller`、`CodexAppServerThreadEventObserver`。

**agentdesk**（代码事实）：
- CUA Helper.app 编译安装 + TCC 引导卡片（560×124 拖拽、自动轮询检测、自动开面板）；A/B/C 三层降级 + capabilities + guidance；`cua_verify` 前后截图证据对；幽魂光标（点击穿透、不抢焦点、不动真鼠标）；窗口级 `windowId` 精确定位。
- **v1.1.0 起补齐 Codex 的焦点模型**：坐标点击先投递 AppKitDefined/ApplicationActivated 让目标应用“以为”自己在前台，再用 `NSEvent.mouseEvent(windowNumber:)` 造带窗口归属的事件、`postToPid` 定向投递——真实前台与真实光标都不动；5 秒无动作自动反激活，`app-focus`/退出时也会收尾。v1.1.2/1.1.3 补 select_text/paste/scroll/drag、AX 滚动条、键盘真激活后恢复、ScreenCaptureKit 实时 PiP 控制指示器。
- **明确永不做**锁屏/解锁/绕过认证；无 per-app 策略；无远程投递；eval 无进程隔离。

**判定**：**Codex 大幅强**（权限纵深/锁屏/远程/系统集成）；**agentdesk 在“不越锁屏红线 + 不移动真实光标 + 前后证据”上更保守、更可解释**。

### 3.5 会话 / turn / 生命周期

| 维度 | Codex | agentdesk | 判定 |
|---|---|---|---|
| 会话模型 | app-server threads/turns；hooks（Stop/Interrupt/SubagentStop → `turn_ended`）；`CodexAppServerThreadEventObserver`；每 turn `get_app_state` | 租约（扩展权威）+ `tab_mark` + `session_finalize`（**协议/扩展已实现但服务端无生产调用方**）+ 多客户端 frontend | Codex 更完整；agentdesk 有真实的**多客户端共享** |
| 标签交接 | claimTab / openTabs / markDeliverable / markHandoff / requestUserTakeover / requestManualHandoff / nameSession / history | `tab_claim`（三重匹配防认错）+ 标签组 + 角标 + `tab_mark` | Codex 语义更细 |
| 完成信号 | `completion_summary` + 强制时机；hooks 二路 notify | 无“完成摘要”协议 | Codex |
| 会话隔离 | untrusted JS kernel + trusted worker + per-app 策略 | `browser_eval` 用 `node:vm`，自述“本地受信工具、async 段在宿主事件循环” | Codex |

### 3.6 凭据 / 登录

| 维度 | Codex | agentdesk | 判定 |
|---|---|---|---|
| 本地凭据仓 | 未见（登录靠真实 profile 会话 + `browserAuth`/SIWC 交接 + 审批策略） | macOS 钥匙串 + `ab_login`（入参只有 tabId）+ 双锁防钓鱼 + 本地 TOTP，凭据零进模型/日志/审计 | **agentdesk（独有）** |
| 登录语义 | `browserAuth` capability + SIWC（Sign-in with ChatGPT）+ 登录策略 nuance（“去 xyz.com”隐含同意登录） | origin 精确锁 + 提交后 3s 跨站 `suspicious` 判定 | Codex 更产品化；agentdesk 更“自动化” |
| 账号依赖 | 需 ChatGPT 账号 + 云端 | 无账号、纯本地 | agentdesk |

### 3.7 扩展机制：插件 / hooks / skills / code mode / 记忆

**Codex**（证据：`codex features list`、`codex-code-mode-host` 二进制字符串、`~/.codex/plugins/cache`、`AppInstructions/*.md`、`SkysightSummarizer.md`）：
- 插件：bundled（browser/chrome/computer-use/unified-computer-use/codex-app-tools/visualize）+ curated remote（app/vercel/canva/notion/openai-developers/…）；`.codex-plugin/plugin.json` 可声明 MCP servers、hooks、skills、interface（含隐私披露）。
- hooks：Stop/Interrupt/SubagentStop → `mcp_tool` 调用 `turn_ended`。
- **code mode**：`codex-code-mode-host`（Rust，V8）以 gRPC/IPC 提供 session/cell/execute/wait/terminate、工具回调、资源限制、输出截断、OTEL、audio/image content blocks → 让模型写 JS 调**任意 MCP 工具**（比 agentdesk 的 browser_eval 更通用）。
- 记忆/环境：**Skysight**（滚动事件流 + 10 分钟/6 小时摘要 + 记忆扩展 + 反 prompt-injection 的 summarizer 提示词）、**Computer History**（可 pause/clear、按 app 记录、周报）、App 级 playbooks（Notion/Slack/Clock/Numbers/Spotify/AppleMusic/iPhone Mirroring）。
- 其他 feature flags（stable true）：`multi_agent`、`in_app_browser`、`image_generation`、`memories`、`plugins`、`skill_search`、`unified_exec`、`hooks`、`guardian_approval`、`tool_call_mcp_elicitation` 等（约 60 项）。

**agentdesk**：固定 30 个 MCP 工具；无插件/hook/skill 机制；WebMCP 只是“页面级自声明工具”（这点 Codex 也有 WebMCP 且默认被 gate）。

**判定**：**Codex 大幅强**。

### 3.8 工程化 / 测试 / 安装分发

| 维度 | Codex | agentdesk |
|---|---|---|
| 产物形态 | 5 个签名 App + Rust CLI + Electron（安装体积约 1.5 GB：ChatGPT.app 742MB app.asar + 408MB codex-cli + 272MB cua_node + 65MB CUA） | npm 包（12,391 行；3 个依赖 ws/zod/mcp-sdk） |
| 更新 | Sparkle 自动更新 + 插件缓存版本化（`26.1103.60933`/`1.0.1001824`）+ 远程 curated 插件 | npm update + 重跑 setup；扩展 ID 依赖路径 |
| 可验证性 | 未在本机制品中发现可执行测试；遥测/OTEL 丰富但不可本地查询 | **158 个 test** + 伪扩展 selftest + 真 Chromium e2e + 真机 `verify` 记分卡 + doctor；源码可审计 |
| 可审计性（代码） | 闭源、大二进制、Swift/Rust 混合 | 12k 行可读源码，协议单一事实来源 |

**判定**：功能/产品化 Codex 强；**可审计/可测试/轻量 agentdesk 强**。

### 3.9 隐私 / 数据流向

| 维度 | Codex | agentdesk |
|---|---|---|
| 数据出网 | 模型/`site_status` 远端裁决/remote control websocket（`~/.codex/logs_2.sqlite` 可见 app-server remote control 连 `chatgpt.com/backend-api/`）+ 遥测 + Skysight 活动记录；插件披露文案明示“Browser data from using this plugin may be used for training” | 控制面只在 loopback；无遥测；审计本地 |
| 本地风险 | 屏幕/操作以编码帧外发、锁屏可解 | 本机 WS 无鉴权、eval 无沙箱、确认可自批（见 §5） |

**判定**：**agentdesk 数据本地性更强**；Codex 在用户同意/审批 UX 上更强。

---

## 4. Codex 比 agentdesk 强的地方（逐条，按影响排序）

1. **审批权威体系**：15 gates / 8 authorities / turn-thread-global 持久授权 / MCP elicitation / guardian auto-review / 远端 site_status 双裁决（`chrome/docs/confirmations.md`、`browser-service.mjs`、app.asar `composer.computerUseAppApproval.*`）。
2. **浏览器 API 表达力**：Playwright 34 方法 + `frameLocator`(iframe) + 剪贴板 + AX 9 动作 + 内容导出 + 页面内 CUA + 对话框对象 + 标签交接（`docs/api.json`）。
3. **屏幕动作面**：`setValue`/`selectText`/`paste(format)`/`performSecondaryAction`/音频/跨平台/AX diff（`@oai/cua` d.ts、`tinysky-alt-core-cua-repl-mac.md`）。
4. **系统级权限与锁屏集成**：多 TCC + 独立权限窗口 + per-app 策略 + URL blocklist + 锁屏 Guardian（自动解锁租约）+ AuthorizationPlugin（REA：`SAILockScreenGuardianXPCProtocol`、`CodexComputerUseMechanism`、EID `ev_078cfb45…`）。
5. **远程流式 CUA**：H.264 编码帧 + operation fence + 光标同步 + Remote PIP（REA：`SAIRemoteHostedPIPContentHostXPCProtocol`）。
6. **持久 REPL + 文档/状态注入 + 完成信号**：`js`/`js_reset`/`turn_ended`、`completion_summary`、每 turn `get_app_state`（`.mcp.json` 8KB tool override、`create_bootstrap_emitter.js`）。
7. **多 MCP server 集成 + Record&Replay + App playbooks**：Computer Use/Messages/Calendar/Computer History/Event Stream 五服务 + 录制回放 + 7 个 App 指导文档（REA：`SkyComputerUseClient` 类清单、`AppInstructions/*.md`）。
8. **插件/hooks/skills/code mode/多 agent**：`codex-code-mode-host`（V8 调任意 MCP 工具）+ 插件缓存 + hooks + `features list` 约 60 项 stable（REA：`ev_5d66e721…`、CLI `features list`）。
9. **记忆/环境感知**：Skysight 活动流摘要 + Computer History（含反 prompt-injection 的整理提示词）。
10. **浏览器会话语义**：claim/handoff/deliverable、session naming、history、四后端（extension/iab/dot/mcpapps/cdp）与云浏览器。
11. **工程化**：签名/公证/硬运行时/自动更新/本地化/Sparkle。
12. **信任边界隔离**：untrusted kernel ↔ trusted worker + IPC ancestor 校验 + native host 代码签名对端校验（`SecTask*` + `2DC432GLL2`）。
13. **审批策略可配置**：`~/.codex/browser/config.toml` 的 `full_cdp_access_enabled`/`approval_mode`/`history_approval_mode`（本机设置）证明其策略面可调。
14. **文件上传/下载/剪贴板**：Codex 有完整通道；agentdesk 上传无、下载工具因 manifest 缺 `downloads.open` 实际不可用。
15. **视觉与引导**：4MB brotli AX wasm、Lens 45 帧动效、虚拟光标/Fog、permission window。

---

## 5. agentdesk 仍占优的地方（逐条）

1. **凭据仓**：钥匙串 + 双锁 + 本地 TOTP，凭据零进模型/日志/审计（Codex 无对应物）— `service/login.mjs`、`service/credentials.mjs`、`service/totp.mjs`。
2. **动作级本地审计**：JSONL + 脱敏 + `ab_audit` 可查（Codex 遥测不可本地查）— `service/audit.mjs`、`service/mcp.mjs`。
3. **`cua_verify` 前后证据对**：防“声称点了其实没点” — `service/cua.mjs`。
4. **幽魂光标 + 合成激活定向点击**：叠加窗点击穿透、不抢焦点；v1.1.0 起坐标点击也不再移动真实光标/抢真实前台（目标应用被合成激活，事件带窗口归属定向投递）；可 `cuaOverlay:false` 关、不入审计 — `swift/cua-helper.swift`。
5. **A/B/C 显式降级 + capabilities + guidance**：Codex 无“能力层级”概念 — `service/cua.mjs`。
6. **纯本地/零云/无账号**；控制面 loopback。
7. **批量隐形读页** `ab_read_urls` + **实时投屏** `ab_screencast`（Codex `Tabs.content` 在 4 后端默认禁用，无投屏工具）。
8. **多客户端 frontend 共享 + 端口接管自愈** — `service/mcp-entry.mjs`、`service/remote-frontend.mjs`。
9. **轻量安装**：npm + 12,391 行 vs Codex 约 1.5 GB 多进程常驻。
10. **源码可审计 + 158 测试 + 伪扩展自检 + 真 Chromium e2e + 真机 verify**。
11. **WebMCP 发现/调用/推送**（`webmcpHint` + notifications/message）— 与 Codex 同有 WebMCP，但 agentdesk 默认更直接。
12. **macOS 窗口级 CUA**（`windowId` 精确截窗）— Codex mac 侧 `listWindows` 仅 Linux/Win。

---

## 6. 给 agentdesk 的建议（借鉴优先级）

### P0 —— 安全语义补齐（否则“本地可审计”的宣传不成立）

1. **把确认做成真正的人类回路**：`ab_confirm` 改为 MCP elicitation/客户端 UI 回调（Codex 的 `tool_call_mcp_elicitation` 思路），token 绑定具体动作+参数摘要，禁止模型自批。
2. **策略门覆盖 `browser_eval`**：`tab._cmd` / `tab.eval` / `tabs.new({url})` 必须过 gate；审计补 `tab_eval`、`tab_ax_action`。
3. **本机 WS 鉴权**：token + 对端进程校验（peer pid/代码签名），防本机其他进程冒充 frontend 读 Cookie。
4. **接线 `session_finalize`**：turn/会话结束时 finalize、关 agent 页、清角标，避免陈旧租约阻塞 claim。

### P1 —— 浏览器能力补课（按性价比）

- iframe/frameLocator（当前定位器最大硬伤）
- 剪贴板读/写
- 暴露 `tab_ax_action`（扩展已有，service 未暴露）
- 下载权限修复（`downloads.open` 声明）与上传通道
- 标签交接语义（`requestUserTakeover` 风格）+ 会话命名/历史

### P2 —— 工具面语义升级（保留粗粒度 MCP 工具的形态下借鉴）

- 增加“每 turn 一次状态”纪律与 **AX diff**（省 token）
- REPL 的**文档/状态注入**与 **completion_summary** 式完成信号
- 保持并强化 `cua_verify` 证据对作为差异化（Codex 没有）

### P3 —— 审批策略可配置 + 审批事件入审计

- 引入风险分类（删除/对外发送/装软件/金融/敏感数据）与档位（pre-approve/action-time/handoff），即使默认保守。

### 不建议照搬（红线/成本）

- **锁屏自动解锁 + AuthorizationPlugin**：能力最强但安全/审核风险最高，且与 agentdesk“绝不碰锁屏”的定位冲突。
- **云 site_status 裁决 / 遥测 / Skysight 全时活动录制**：隐私与合规代价。
- **742MB Electron + 多常驻进程 + 多 MCP server**：与 agentdesk 轻量定位相悖。

---

## 7. 局限与未解问题

1. **无法反编译**：本机无 Ghidra/Hopper，Swift/Rust 函数体未还原；XPC/图形/加密等行为均为协议与命名推断。
2. **（第二轮已解决）Codex Chrome 扩展本体**已从本机 Chrome profile 提取并分析（v1.26.1102.11740，`.codex-analysis/04-chrome-extension.md`）；仍未知的是 HTTPS tunnel 后端 URL/轮询体与 host 二进制完整方法表。
3. **browser-service.mjs 只采样约 5%**（1.6MB 打包产物），gate 判定的具体实现细节未逐行走读。
4. 用户 `~/.codex/browser/config.toml` 与 `~/.codex/config.toml` 是**个人配置**（含 approval_mode=never_ask 等），不能当作 Codex 默认值。
5. `SkyComputerUseClient` 同时承担 5 个 MCP server，但旧 `computer-use` MCP 与 `cua_repl` 的**路由/双开条件**未完全确认。
6. Codex 是否自带可执行测试、Codex CLI 0.167 与 npm 0.118 的行为差异、Remote PIP 的具体编解码/加密，均未解。

---

## 附录 A：七份原始审计（证据台账）

| 文件 | 内容 | 规模 |
|---|---|---|
| `.codex-analysis/01-browser-channel.md` | Codex 浏览器通道（API 全量、4 后端、审批 gate、机制拆解、41 维对比） | 977 行 |
| `.codex-analysis/02-cua-channel.md` | Codex CUA 通道（cua API、3 工具/REPL/注入机制、权限/审批/锁屏、19 维对比、15 条未知） | 587 行 |
| `.codex-analysis/03-agentdesk-inventory.md` | agentdesk 全仓事实基准（13 章、388 行表格、20 条 README vs 代码不一致） | 719 行 |
| `.codex-analysis/04-chrome-extension.md` | 已安装 Codex Chrome 扩展逆向（两套 MCP 端点、js-kernel 三层沙箱、DNR 策略、审批外置） | 514 行 |
| `.codex-analysis/05-appserver-approval.md` | app-server 审批/elicitation 协议（11 类 server→client 请求、决策枚举、userVerification、UI 映射） | 673 行 |
| `.codex-analysis/06-browser-gates.md` | browser-service 16 闸门/8 authority/11 类审批形状/TOML 持久化/site_status | 666 行 |
| `.codex-analysis/07-cua-approval.md` | CUA 五层审批、per-app 授权、Messages 读写分离、落盘文件、风险档、123 条设置文案 | 1117 行 |

## 附录 B：REA 证据 ID 索引（本报告引用的主要证据）

| 主题 | Evidence ID |
|---|---|
| `SkyComputerUseService` Mach-O 摘要 | `ev_35ad87520c77bb822e349027546e00bbcdcfda3297d7bcf11670e6d8d7dc186d` |
| `SkyComputerUseService` 签名/entitlements | `ev_2596a4ac7a296cedfe31fd9f54ec1103993a17621adb8e8b79d6d3ecc3a0f709` |
| `SkyComputerUseService` ObjC/Swift 分发元数据 | `ev_abf9e34f1907d2fbfa64ebd838df62db8ad0db6c605d5d5e5e7873963b366f18` |
| `Codex Computer Use.app` Info.plist | `ev_fd1b7a0b312673703c164b098c9352d77a7fbfbac11191c89c556774e689b92f` |
| App bundle 清单 | `ev_583a176da8d3ca105fed3676cb9afe4dd5dd126fa0c30a3e88ec895ad02cba09` |
| `CUALockScreenGuardian` Mach-O / 分发元数据 | `ev_7c4c1f5e0d68c30a9920fd5b9649feb3860d37f4951797502f43c92282a94245` / `ev_b48700f4d86e52e3a1a28c96cb90818f82420d8f7c000a47f9bfb74bc1ebd9a8` |
| AuthorizationPlugin Mach-O / imports / 签名 | `ev_078cfb45c583b870d1cdc73c948fddc1e43f89223fe6701f93670bb58ba676b9` / `ev_cc9309f33310afa0107d2810c79c190e9679bfb3a2cc1ce5a0c3fbab21265d1f` / `ev_3473fc035924f64353e9e50f3dfd7e1a1cfb6a9cc4f37658c3c6ad8a0fe44c7e` |
| `SkyComputerUseClient` Mach-O / 分发元数据 | `ev_70c2a169bdd442caf78aaf890b16c09442c52f0d98f007b31c5cc320a5dc61d8` / `ev_e6df9ddaf8a850e6459f1dfe723b0f4875aec6602560cc1c2c2fad127bc58bd2` |
| Chrome native host Mach-O | `ev_8d6b018c4419bbd8bf6fcd9eb54c1456901d076bdb12b3a6d7887db6a086eb01` |
| ChatGPT.app（Electron 候选） | `ev_1558763dd562967b344fd61f37cddfd4dfe9d9164b09ae66699251fa6c941c0d` |
| `codex-exec-server` Rust 元数据（无 auditable section） | `ev_5d66e7217e41bf34b372edf6b5dc80ed5c6efa0fc4f52fcdb072c7178a35dfcf` |

| app.asar 抽取的审批 UI/回传模块（webview） | REA JS 分析：parent `ev_6f8c0ae0ff3e59041eea1cb92454daa23a2405566aa09b547fd828c2fa23e795`、view `ev_d95e095ce81065f75a9390d60343548e4b231d56b7f196bdfe173a5b769be565` |
| app-server 协议生成物 | `codex app-server generate-json-schema`（`.codex-analysis/appserver-schema/`，47 文件）与 `generate-ts`（`.codex-analysis/appserver-ts/`、`appserver-ts-experimental/`）；证据为生成命令+文件内容，非 REA 记录 |
| 审批协议/闸门/CUA 审批台账 | `.codex-analysis/05-appserver-approval.md`、`06-browser-gates.md`、`07-cua-approval.md` |

## 附录 C：本机 Codex 版本速查

- ChatGPT Desktop `26.1103.60933`；Codex CLI（内置）`0.167.0-alpha.3.2`；npm 全局 `@openai/codex 0.118.0`
- Chrome 插件 `26.1103.60933`（browser-service 1.6MB；extension IDs：`hehggadaopoacecdllhhajmbjkdcmajg`(Chrome)、`odlomjlbamekndcpllcnffbgeohgkmjh`(Edge)）
- Codex Computer Use `26.1102.1001824`（service/guardian/client/installer/authorization plugin 五件套）
- `@oai/cua 0.2.6`、`@oai/cua-repl 0.1.3`、`@oai/sky 0.7.17`、`@oai/browser-desktop 0.1.1`
