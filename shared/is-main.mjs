// shared/is-main.mjs — 统一的「作为脚本直接运行」入口守护
//
//   import { isMain } from '../shared/is-main.mjs';
//   if (isMain(import.meta.url)) main();
//
// 背景：npm 全局 bin（如 agentdesk-mcp）是指向入口文件的符号链接，shebang 启动时
// process.argv[1] 是符号链接路径，而 ESM 的 import.meta.url 解析为真实路径——
// 守护若直接比较两者则永不相等 → main() 不执行、进程静默退出 0
// （v1.1.1 修过 mcp-entry.mjs 一处，v1.1.2 起所有入口统一走本助手）。
// 被 import 时必须返回 false（这是守护存在的意义：测试与跨模块复用不触发 CLI）。

import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function isMain(importMetaUrl) {
  if (!process.argv[1]) return false; // node -e / REPL / 被测试运行器 import 等
  let real;
  try {
    real = realpathSync(process.argv[1]); // 符号链接 → 真实路径（含相对路径的 cwd 解析）
  } catch {
    return false; // argv[1] 在盘上不存在（竞态删除等）——保守不执行
  }
  return pathToFileURL(real).href === importMetaUrl;
}
