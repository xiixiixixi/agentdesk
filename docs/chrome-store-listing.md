# Chrome Web Store 上架材料（AgentDesk 浏览器扩展 v1.0.1）

> 打包产物：`/tmp/agentdesk-release-1.0.1/agentdesk-extension-1.0.1.zip`（由 `extension/` 打包，已排除 `runtime-config.json` 里的本机 token）
> 上架前需要：注册 Chrome 开发者账号（一次性 $5）→ 新建条目 → 上传 zip → 填下表 → 提交审核。

## 基本信息

| 字段 | 建议填写 |
|---|---|
| 名称 | AgentDesk |
| 简短描述（132 字符内） | 让任意 MCP AI 客户端操控你真实登录态的 Chrome；纯本地、可审计、无需云账号 |
| 类别 | 生产工具（Productivity） / 开发者工具 |
| 语言 | 中文（简体）+ English |
| 图标 | 128px 已在包内（`icons/icon128.png`） |

## 详细描述（可直接粘贴）

```
AgentDesk 的浏览器扩展，配合本机 AgentDesk 服务（https://github.com/xiixiixi/agentdesk 开源）
让支持 MCP 协议的 AI 客户端（Codex / Cursor / Claude Code / ZCode 等）操控你自己的 Chrome：
- 使用你当前浏览器的真实登录态，无需重新登录、无需迁移 Cookie
- 支持 30 个 MCP 工具：标签/导航/截图/无障碍树/CDP/批量读页/实时投屏/网页工具(WebMCP)
- 全部指令只在本机 127.0.0.1 流动，不出网、无云端、无遥测
- 多浏览器互斥：同一时刻只有你选中的那个浏览器受控
- 所有动作写入本地审计日志（可在 AI 会话中查询）

安装：先在本机安装 agentdesk（npm i -g agentdesk）并运行 `agentdesk`，再安装本扩展。
```

## 权限用途说明（审核会逐项看）

| 权限 | 用途 |
|---|---|
| `debugger` | 通过 CDP 执行页面操作/截图/无障碍树（核心能力） |
| `tabs` / `tabGroups` | 创建/管理 AI 使用的标签页、可见标签组 |
| `scripting` | 注入定位器与页面状态读取脚本 |
| `nativeMessaging` | （兼容旧安装）连接本机 AgentDesk 宿主程序 |
| `storage` / `alarms` | 保存租约状态、断线重连 |
| `bookmarks` / `history` / `downloads` | 只读查询与下载动作（经策略门确认） |
| `host_permissions <all_urls>` | 用户明确要求 AI 操作的站点；所有动作经本地策略门 |

## 隐私与数据

- 扩展不收集、不上传任何用户数据；无遥测。
- 所有请求只发往本机 `ws://127.0.0.1:<port>`（本地 AgentDesk 服务）。
- 页面内容仅在用户发起的 AI 任务中读取，结果留在本机审计日志。
- 隐私政策 URL：使用仓库 README 的“纯本地架构”段落即可（上架时需填一个可公开访问的 URL）。

## 截图清单（1280×800，至少 1 张）

1. 扩展弹窗：“受控中/待机”开关截图
2. AI 会话里让它打开网页并截图的对话截图
3. 多浏览器互斥提示（Chrome 受控、另一浏览器待机）

## 审核备注

- 本扩展只是“本地服务的执行体”，不注册任何远程服务器；请在测试说明里附：
  `npm i -g agentdesk && agentdesk`，然后 Chrome 加载本扩展并运行 `npm run doctor`。
- 若审核环境无法运行本机 Node 服务，可注明“扩展单独安装后处于未连接状态，属预期”。
