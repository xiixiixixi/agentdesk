// swift/cua-helper.swift — 屏幕操作助手（单文件 Swift，行协议 JSON 服务）
//
// 由 setup.mjs / cua-selftest.mjs 用 swiftc 编译为 host/cua-helper（编译产物不入库）。
// 协议：stdin 每行一个 JSON 请求 {id, cmd, ...参数}；stdout 每行一个 JSON 响应
//   成功 {id, ok:true, ...数据} / 失败 {id, ok:false, error:"...", code?:"..."}。
// 除本协议外不向 stdout 写任何内容；诊断信息一律 stderr。
//
// 命令集（与 service/cua.mjs 的调用侧一一对应）：
//   probe                              → {axGranted, screenGranted}（AXIsProcessTrusted / CGPreflightScreenCaptureAccess）
//                                        附 responsibleProcess（TCC 记账的宿主 App 名——用户在系统设置
//                                        里要勾选的就是这个名字）。v1.0.0：从 AgentDesk.app 内运行时
//                                        权限挂在本 .app 上（helperBundle 回传 id/name/path，终端是谁
//                                        不再重要）；裸 CLI 运行时沿 ppid 链推断宿主（通常为终端）。
//   request-permissions                → 向系统申请辅助功能与屏幕录制权限（各自仅在缺失时申请）：
//                                        AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt=true)
//                                        弹标准对话框并把负责进程加进辅助功能列表（未勾选）；
//                                        CGRequestScreenCaptureAccess() 同理注册屏幕录制。
//                                        两者立即返回（不阻塞等用户操作），静置 ~500ms 让弹窗出现后
//                                        即报 {axGranted, axRequested, screenGranted, screenRequested,
//                                        responsibleProcess}。用户在系统设置勾选后经 probe 复测生效。
//   windows                            → {windows:[{windowId, ownerPid, ownerName, title, bounds:{x,y,w,h}, onScreen}]}
//   ax-tree {pid, maxDepth?}           → {nodes:[{depth, role, title?, value?, bounds?, actions?}], truncated}
//                                        遍历限额：深度 12 / 每层 80 / 总 1500 节点；文本截断 120 字符。
//                                        AX 未授权 → {ok:false, code:"not-granted"}（结构化，不崩溃）。
//   element-click {pid, role, title?}  → 先 AXUIElement PerformAction(press)；失败兜底取元素 bounds
//                                        中心做坐标点击 → {pressed} | {xyFallback, bounds, at}
//   set-value {pid, role, title?, value} → AXUIElementSetAttributeValue(kAXValue)，回读校验；
//                                        不可写 → value-not-settable（不移动鼠标/不抢焦点）
//   perform-action {pid, role, title?, action} → AXUIElementPerformAction；校验动作在 AXActionNames 中，
//                                        大小写不敏感匹配；不支持 → action-not-available + 可用动作列表
//   select-text {pid, role, title?, text, prefix?, suffix?, selection?} → 在 AXValue 文本里定位并设置
//                                        AXSelectedTextRange（text/cursor_before/cursor_after），回读校验
//   paste {pid, text, format?}         → 写入剪贴板（text/md/html）+ 定向 ⌘V，完成后恢复原剪贴板
//   scroll {pid, x?, y?, role?, title?, direction?, pages?, scrollX?, scrollY?} → 定向滚轮事件
//   drag {pid, fromX, fromY, toX, toY, steps?, durationMs?} → 定向按下/拖动/释放
//   PiP-lite（常驻控制指示器）          → 动作期间在目标窗口右上角显示「AgentDesk 正在操作」+ 实时缩略图；
//                                        非激活面板、点击穿透，合成激活结束/5s 无动作自动收起
//   xy-click {x, y, pid?}              → v1.1.0：有 pid 且能定位目标窗口时走「合成激活 + 定向投递」：
//                                        先向 pid 投递 AppKitDefined/ApplicationActivated（目标“以为”自己是
//                                        前台，真实前台不变），再用 NSEvent.mouseEvent(windowNumber: 目标窗口)
//                                        造 down/up、取 cgEvent、补窗口关联字段后 postToPid——事件落到目标
//                                        窗口，真实光标不动、不抢前台。同一应用内非 key 窗口会先 AX 设为
//                                        应用内 main（只动应用内部窗口序）。无 pid → 全局注入（会移动真实
//                                        光标，回 fallback:"global"）；给 pid 但点击点无目标窗口 → 报错不盲点。
//   type {pid?, text}                  → 键盘事件逐段输入：CGEventKeyboardSetUnicodeString 直塞 UTF-16 文本
//                                        （中文等无键码字符的唯一可靠路径），按 UTF-16 码元分段（≤20/事件，
//                                        规避单事件长度上限——一个 emoji 常占多个码元，按字符合段会超限）。
//                                        给 pid 时先确保目标“以为”自己是前台（合成激活），否则 keyWindow
//                                        可能为空、输入无处可去。
//   key {pid?, key, modifiers?}        → modifiers: cmd/ctrl/alt/shift；key 用键码映射表。v0.5.5 起修饰键按
//                                        真实按键序列注入：flagsChange(按下修饰键) → keyDown(带 flag) → keyUp
//                                        → flagsChange(释放)，事件间 5ms 间隔，配合 hidSystemState 事件源，
//                                        ⌘S/⌘N 等组合键才能稳定触发系统对话框。给 pid 时同样先合成激活。
//   app-focus {pid}                    → 先撤销合成激活，再 AX raise 主窗口 + NSRunningApplication activate
//   release-focus                      → 立即撤销合成激活（幂等）；最后一次动作后 5s 也会自动撤销
//   overlay-show {x, y, kind:'arrow'|'click', durationMs?(默认700)} → {ok:true}
//                                       幽魂光标：在 (x,y) 闪现琥珀色 AI 专属箭头（kind=click
//                                       追加约 350ms 扩散涟漪），durationMs 后淡出。叠加窗点击
//                                       穿透、不抢焦点、真鼠标不动；窗口懒创建并复用。
//   overlay-hide                       → 立即隐藏叠加 → {ok:true}
//   show-permission-card {kind:'accessibility'|'screen', appName, durationSec?(默认120,夹取5..600)}
//                                       → {kind, autoHideSec, frame:{x,y,w,h}(屏幕左上原点), dragFrom?}
//                                       权限引导悬浮卡片（v0.5.4 起；v1.0.0 全面升级）：
//                                       NSPanel(borderless/nonactivating/floating/canJoinAllSpaces)。
//                                       本项目唯一「可交互」的叠加窗（ignoresMouseEvents=false，
//                                       但它就是给用户看的引导 UI；仍不抢焦点）。
//                                       v1.0.0 形态（560×124）：
//                                       ① 左侧 72px 琥珀大图标=拖拽句柄——从 AgentDesk.app 内运行时
//                                          拖出的就是本 .app 本体（TCC 记账、设置列表要加的正是它）；
//                                          裸 CLI 运行时退化为拖负责进程（终端）的 .app；
//                                       ② 贴靠跟随：150ms 轮询 CGWindowListCopyWindowInfo 找系统设置
//                                          窗口（pid → bundleIdentifier == com.apple.systempreferences
//                                          取面积最大者），卡片水平居中于它、贴其下沿上叠 6px，
//                                          设置窗移动卡片跟随；用户拖动卡片/图标拖拽期间冻结跟随；
//                                       ③ 授权自动检测：1.2s 轮询 AXIsProcessTrusted（不带 prompt）/
//                                          CGPreflightScreenCaptureAccess，对应权限生效即自动隐藏该卡；
//                                          卡片全数收起且 stdin 已 EOF 时进程自退（下次请求由服务端
//                                          从 .app 位置重启新实例=自动重读 TCC grant）；
//                                       ④ 右上 ✕ 关闭；durationSec 秒后自动淡出；accessibility 在上、
//                                          screen 在下错位排布，两卡不重叠。
//   hide-permission-card {kind}        → 立即隐藏对应卡片（幂等，未显示的 kind 也回 ok）
//
// 线程模型（v0.5.1 起）：主线程跑 NSApplication run loop（叠加窗口需要 AppKit）；
// stdin 移到后台队列逐行读，命令解析与执行留在读取线程（与旧版单线程行为一致），
// 仅 overlay/permission-card 的窗口操作经 DispatchQueue.main.async 切主线程执行后应答；
// stdin EOF → 主线程 NSApp.terminate 退出（保持旧行为：进程随 stdin 关闭而退出）；
// 例外（v0.5.4）：权限引导卡片还在屏上时留守，待卡片全数收起（淡出/隐藏/关闭）后再退
// （setup 非交互模式把卡片留给用户看、脚本自身先退出；卡片寿命最长 durationSec 秒封顶）。
//
// 安全边界：本助手不做任何锁屏/解锁/认证类操作；只执行调用方显式给出的动作。
// 幽灵光标叠加窗点击穿透（不可交互）；权限引导卡片是唯一的例外——可交互但不抢焦点
// （nonactivating panel）：它就是引导用户完成系统授权的 UI，不碰任何其他应用。

import Cocoa
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

// ---------- 响应输出（唯一 stdout 出口） ----------

func respond(_ id: Any?, _ payload: [String: Any]) {
    var out = payload
    out["id"] = id ?? -1
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

func respondOk(_ id: Any?, _ data: [String: Any]) { respond(id, ["ok": true].merging(data) { _, new in new }) }

func respondErr(_ id: Any?, _ error: String, code: String? = nil) {
    var p: [String: Any] = ["ok": false, "error": error]
    if let c = code { p["code"] = c }
    respond(id, p)
}

// ---------- 通用小工具 ----------

let textLimit = 120

func truncStr(_ s: String) -> String { s.count <= textLimit ? s : String(s.prefix(textLimit)) + "…" }

/** 读 AX 属性，失败返回 nil（AX 调用里「读不到」是常态，不视为错误）。 */
func axAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
    return v
}

/** AXValue(CGPoint/CGSize) → [Double]；非对应类型返回 nil。 */
func axPointOrSize(_ v: CFTypeRef?) -> [Double]? {
    guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    let axv = v as! AXValue // 类型已核对，强转安全
    var point = CGPoint()
    if AXValueGetValue(axv, .cgPoint, &point) { return [point.x, point.y] }
    var size = CGSize()
    if AXValueGetValue(axv, .cgSize, &size) { return [size.width, size.height] }
    return nil
}

func axTrusted() -> Bool { AXIsProcessTrusted() }

let AX_NOT_GRANTED_HINT = "辅助功能（AX）未授权：系统设置 → 隐私与安全性 → 辅助功能，勾选运行本助手的终端/应用后重试"

// ---------- probe ----------

func cmdProbe(_ id: Any?, _ p: [String: Any]) {
    var out: [String: Any] = ["axGranted": axTrusted(), "screenGranted": CGPreflightScreenCaptureAccess(),
                              "responsibleProcess": responsibleProcessName()]
    // v1.0.0：从 .app 内运行 → 权限主体就是本 .app（服务端据此切换为「拖 .app 授权」引导）
    if let bid = Bundle.main.bundleIdentifier {
        out["helperBundle"] = [
            "id": bid,
            "name": (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "AgentDesk",
            "path": Bundle.main.bundleURL.path,
        ] as [String: Any]
    }
    let b = CGDisplayBounds(CGMainDisplayID()) // 主屏尺寸（自检把幽魂光标定位到屏幕中央用）
    out["screen"] = ["w": b.width, "h": b.height]
    respondOk(id, out)
}

// ---------- request-permissions（v0.5.3：标准 macOS 权限申请——申请，而不只是检查） ----------

/** 父 pid（sysctl kinfo_proc；失败返回 -1）。 */
func parentPid(_ pid: pid_t) -> pid_t {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    return info.kp_eproc.e_ppid
}

/**
 * 负责进程名（TCC 记账的宿主 App——申请权限时系统弹窗与设置列表里显示的就是它）。
 * v1.0.0 双模式：从 AgentDesk.app 内运行（Bundle.main 带 bundleIdentifier）→ 就是本 .app；
 * 裸 CLI 运行 → 沿 ppid 链向上找最近的真 App 进程（NSRunningApplication 非 nil 且带
 * bundleIdentifier 的才算——主线程的 NSApplication 会把本 CLI 进程也注册成「app」，
 * 但无 bundle，借此排除）；找不到回退本进程名。
 */
func responsibleProcessName() -> String {
    if Bundle.main.bundleIdentifier != nil { // 本进程已是个 .app：权限挂在自己身上
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "AgentDesk"
    }
    var pid = parentPid(getpid()) // 从父进程起步，跳过被 NSApplication 自注册的本进程
    for _ in 0..<16 { // 链深兜底，防异常成环
        if pid <= 1 { break }
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        let ppid = parentPid(pid)
        if ppid <= 0 { break }
        pid = ppid
    }
    return ProcessInfo.processInfo.processName
}

/**
 * 向系统申请辅助功能与屏幕录制（各自仅在缺失时申请，已授权的不重复弹窗）。
 * 两个 API 都把「负责进程」（调用链上的宿主 App，通常是终端）注册进对应列表（未勾选状态），
 * 并立即返回；静置 ~500ms 让系统对话框出现后即报状态，不阻塞等用户操作。
 */
func cmdRequestPermissions(_ id: Any?, _ p: [String: Any]) {
    var axGranted = axTrusted()
    var axRequested = false
    if !axGranted {
        // kAXTrustedCheckOptionPrompt 在 Swift 里是 Unmanaged<CFString>，取值后作字典键
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axGranted = AXIsProcessTrustedWithOptions(opts)
        axRequested = !axGranted // 已向系统申请（弹窗+注册未勾选项），等用户去设置里勾选
    }
    var screenGranted = CGPreflightScreenCaptureAccess()
    var screenRequested = false
    if !screenGranted {
        screenGranted = CGRequestScreenCaptureAccess()
        screenRequested = !screenGranted
    }
    usleep(500_000) // 给系统 ~500ms 弹出对话框，随后立即返回
    respondOk(id, [
        "axGranted": axGranted,
        "axRequested": axRequested,
        "screenGranted": screenGranted,
        "screenRequested": screenRequested,
        "responsibleProcess": responsibleProcessName(),
    ])
}

// ---------- windows（CGWindowList：窗口清单本身无需授权；窗口标题需屏幕录制授权才可见） ----------

func cmdWindows(_ id: Any?, _ p: [String: Any]) {
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else {
        respondErr(id, "CGWindowListCopyWindowInfo returned nothing")
        return
    }
    var out: [[String: Any]] = []
    for w in list {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
        // 只报常规层（layer 0）的真实进程窗口，排除菜单条/Dock/悬浮层等系统装饰
        if layer != 0 || pid <= 0 { continue }
        var b: [String: Any] = [:]
        if let bounds = w[kCGWindowBounds as String] as? [String: Any] {
            b = [
                "x": (bounds["X"] as? Double) ?? Double((bounds["X"] as? Int) ?? 0),
                "y": (bounds["Y"] as? Double) ?? Double((bounds["Y"] as? Int) ?? 0),
                "w": (bounds["Width"] as? Double) ?? Double((bounds["Width"] as? Int) ?? 0),
                "h": (bounds["Height"] as? Double) ?? Double((bounds["Height"] as? Int) ?? 0),
            ]
        }
        out.append([
            "windowId": (w[kCGWindowNumber as String] as? Int) ?? 0,
            "ownerPid": pid,
            "ownerName": (w[kCGWindowOwnerName as String] as? String) ?? "",
            "title": (w[kCGWindowName as String] as? String) ?? "", // 无屏幕录制授权时系统不给标题 → 空串
            "bounds": b,
            "onScreen": (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
        ])
        if out.count >= 200 { break }
    }
    respondOk(id, ["windows": out])
}

// ---------- ax-tree（AXUIElement 遍历，限额见文件头） ----------

func axNode(_ el: AXUIElement, _ depth: Int) -> [String: Any] {
    var node: [String: Any] = ["depth": depth]
    if let role = axAttr(el, kAXRoleAttribute) as? String { node["role"] = truncStr(role) }
    if let title = axAttr(el, kAXTitleAttribute) as? String { node["title"] = truncStr(title) }
    // 描述属性：Finder 侧栏图标等不带标题的元素，标签语义在 AXDescription（2026-10 真机发现）
    if let desc = axAttr(el, kAXDescriptionAttribute) as? String { node["desc"] = truncStr(desc) }
    if let value = axAttr(el, kAXValueAttribute) {
        if let s = (value as? String), !s.isEmpty { node["value"] = truncStr(s) }
        else if let n = value as? NSNumber { node["value"] = n.doubleValue }
    }
    if let pos = axPointOrSize(axAttr(el, kAXPositionAttribute)),
       let size = axPointOrSize(axAttr(el, kAXSizeAttribute)) {
        node["bounds"] = ["x": pos[0], "y": pos[1], "w": size[0], "h": size[1]]
    }
    var names: CFArray?
    if AXUIElementCopyActionNames(el, &names) == .success, let arr = names {
        let acts = (arr as [AnyObject]).compactMap { $0 as? String }
        if !acts.isEmpty { node["actions"] = acts }
    }
    return node
}

/// 深度优先遍历；返回节点数。限额：maxDepth(≤12)、每层 80 子节点、总 1500。
func axWalk(_ el: AXUIElement, _ depth: Int, _ maxDepth: Int, _ out: inout [[String: Any]], _ budget: inout Int) {
    if budget <= 0 || depth > maxDepth { return }
    out.append(axNode(el, depth))
    budget -= 1
    guard let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
    var n = 0
    for kid in kids {
        if n >= 80 || budget <= 0 { break }
        axWalk(kid, depth + 1, maxDepth, &out, &budget)
        n += 1
    }
}

func cmdAxTree(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let pid = p["pid"] as? Int, pid > 0 else {
        respondErr(id, "ax-tree 需要 pid（正整数）")
        return
    }
    let maxDepth = min((p["maxDepth"] as? Int) ?? 12, 12)
    let app = AXUIElementCreateApplication(pid_t(pid))
    var nodes: [[String: Any]] = []
    var budget = 1500
    axWalk(app, 0, maxDepth, &nodes, &budget)
    respondOk(id, ["nodes": nodes, "truncated": budget <= 0])
}

/** 只读诊断：返回屏幕坐标下的 AX 元素与可用动作（滚动/点击排障用）。 */
func cmdAxHit(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else {
        respondErr(id, "ax-hit 需要 x/y", code: "bad-args")
        return
    }
    let sys = AXUIElementCreateSystemWide()
    var ref: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &ref)
    guard err == .success, let el = ref else {
        respondErr(id, "该点没有 AX 元素（AXError \(err.rawValue)）", code: "no-element")
        return
    }
    var chain: [[String: Any]] = []
    var cur = el
    for _ in 0..<8 {
        var namesRef: CFArray?
        let actions = (AXUIElementCopyActionNames(cur, &namesRef) == .success ? (namesRef as? [String]) : nil) ?? []
        chain.append([
            "role": axAttr(cur, kAXRoleAttribute) as? String ?? "",
            "title": axAttr(cur, kAXTitleAttribute) as? String ?? "",
            "actions": actions,
        ])
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parentRef) == .success,
              let p = parentRef else { break }
        cur = unsafeBitCast(p, to: AXUIElement.self)
    }
    respondOk(id, ["chain": chain])
}

// ---------- element-click（AX press 优先，元素 bounds 中心坐标兜底） ----------

/// 深度优先找 role（精确）+ title（给 title 时精确，否则第一个同 role）匹配的元素。
/// title 匹配语义是「可读标签」：AXTitle 命不中时依次核对 AXDescription（Finder 侧栏图标）
/// 与 AXValue 字符串（Finder 侧栏行的 AXStaticText 标签在 value，2026-10 真机发现）。
func axFind(_ el: AXUIElement, _ depth: Int, _ role: String, _ title: String?) -> AXUIElement? {
    if depth > 12 { return nil }
    if let r = axAttr(el, kAXRoleAttribute) as? String, r == role {
        if let want = title {
            if let t = axAttr(el, kAXTitleAttribute) as? String, t == want { return el }
            if let d = axAttr(el, kAXDescriptionAttribute) as? String, d == want { return el }
            if let v = axAttr(el, kAXValueAttribute) as? String, v == want { return el }
        } else { return el }
    }
    guard let kids = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    var n = 0
    for kid in kids {
        if n >= 80 { break }
        if let hit = axFind(kid, depth + 1, role, title) { return hit }
        n += 1
    }
    return nil
}

func cmdElementClick(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let pid = p["pid"] as? Int, pid > 0, let role = p["role"] as? String, !role.isEmpty else {
        respondErr(id, "element-click 需要 pid 与 role（title 可选）")
        return
    }
    let wantTitle = p["title"] as? String
    let title = (wantTitle?.isEmpty ?? true) ? nil : wantTitle
    let app = AXUIElementCreateApplication(pid_t(pid))
    guard let el = axFind(app, 0, role, title) else {
        respondErr(id, "未找到匹配元素 role=\(role) title=\(title ?? "")（先用 ax-tree 核对元素的真实 role/title）", code: "element-not-found")
        return
    }
    // 路径 A：元素自己的 AXPress 动作
    if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
        respondOk(id, ["pressed": true])
        return
    }
    // 路径 B：取元素 bounds 中心做坐标点击（v1.1.0：合成激活 + 定向投递；找不到目标窗口才全局兜底）
    guard let pos = axPointOrSize(axAttr(el, kAXPositionAttribute)),
          let size = axPointOrSize(axAttr(el, kAXSizeAttribute)), size[0] > 0, size[1] > 0 else {
        respondErr(id, "元素无 bounds，无法坐标兜底", code: "no-bounds")
        return
    }
    let cx = pos[0] + size[0] / 2
    let cy = pos[1] + size[1] / 2
    let d = postClick(pid, cx, cy)
    if d.noWindow {
        respondErr(id, "元素 bounds 处没有目标窗口（可能在别的桌面/已最小化）；未执行坐标兜底，避免误点前台应用", code: "no-window-at-point")
        return
    }
    if d.eventBuildFailed {
        respondErr(id, "无法构造定向鼠标事件；未执行坐标兜底（避免全局盲点）", code: "click-event-failed")
        return
    }
    var out: [String: Any] = ["xyFallback": true, "bounds": ["x": pos[0], "y": pos[1], "w": size[0], "h": size[1]], "at": [cx, cy]]
    if d.targeted { out["targeted"] = true }
    if d.syntheticFocus { out["syntheticFocus"] = true }
    if d.fallbackGlobal { out["fallback"] = "global" }
    if let wid = d.windowId { out["windowId"] = wid }
    respondOk(id, out)
}

// ---------- AX 属性写入 / 次级动作（v1.1.1） ----------

/** 用 AXValue 直接替换可编辑元素的值（不移动鼠标/不抢焦点）。 */
func cmdSetValue(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let pid = p["pid"] as? Int, pid > 0, let role = p["role"] as? String, !role.isEmpty,
          let value = p["value"] as? String else {
        respondErr(id, "set-value 需要 pid、role 与 value（title 可选）", code: "bad-args")
        return
    }
    let wantTitle = p["title"] as? String
    let title = (wantTitle?.isEmpty ?? true) ? nil : wantTitle
    let app = AXUIElementCreateApplication(pid_t(pid))
    guard let el = axFind(app, 0, role, title) else {
        respondErr(id, "未找到匹配元素 role=\(role) title=\(title ?? "")（先用 ax-tree 核对）", code: "element-not-found")
        return
    }
    showPiP(for: el, pid: pid_t(pid))
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else {
        respondErr(id, "元素 role=\(role) 的 AXValue 不可写（不同控件支持不同；可用 ax-tree 查看 value/actions）", code: "value-not-settable")
        return
    }
    let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
    guard err == .success else {
        respondErr(id, "AXValue 写入失败（AXError \(err.rawValue)）", code: "set-value-failed")
        return
    }
    // 回读校验（尽力而为：部分控件读回格式不同，verified=false 不代表写入失败）
    var readRef: CFTypeRef?
    var verified = false
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &readRef) == .success,
       let read = readRef as? String {
        verified = read == value
    }
    let out: [String: Any] = [
        "set": true, "verified": verified, "role": role, "title": title ?? "",
        "valueLength": value.utf16.count,
    ]
    respondOk(id, out)
}

/** 执行元素暴露的次级 AX 动作（Raise / Expand / Collapse / Show Menu 等）。 */
func cmdPerformAction(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let pid = p["pid"] as? Int, pid > 0, let role = p["role"] as? String, !role.isEmpty,
          let action = p["action"] as? String, !action.isEmpty else {
        respondErr(id, "action 需要 pid、role 与 action（title 可选）", code: "bad-args")
        return
    }
    let wantTitle = p["title"] as? String
    let title = (wantTitle?.isEmpty ?? true) ? nil : wantTitle
    let app = AXUIElementCreateApplication(pid_t(pid))
    guard let el = axFind(app, 0, role, title) else {
        respondErr(id, "未找到匹配元素 role=\(role) title=\(title ?? "")（先用 ax-tree 核对）", code: "element-not-found")
        return
    }
    showPiP(for: el, pid: pid_t(pid))
    var namesRef: CFArray?
    var actions: [String] = []
    if AXUIElementCopyActionNames(el, &namesRef) == .success, let names = namesRef as? [String] {
        actions = names
    }
    let matched = actions.first { $0 == action }
        ?? actions.first { $0.caseInsensitiveCompare(action) == .orderedSame }
    guard let perform = matched else {
        respondErr(id, "元素不支持动作「\(action)」；可用动作: \(actions.isEmpty ? "（无）" : actions.joined(separator: ", "))", code: "action-not-available")
        return
    }
    let err = AXUIElementPerformAction(el, perform as CFString)
    guard err == .success else {
        respondErr(id, "AX 动作执行失败（AXError \(err.rawValue)）", code: "action-failed")
        return
    }
    respondOk(id, ["performed": true, "action": perform, "availableActions": actions])
}

/** 在可编辑元素里选中文本（AXSelectedTextRange），或把光标放到匹配文本前/后。 */
func cmdSelectText(_ id: Any?, _ p: [String: Any]) {
    guard axTrusted() else { respondErr(id, AX_NOT_GRANTED_HINT, code: "not-granted"); return }
    guard let pid = p["pid"] as? Int, pid > 0, let role = p["role"] as? String, !role.isEmpty,
          let text = p["text"] as? String, !text.isEmpty else {
        respondErr(id, "select-text 需要 pid、role 与 text（title/prefix/suffix 可选）", code: "bad-args")
        return
    }
    let selection = (p["selection"] as? String) ?? "text"
    guard ["text", "cursor_before", "cursor_after"].contains(selection) else {
        respondErr(id, "selection 需为 text / cursor_before / cursor_after", code: "bad-args")
        return
    }
    let wantTitle = p["title"] as? String
    let title = (wantTitle?.isEmpty ?? true) ? nil : wantTitle
    let prefix = (p["prefix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let suffix = (p["suffix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let app = AXUIElementCreateApplication(pid_t(pid))
    guard let el = axFind(app, 0, role, title) else {
        respondErr(id, "未找到匹配元素 role=\(role) title=\(title ?? "")（先用 ax-tree 核对）", code: "element-not-found")
        return
    }
    guard let value = axAttr(el, kAXValueAttribute) as? String else {
        respondErr(id, "元素 role=\(role) 没有可读的 AXValue 文本", code: "value-not-readable")
        return
    }
    let ns = value as NSString
    let search = (prefix ?? "") + text + (suffix ?? "")
    var hit = ns.range(of: search)
    if hit.location == NSNotFound { // 带上下文没命中时退回纯 text（调用方的 prefix/suffix 可能不精确）
        hit = ns.range(of: text)
    }
    guard hit.location != NSNotFound else {
        respondErr(id, "元素文本里找不到目标文本（长度 \(text.utf16.count)）", code: "text-not-found")
        return
    }
    var target = hit
    if hit.length == (search as NSString).length { // 命中的是带上下文的整段，扣掉上下文
        if let prefix = prefix { target.location += (prefix as NSString).length }
        target.length = (text as NSString).length
    } else {
        target = ns.range(of: text)
        if target.location == NSNotFound {
            respondErr(id, "元素文本里找不到目标文本", code: "text-not-found")
            return
        }
    }
    let sel: CFRange
    switch selection {
    case "cursor_before": sel = CFRange(location: target.location, length: 0)
    case "cursor_after": sel = CFRange(location: target.location + target.length, length: 0)
    default: sel = CFRange(location: target.location, length: target.length)
    }
    // 尽力先聚焦元素
    var focusSettable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(el, kAXFocusedAttribute as CFString, &focusSettable) == .success,
       focusSettable.boolValue {
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    var range = sel
    guard let axRange = AXValueCreate(.cfRange, &range) else {
        respondErr(id, "无法构造 CFRange", code: "selection-failed")
        return
    }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(el, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
          settable.boolValue else {
        respondErr(id, "元素 role=\(role) 不支持 AXSelectedTextRange（可先用 element-click 聚焦再 type）", code: "selection-not-settable")
        return
    }
    let err = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axRange)
    guard err == .success else {
        respondErr(id, "AXSelectedTextRange 写入失败（AXError \(err.rawValue)）", code: "selection-failed")
        return
    }
    var verified = false
    var readRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &readRef) == .success,
       let rv = readRef, CFGetTypeID(rv) == AXValueGetTypeID() {
        var rr = CFRange()
        if AXValueGetValue(unsafeBitCast(rv, to: AXValue.self), .cfRange, &rr) {
            verified = rr.location == sel.location && rr.length == sel.length
        }
    }
    showPiP(for: el, pid: pid_t(pid))
    respondOk(id, [
        "selected": true, "verified": verified, "selection": selection,
        "range": ["location": sel.location, "length": sel.length],
        "textLength": text.utf16.count,
    ])
}

// ---------- 事件投递（v0.5.5：hidSystemState 事件源；v1.1.0：定向鼠标经合成激活后可用） ----------

/**
 * 键盘/鼠标事件统一用 HID 系统状态源创建。combinedSessionState 合成的事件不带真实 HID 修饰键状态，
 * 修饰键与按键事件之间的顺序在窗口服务器侧会错乱——⌘S/⌘N「有时不弹」的根源。
 */
func eventSource() -> CGEventSource? { CGEventSource(stateID: .hidSystemState) }

/** 键盘事件：有 pid → 定向投递到该进程；无 pid → 全局（键盘不涉及 hit-testing，两条路都可靠）。 */
func postEvent(_ pid: Int?, _ e: CGEvent) {
    if let pid = pid, pid > 0 { e.postToPid(pid_t(pid)) } else { e.post(tap: .cghidEventTap) }
}

/** 把进程带到前台（AXRaise 主窗口 + activate）；app-focus 与定向鼠标降级共用。 */
@discardableResult
func focusApp(_ pid: pid_t) -> (raised: Bool, activated: Bool) {
    var raised = false
    let app = AXUIElementCreateApplication(pid)
    if let raw = axAttr(app, kAXMainWindowAttribute) {
        let win = unsafeBitCast(raw, to: AXUIElement.self) // kAXMainWindowAttribute 必为元素
        if AXUIElementPerformAction(win, "AXRaise" as CFString) == .success { raised = true }
    }
    var activated = false
    if let running = NSRunningApplication(processIdentifier: pid) {
        activated = running.activate(options: []) // macOS 14 起 activateIgnoringOtherApps 已废弃且无效
    }
    return (raised, activated)
}

/** kCGMouseEventWindowUnderMousePointer(91)/…ThatCanHandleThisEvent(92)：Swift overlay 未导出，用原值。 */
let FIELD_WIN_UNDER_POINTER = CGEventField(rawValue: 91)!
let FIELD_WIN_CAN_HANDLE = CGEventField(rawValue: 92)!

/** pid 在屏上（常规层）且包含 (x,y) 的窗口；没有则 nil（调用方回退全局，避免落到窗外静默无效）。 */
func windowContaining(_ pid: pid_t, _ x: Double, _ y: Double) -> (windowId: Int, bounds: CGRect)? {
    for w in onScreenWindows() where w.pid == Int(pid) {
        if w.bounds.contains(CGPoint(x: x, y: y)) { return (w.windowId, w.bounds) }
    }
    return nil
}

/** 在屏常规层窗口快照（CGWindowList 本就按前→后 z 序返回）。 */
func onScreenWindows() -> [(windowId: Int, pid: Int, ownerName: String, bounds: CGRect)] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] else { return [] }
    var out: [(Int, Int, String, CGRect)] = []
    for w in list {
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
        guard layer == 0, pid > 0 else { continue }
        guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        out.append((
            (w[kCGWindowNumber as String] as? Int) ?? 0,
            pid,
            (w[kCGWindowOwnerName as String] as? String) ?? "",
            CGRect(x: (b["X"] as? Double) ?? 0, y: (b["Y"] as? Double) ?? 0,
                   width: (b["Width"] as? Double) ?? 0, height: (b["Height"] as? Double) ?? 0)
        ))
    }
    return out
}

// ---------- 合成激活（v1.1.0）：让目标应用“以为自己在前台”，不改真实前台、不动真实光标 ----------
//
// Codex Computer Use 的实测机制（REA 静态分析 + 本机复现）：
//   1. 向目标 pid 投递一个 NSEvent(type=13 AppKitDefined, subtype=1 ApplicationActivated) 的
//      CGEvent。目标应用的 NSApplication 会收到 applicationDidBecomeActive 并把它的 keyWindow
//      立起来，但 WindowServer 的真实前台应用不变（用户无感）。
//   2. 定向鼠标事件不是直接 CGEvent(mouseEventSource:)，而是先用
//      NSEvent.mouseEvent(..., windowNumber: 目标窗口) 造事件、再取 cgEvent——这样事件才带
//      窗口归属，AppKit 才会把它派发到目标窗口（否则 NSEvent.windowNumber=0，事件被丢弃）。
//   3. 收尾时投递 subtype=2 ApplicationDeactivated，目标应用恢复“未激活”状态。

let SYNTHETIC_FOCUS_TTL: TimeInterval = 5.0 // 最后一次动作后 5s 自动反激活
let syntheticFocusLock = NSLock()
var syntheticFocusPid: pid_t = 0
var syntheticFocusGeneration = 0 // 每次激活/反激活自增；过期定时器据此失效（避免误伤新目标）
var syntheticFocusTimer: DispatchWorkItem?
var syntheticFocusSignalSources: [DispatchSourceSignal] = []

/** 应用是否真的是当前前台（合成激活不会改变这个判断）。 */
func frontmostPid() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
}

/** 投递 AppKitDefined 事件：subtype 1=ApplicationActivated / 2=ApplicationDeactivated。 */
func postAppKitDefined(_ pid: pid_t, subtype: Int16) {
    guard let ev = NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: 0, context: nil, subtype: subtype,
                                      data1: 0, data2: 0),
          let cg = ev.cgEvent else { return }
    cg.postToPid(pid)
}

/** 确保目标应用“以为自己在前台”；返回是否真的做了合成激活（已在前台/同一 pid 返回 false）。 */
@discardableResult
func ensureSyntheticFocus(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if frontmostPid() == pid {
        releaseSyntheticFocus()
        return false
    }
    syntheticFocusLock.lock()
    let previous = syntheticFocusPid
    syntheticFocusPid = pid
    syntheticFocusGeneration += 1
    let generation = syntheticFocusGeneration
    syntheticFocusTimer?.cancel()
    let item = DispatchWorkItem { releaseSyntheticFocus(generation: generation) }
    syntheticFocusTimer = item
    syntheticFocusLock.unlock()

    if previous != pid { // 先撤旧目标，再激活新目标
        if previous > 0 { postAppKitDefined(previous, subtype: 2) }
        postAppKitDefined(pid, subtype: 1)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + SYNTHETIC_FOCUS_TTL, execute: item)
    return true
}

// 最近一次交互窗口（pid → windowId/bounds）：键盘动作真激活时用它把目标窗口设为 main。
let lastWindowLock = NSLock()
var lastWindowByPid: [pid_t: (wid: Int, bounds: CGRect)] = [:]

func rememberWindow(pid: pid_t, wid: Int, bounds: CGRect) {
    lastWindowLock.lock()
    lastWindowByPid[pid] = (wid, bounds)
    lastWindowLock.unlock()
}

func rememberedWindow(_ pid: pid_t) -> (wid: Int, bounds: CGRect)? {
    lastWindowLock.lock()
    defer { lastWindowLock.unlock() }
    return lastWindowByPid[pid]
}

/** 把目标窗口设为应用内 main window 并 raise（best effort）。
 *  AppKit 只把定向鼠标事件派发给 key/main 窗口；同一应用内点击非 key 窗口时必须先做这一步，
 *  否则事件带对了 windowNumber 也会被丢弃。只动应用内部窗口序，不做真实前台切换。 */
func focusWindowForClick(_ pid: pid_t, _ bounds: CGRect) {
    let app = AXUIElementCreateApplication(pid)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
          let windows = ref as? [AXUIElement] else { return }
    var best: AXUIElement?
    var bestScore = CGFloat.greatestFiniteMagnitude
    for w in windows {
        guard let pos = axPointOrSize(axAttr(w, kAXPositionAttribute)),
              let size = axPointOrSize(axAttr(w, kAXSizeAttribute)) else { continue }
        let score = abs(pos[0] - bounds.minX) + abs(pos[1] - bounds.minY)
                  + abs(size[0] - bounds.width) + abs(size[1] - bounds.height)
        if score < bestScore { bestScore = score; best = w }
    }
    guard let win = best else { return }
    var mainRef: CFTypeRef?
    let isMain = AXUIElementCopyAttributeValue(win, kAXMainAttribute as CFString, &mainRef) == .success
        && (mainRef as? Bool) == true
    if !isMain {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(win, kAXMainAttribute as CFString, &settable) == .success,
           settable.boolValue {
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else if AXUIElementIsAttributeSettable(win, kAXFocusedAttribute as CFString, &settable) == .success,
                  settable.boolValue {
            AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }
}

/** 用 AX 元素所在窗口定位 PiP 预览（匹配 CGWindow）；失败退回 pid 的第一张窗口。 */
func showPiP(for element: AXUIElement, pid: pid_t) {
    if let raw = axAttr(element, kAXWindowAttribute) {
        let win = unsafeBitCast(raw, to: AXUIElement.self)
        if let pos = axPointOrSize(axAttr(win, kAXPositionAttribute)),
           let size = axPointOrSize(axAttr(win, kAXSizeAttribute)) {
            let b = CGRect(x: pos[0], y: pos[1], width: size[0], height: size[1])
            if let w = onScreenWindows().first(where: {
                $0.pid == Int(pid) && abs($0.bounds.minX - b.minX) < 4 && abs($0.bounds.minY - b.minY) < 4
            }) {
                rememberWindow(pid: pid, wid: w.windowId, bounds: w.bounds)
                controlPiP.show(pid: pid, windowId: w.windowId, windowBounds: w.bounds)
                return
            }
        }
    }
    controlPiP.show(pid: pid)
}

/** 反激活（幂等）：目标若已真的在前台则不发，避免把它“说”成未激活。
 *  generation 非空时只处理同代定时器（旧的 5s 定时器不能误伤后来重新激活的目标）。 */
func releaseSyntheticFocus(generation: Int? = nil) {
    syntheticFocusLock.lock()
    if let g = generation, g != syntheticFocusGeneration {
        syntheticFocusLock.unlock()
        return
    }
    syntheticFocusGeneration += 1
    syntheticFocusTimer?.cancel()
    syntheticFocusTimer = nil
    let pid = syntheticFocusPid
    syntheticFocusPid = 0
    syntheticFocusLock.unlock()
    controlPiP.hide()
    guard pid > 0, frontmostPid() != pid else { return }
    postAppKitDefined(pid, subtype: 2)
}

// ---------- 键盘专用真实激活（v1.1.3） ----------
//
// 本机实测：合成激活能让 App 收到鼠标/AX 事件，但 macOS 26 不再把后台 App 的
// CGEventPostToPid 键盘事件派发给它（带 windowNumber 的 NSEvent.keyEvent 也一样）。
// Codex 用的是私有 SAIVirtualKeyPress，公开 API 无法等价复刻。务实方案：键盘/粘贴
// 动作短暂真激活目标 App（窗口设为 main），发完键后恢复原前台；鼠标/AX 动作仍走
// 合成激活，不抢前台。

struct KeyboardFocus {
    var requested = false
    var activated = false
    var previousPid: pid_t = 0
    var targetPid: pid_t = 0
}

func activateForKeyboard(_ pid: pid_t, window: (wid: Int, bounds: CGRect)?) -> KeyboardFocus {
    var f = KeyboardFocus(targetPid: pid)
    if frontmostPid() == pid { return f } // 已真前台，直接发
    f.requested = true
    f.previousPid = frontmostPid() ?? 0
    releaseSyntheticFocus() // 键盘走真激活，先清掉合成状态
    if let w = window { focusWindowForClick(pid, w.bounds) }
    if let app = NSRunningApplication(processIdentifier: pid) {
        _ = app.activate(options: [.activateAllWindows])
    }
    for _ in 0..<12 { // 最多约 300ms
        usleep(25_000)
        if frontmostPid() == pid { f.activated = true; break }
    }
    return f
}

/** 键盘发完后恢复原前台；用户中途切走则不抢。 */
func restoreAfterKeyboard(_ f: KeyboardFocus) {
    guard f.requested, f.activated, f.previousPid > 0, f.previousPid != f.targetPid else { return }
    guard frontmostPid() == f.targetPid else { return }
    usleep(60_000) // 给目标应用处理完按键/粘贴
    if let prev = NSRunningApplication(processIdentifier: f.previousPid) {
        _ = prev.activate(options: [])
    }
    controlPiP.hide()
}

/** 键盘动作真激活失败时的统一错误（无窗口/无 bundle 的后台进程）。 */
let KEYBOARD_FOCUS_ERROR = "无法把目标应用切到前台，键盘事件无法可靠投递；可改用 cua_set_value / cua_paste（需要前台）或 cua_app_focus"


/** 一次点击的投递方式回执：targeted=定向到目标窗口（不抢前台、不动真光标）；fallbackGlobal=全局降级。 */
struct ClickDelivery {
    var targeted = false
    var fallbackGlobal = false
    var syntheticFocus = false
    var noWindow = false // 给了 pid 但点击点没有目标窗口：不点，避免误点前台
    var eventBuildFailed = false // 定向事件构造失败：不点，避免全局盲点
    var windowId: Int? = nil
}

/** 全局注入（会移动真实光标）——仅无 pid / 找不到目标窗口时兜底。 */
func postGlobalClick(_ pt: CGPoint) {
    let src = eventSource()
    guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
          let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) else { return }
    down.post(tap: .cghidEventTap)
    usleep(10_000) // down/up 间隔 10ms：贴近真实点击，双击检测等时序才正常
    up.post(tap: .cghidEventTap)
}

/** 主屏高度（点）：NSEvent.cgEvent 的 y 翻转以主屏为基准。 */
func mainScreenHeight() -> Double {
    Double(CGDisplayBounds(CGMainDisplayID()).height)
}

/** 造一个带窗口归属的定向鼠标事件（NSEvent → cgEvent + 字段 3/7/91/92 + clickState）。 */
func targetedMouseEvent(_ type: NSEvent.EventType, screenPt: CGPoint, bounds: CGRect, wid: Int,
                        clickCount: Int = 1) -> CGEvent? {
    let wx = screenPt.x - bounds.minX
    let wy = bounds.maxY - screenPt.y
    let inputY = mainScreenHeight() - bounds.height + wy
    guard let ne = NSEvent.mouseEvent(with: type, location: NSPoint(x: wx, y: inputY),
                                      modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: wid, context: nil, eventNumber: 0,
                                      clickCount: clickCount, pressure: 1.0),
          let e = ne.cgEvent else { return nil }
    e.setIntegerValueField(.mouseEventButtonNumber, value: 0)
    e.setIntegerValueField(CGEventField(rawValue: 7)!, value: 3) // NSEventSubtypeMouseEvent
    e.setIntegerValueField(FIELD_WIN_UNDER_POINTER, value: Int64(wid))
    e.setIntegerValueField(FIELD_WIN_CAN_HANDLE, value: Int64(wid))
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
    return e
}

/**
 * 鼠标点击（v1.1.0）。有 pid 且能定位目标窗口时：
 *   ① 合成激活（目标“以为”自己在前台，真实前台不变）
 *   ② 同一应用内非 key 窗口：AX 设为应用内 main window + raise（只动应用内部窗口序）
 *   ③ 用 NSEvent.mouseEvent(windowNumber: 目标窗口) 造 down/up，取 cgEvent，补窗口关联字段
 *   ④ postToPid 定向投递——事件带窗口归属，落到目标窗口，真实光标不动
 * 无 pid：全局注入（会移动真实光标，如实回执 fallbackGlobal）。
 * 有 pid 但点击点没有目标窗口：不点（noWindow=true），避免误点当前前台应用。
 */
func postClick(_ pid: Int?, _ x: Double, _ y: Double) -> ClickDelivery {
    var d = ClickDelivery()
    let pt = CGPoint(x: x, y: y)
    guard let pid = pid, pid > 0 else {
        postGlobalClick(pt)
        d.fallbackGlobal = true
        return d
    }
    guard let (wid, bounds) = windowContaining(pid_t(pid), x, y) else {
        d.noWindow = true // 目标可能在别的桌面/已最小化：不盲点前台应用
        return d
    }
    d.windowId = wid
    rememberWindow(pid: pid_t(pid), wid: wid, bounds: bounds)
    d.syntheticFocus = ensureSyntheticFocus(pid_t(pid))
    if d.syntheticFocus { usleep(20_000) } // 等目标应用处理 activation（keyWindow 就位）
    focusWindowForClick(pid_t(pid), bounds) // 非 key 窗口先设为应用内 main，否则事件会被丢弃
    controlPiP.show(pid: pid_t(pid), windowId: wid, windowBounds: bounds) // 常驻控制指示器

    guard let down = targetedMouseEvent(.leftMouseDown, screenPt: pt, bounds: bounds, wid: wid),
          let up = targetedMouseEvent(.leftMouseUp, screenPt: pt, bounds: bounds, wid: wid) else {
        d.eventBuildFailed = true // 有 pid 时不全局盲点
        return d
    }
    down.postToPid(pid_t(pid))
    usleep(10_000)
    up.postToPid(pid_t(pid))
    d.targeted = true
    return d
}

func cmdXyClick(_ id: Any?, _ p: [String: Any]) {
    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue else {
        respondErr(id, "xy-click 需要 x/y（数字）")
        return
    }
    let pid = p["pid"] as? Int
    let d = postClick(pid, x, y)
    if d.noWindow {
        respondErr(id, "目标 pid 在 (\(x),\(y)) 没有可点击窗口（可能在别的桌面/已最小化）；未执行，避免误点前台应用", code: "no-window-at-point")
        return
    }
    if d.eventBuildFailed {
        respondErr(id, "无法构造定向鼠标事件；未执行（避免全局盲点）", code: "click-event-failed")
        return
    }
    var out: [String: Any] = ["x": x, "y": y, "targeted": d.targeted]
    if d.targeted {
        out["mode"] = "targeted"
        out["syntheticFocus"] = d.syntheticFocus
        out["note"] = d.syntheticFocus
            ? "定向投递：目标应用已被合成激活（真实前台不变、真实光标不动）"
            : "定向投递：目标已是前台（不移动真实光标）"
    } else if d.fallbackGlobal {
        out["fallback"] = "global"
        out["note"] = "无 pid：全局投递（会移动真实光标）"
    }
    if let wid = d.windowId { out["windowId"] = wid }
    respondOk(id, out)
}

// ---------- scroll / drag（v1.1.2：定向滚动与拖拽，复用合成激活 + 窗口归属） ----------

/** 在 point 下找 AXScrollArea，改对应滚动条的 AXValue（标准 AppKit 滚动区通用）。
 *  AXScrollDownByPage 等动作在 macOS 26 上会返回 -25205，滚条 value 才是可靠路径。 */
struct AxScrollBarResult {
    var ok = false
    var bar = ""
    var value: Double = 0
    var verified = false
}

func axScrollBarAt(_ point: CGPoint, _ direction: String, _ pages: Int) -> AxScrollBarResult {
    var result = AxScrollBarResult()
    let sys = AXUIElementCreateSystemWide()
    var ref: AXUIElement?
    guard AXUIElementCopyElementAtPosition(sys, Float(point.x), Float(point.y), &ref) == .success,
          var el = ref else { return result }
    for _ in 0..<12 {
        if (axAttr(el, kAXRoleAttribute) as? String) == "AXScrollArea" { break }
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
              let p = parentRef else { return result }
        el = unsafeBitCast(p, to: AXUIElement.self)
    }
    guard (axAttr(el, kAXRoleAttribute) as? String) == "AXScrollArea" else { return result }
    let vertical = (direction == "up" || direction == "down")
    let attr = vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
    var barRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &barRef) == .success,
          let barRef = barRef else { return result }
    let bar = unsafeBitCast(barRef, to: AXUIElement.self)
    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &valueRef) == .success,
          let old = (valueRef as? NSNumber)?.doubleValue else { return result }
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { return result }
    let step = 0.1 * Double(max(1, pages))
    let target = (direction == "down" || direction == "right")
        ? min(1.0, old + step) : max(0.0, old - step)
    guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                       NSNumber(value: target)) == .success else { return result }
    result.ok = true
    result.bar = vertical ? "vertical" : "horizontal"
    result.value = target
    var readRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(bar, kAXValueAttribute as CFString, &readRef) == .success,
       let read = (readRef as? NSNumber)?.doubleValue {
        result.verified = abs(read - target) < 0.001
    }
    return result
}

func cmdScroll(_ id: Any?, _ p: [String: Any]) {
    guard let pid = p["pid"] as? Int, pid > 0 else {
        respondErr(id, "scroll 需要 pid", code: "bad-args")
        return
    }
    var point: CGPoint?
    let x = (p["x"] as? NSNumber)?.doubleValue
    let y = (p["y"] as? NSNumber)?.doubleValue
    if let x = x, let y = y, x.isFinite, y.isFinite {
        point = CGPoint(x: x, y: y)
    } else if let role = p["role"] as? String, !role.isEmpty {
        let wantTitle = p["title"] as? String
        let title = (wantTitle?.isEmpty ?? true) ? nil : wantTitle
        let app = AXUIElementCreateApplication(pid_t(pid))
        if let el = axFind(app, 0, role, title),
           let pos = axPointOrSize(axAttr(el, kAXPositionAttribute)),
           let size = axPointOrSize(axAttr(el, kAXSizeAttribute)) {
            point = CGPoint(x: pos[0] + size[0] / 2, y: pos[1] + size[1] / 2)
        }
    } else if let w = onScreenWindows().first(where: { $0.pid == pid }) {
        point = CGPoint(x: w.bounds.midX, y: w.bounds.midY)
    }
    guard let pt = point else {
        respondErr(id, "scroll 找不到可滚动窗口（目标可能在别的桌面/已最小化）", code: "no-window-at-point")
        return
    }
    guard let (wid, bounds) = windowContaining(pid_t(pid), pt.x, pt.y) else {
        respondErr(id, "scroll 的落点没有目标窗口；未执行", code: "no-window-at-point")
        return
    }
    var dx: Int32 = 0
    var dy: Int32 = 0
    var direction: String? = nil
    var pages = 1
    if let d = p["direction"] as? String {
        direction = d.lowercased()
        pages = max(1, min(10, p["pages"] as? Int ?? 1))
        let px = Int32(400 * pages)
        switch direction! {
        case "up": dy = px
        case "down": dy = -px
        case "left": dx = px
        case "right": dx = -px
        default:
            respondErr(id, "direction 需为 up/down/left/right", code: "bad-args")
            return
        }
    } else if let sx = p["scrollX"] as? Int, let sy = p["scrollY"] as? Int {
        dx = Int32(sx)
        dy = Int32(sy)
    } else {
        respondErr(id, "scroll 需要 direction/pages 或 scrollX/scrollY", code: "bad-args")
        return
    }
    // 优先 AX 滚动条 value（后台可用、不依赖真实光标/窗口关联）；不支持时才回退滚轮事件。
    if let direction = direction {
        let ax = axScrollBarAt(pt, direction, pages)
        if ax.ok {
            rememberWindow(pid: pid_t(pid), wid: wid, bounds: bounds)
            controlPiP.show(pid: pid_t(pid), windowId: wid, windowBounds: bounds)
            respondOk(id, [
                "scrolled": true, "via": "ax-scrollbar", "bar": ax.bar, "value": ax.value,
                "verified": ax.verified, "pages": pages,
                "dx": dx, "dy": dy, "steps": pages, "direction": direction,
                "windowId": wid, "targeted": true, "syntheticFocus": false,
            ])
            return
        }
    }
    let synth = ensureSyntheticFocus(pid_t(pid))
    if synth { usleep(20_000) }
    focusWindowForClick(pid_t(pid), bounds)
    rememberWindow(pid: pid_t(pid), wid: wid, bounds: bounds)
    controlPiP.show(pid: pid_t(pid), windowId: wid, windowBounds: bounds)
    let steps = (direction == nil) ? 1 : pages
    let src = eventSource()
    for _ in 0..<steps {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else {
            respondErr(id, "无法构造滚轮事件", code: "scroll-failed")
            return
        }
        e.location = pt
        e.setIntegerValueField(FIELD_WIN_UNDER_POINTER, value: Int64(wid))
        e.setIntegerValueField(FIELD_WIN_CAN_HANDLE, value: Int64(wid))
        e.postToPid(pid_t(pid))
        usleep(10_000)
    }
    respondOk(id, [
        "scrolled": true, "via": "event", "dx": dx, "dy": dy, "steps": steps,
        "direction": direction ?? "", "windowId": wid,
        "targeted": true, "syntheticFocus": synth,
    ])
}

func cmdDrag(_ id: Any?, _ p: [String: Any]) {
    guard let pid = p["pid"] as? Int, pid > 0,
          let fx = (p["fromX"] as? NSNumber)?.doubleValue, let fy = (p["fromY"] as? NSNumber)?.doubleValue,
          let tx = (p["toX"] as? NSNumber)?.doubleValue, let ty = (p["toY"] as? NSNumber)?.doubleValue,
          fx.isFinite, fy.isFinite, tx.isFinite, ty.isFinite else {
        respondErr(id, "drag 需要 pid 与 fromX/fromY/toX/toY（数字）", code: "bad-args")
        return
    }
    let from = CGPoint(x: fx, y: fy)
    let to = CGPoint(x: tx, y: ty)
    guard let (wid, bounds) = windowContaining(pid_t(pid), from.x, from.y) else {
        respondErr(id, "drag 起点没有目标窗口；未执行", code: "no-window-at-point")
        return
    }
    let synth = ensureSyntheticFocus(pid_t(pid))
    if synth { usleep(20_000) }
    focusWindowForClick(pid_t(pid), bounds)
    rememberWindow(pid: pid_t(pid), wid: wid, bounds: bounds)
    controlPiP.show(pid: pid_t(pid), windowId: wid, windowBounds: bounds)
    let steps = max(2, min(60, p["steps"] as? Int ?? 12))
    let durationMs = max(30, min(2000, p["durationMs"] as? Int ?? 300))
    let stepDelay = max(1, UInt32(Double(durationMs) * 1000.0 / Double(steps)))
    guard let down = targetedMouseEvent(.leftMouseDown, screenPt: from, bounds: bounds, wid: wid) else {
        respondErr(id, "无法构造拖拽按下事件", code: "drag-failed")
        return
    }
    down.postToPid(pid_t(pid))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let pt = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if let e = targetedMouseEvent(.leftMouseDragged, screenPt: pt, bounds: bounds, wid: wid) {
            usleep(stepDelay)
            e.postToPid(pid_t(pid))
        }
    }
    usleep(10_000)
    guard let up = targetedMouseEvent(.leftMouseUp, screenPt: to, bounds: bounds, wid: wid) else {
        respondErr(id, "无法构造拖拽释放事件", code: "drag-failed")
        return
    }
    up.postToPid(pid_t(pid))
    respondOk(id, [
        "dragged": true, "from": [fx, fy], "to": [tx, ty], "steps": steps,
        "durationMs": durationMs, "windowId": wid,
        "targeted": true, "syntheticFocus": synth,
    ])
}

// ---------- type / key ----------

func cmdType(_ id: Any?, _ p: [String: Any]) {
    guard let text = p["text"] as? String, !text.isEmpty else {
        respondErr(id, "type 需要 text（非空字符串）")
        return
    }
    if text.count > 4000 {
        respondErr(id, "text 过长（>4000 字符），请分段输入", code: "text-too-long")
        return
    }
    let pid = p["pid"] as? Int
    var focus = KeyboardFocus()
    if let pid = pid, pid > 0 {
        let w = rememberedWindow(pid_t(pid))
        focus = activateForKeyboard(pid_t(pid), window: w)
        if focus.requested && !focus.activated {
            respondErr(id, KEYBOARD_FOCUS_ERROR, code: "keyboard-focus-failed")
            return
        }
        controlPiP.show(pid: pid_t(pid), windowId: w?.wid, windowBounds: w?.bounds)
    }
    defer { restoreAfterKeyboard(focus) }
    let src = eventSource()
    // 中文等非键码字符唯一可靠路径：CGEventKeyboardSetUnicodeString 把 UTF-16 文本直接塞进事件，
    // 绕过键码翻译与输入法合成。单事件上限 20 个 UTF-16 码元——必须按码元（而非 Character）
    // 分段：一个 emoji 常占 2+ 码元，按字符合段会静默超限丢字。
    let units = Array(text.utf16)
    var sent = 0
    var i = 0
    while i < units.count {
        let n = min(20, units.count - i)
        let chunk = Array(units[i..<(i + n)])
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { break }
        down.keyboardSetUnicodeString(stringLength: n, unicodeString: chunk)
        up.keyboardSetUnicodeString(stringLength: n, unicodeString: chunk)
        postEvent(pid, down)
        usleep(12000) // 12ms/段：太快部分应用会丢字
        postEvent(pid, up)
        usleep(8000)
        sent += n
        i += n
    }
    respondOk(id, ["chars": sent, "realFocus": focus.activated]) // chars 与 JS text.length 同口径（UTF-16 码元数）
}

/** 常用键 → 虚拟键码（ANSI 布局）；字母数字直接查表。 */
let KEY_CODES: [String: Int] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

let MOD_FLAGS: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "ctrl": .maskControl, "control": .maskControl,
    "alt": .maskAlternate, "option": .maskAlternate,
    "shift": .maskShift,
]

/** 修饰键物理键码（flagsChange 事件要带真实键码）：cmd=0x37 shift=0x38 option=0x3A control=0x3B。 */
let MOD_KEY_CODES: [(flag: CGEventFlags, code: CGKeyCode)] = [
    (.maskCommand, 0x37), (.maskShift, 0x38), (.maskAlternate, 0x3A), (.maskControl, 0x3B),
]

/**
 * 合成一次 flagsChange 事件（修饰键按下/释放）：键事件改 type 为 .flagsChanged 并携带
 * 「该修饰键之后」的系统修饰状态，与真实键盘的报告方式一致。
 */
func makeFlagsChange(_ src: CGEventSource?, _ keyCode: CGKeyCode, _ keyDown: Bool, _ flags: CGEventFlags) -> CGEvent? {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: keyDown) else { return nil }
    e.type = .flagsChanged
    e.flags = flags
    return e
}

func cmdKey(_ id: Any?, _ p: [String: Any]) {
    guard let key = p["key"] as? String else { respondErr(id, "key 需要键名"); return }
    let lowered = key.lowercased()
    guard let code = KEY_CODES[lowered] else {
        respondErr(id, "不支持的键名: \(key)（支持字母/数字/enter/tab/escape/space/delete/方向键/home/end/pageup/pagedown/f1-f12）", code: "unknown-key")
        return
    }
    var flags: CGEventFlags = []
    var names: [String] = []
    if let mods = p["modifiers"] as? [String] {
        for m in mods {
            guard let f = MOD_FLAGS[m.lowercased()] else {
                respondErr(id, "不支持的修饰键: \(m)（cmd/ctrl/alt/shift）", code: "unknown-modifier")
                return
            }
            flags.insert(f)
            names.append(m.lowercased())
        }
    }
    let pid = p["pid"] as? Int
    var focus = KeyboardFocus()
    if let pid = pid, pid > 0 {
        let w = rememberedWindow(pid_t(pid))
        focus = activateForKeyboard(pid_t(pid), window: w)
        if focus.requested && !focus.activated {
            respondErr(id, KEYBOARD_FOCUS_ERROR, code: "keyboard-focus-failed")
            return
        }
        controlPiP.show(pid: pid_t(pid), windowId: w?.wid, windowBounds: w?.bounds)
    }
    defer { restoreAfterKeyboard(focus) }
    let src = eventSource()
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: false) else {
        respondErr(id, "无法构造键盘事件")
        return
    }
    // v0.5.5 真实按键序列：修饰键 flagsChange 逐个按下 → keyDown → keyUp → flagsChange 逐个释放，
    // 事件间 5ms 让系统消化顺序；keyDown/keyUp 自身也带修饰 flag（真实键盘正是如此，兜底只看
    // 按键事件 flag 的应用）。combinedSessionState 源 + 瞬发 down/up 正是 ⌘S/⌘N「有时不弹」的根因。
    let modFlags = MOD_KEY_CODES.filter { flags.contains($0.flag) }
    var held: CGEventFlags = []
    for m in modFlags {
        held.insert(m.flag)
        if let e = makeFlagsChange(src, m.code, true, held) { postEvent(pid, e) }
        usleep(5000)
    }
    down.flags = flags
    postEvent(pid, down)
    usleep(10000)
    up.flags = flags
    postEvent(pid, up)
    usleep(5000)
    for m in modFlags.reversed() {
        held.remove(m.flag)
        if let e = makeFlagsChange(src, m.code, false, held) { postEvent(pid, e) }
        usleep(5000)
    }
    respondOk(id, ["key": lowered, "keyCode": code, "modifiers": names, "realFocus": focus.activated])
}

// ---------- paste（剪贴板 + ⌘V，完成后恢复原剪贴板） ----------

/** 发送 ⌘V：沿用 cmdKey 的真实修饰键序列（flagsChange → keyDown → keyUp → flagsChange）。 */
func sendCommandV(_ pid: Int?) {
    let src = eventSource()
    let code = CGKeyCode(KEY_CODES["v"] ?? 9)
    if let e = makeFlagsChange(src, 0x37, true, .maskCommand) { postEvent(pid, e) }
    usleep(5000)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
        down.flags = .maskCommand
        postEvent(pid, down)
    }
    usleep(10000)
    if let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
        up.flags = .maskCommand
        postEvent(pid, up)
    }
    usleep(5000)
    if let e = makeFlagsChange(src, 0x37, false, []) { postEvent(pid, e) }
}

func cmdPaste(_ id: Any?, _ p: [String: Any]) {
    guard let pid = p["pid"] as? Int, pid > 0, let text = p["text"] as? String, !text.isEmpty else {
        respondErr(id, "paste 需要 pid 与非空 text", code: "bad-args")
        return
    }
    let format = (p["format"] as? String) ?? "text"
    guard ["text", "md", "html"].contains(format) else {
        respondErr(id, "format 需为 text / md / html", code: "bad-format")
        return
    }
    if text.utf16.count > 4000 {
        respondErr(id, "text 过长（>4000 字符），请分段粘贴", code: "text-too-long")
        return
    }
    let w = rememberedWindow(pid_t(pid))
    let focus = activateForKeyboard(pid_t(pid), window: w)
    if focus.requested && !focus.activated {
        respondErr(id, KEYBOARD_FOCUS_ERROR, code: "keyboard-focus-failed")
        return
    }
    defer { restoreAfterKeyboard(focus) }
    controlPiP.show(pid: pid_t(pid), windowId: w?.wid, windowBounds: w?.bounds)
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { item -> NSPasteboardItem in
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
    defer {
        usleep(150_000) // 给目标应用读剪贴板的时间
        pb.clearContents()
        if !saved.isEmpty { pb.writeObjects(saved) }
    }
    pb.clearContents()
    if format == "html" {
        pb.setString(text, forType: .html)
        pb.setString(text, forType: .string)
    } else {
        pb.setString(text, forType: .string)
    }
    sendCommandV(pid)
    usleep(80_000)
    respondOk(id, ["pasted": true, "chars": text.utf16.count, "format": format, "clipboardRestored": true, "realFocus": focus.activated])
}

// ---------- app-focus ----------

func cmdAppFocus(_ id: Any?, _ p: [String: Any]) {
    guard let pid = p["pid"] as? Int, pid > 0 else { respondErr(id, "app-focus 需要 pid"); return }
    releaseSyntheticFocus() // 真前台切换前先撤掉“目标以为自己在后台/前台”的合成状态
    let r = focusApp(pid_t(pid))
    respondOk(id, ["axRaised": r.raised, "appActivated": r.activated])
}

/** 显式撤销合成激活（幂等）；服务端收尾/切目标时可主动调用。 */
func cmdReleaseFocus(_ id: Any?) {
    releaseSyntheticFocus()
    respondOk(id, ["released": true])
}

// ---------- 幽魂光标叠加层（overlay：AI 动手位置的可见化提示；真鼠标始终不动） ----------

let AMBER = NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 1) // 与扩展角标同色系

/** 箭头多边形（热区在 (0,0)，箭体向右下延伸；y 向下坐标，draw 时按锚点平移）。 */
let ARROW_POINTS: [CGPoint] = [
    CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 16.9), CGPoint(x: 4.2, y: 12.7), CGPoint(x: 7.1, y: 19.6),
    CGPoint(x: 10.3, y: 18.2), CGPoint(x: 7.4, y: 11.5), CGPoint(x: 12.2, y: 11.5),
]

/** 叠加绘制视图：kind=arrow 只画琥珀箭头；kind=click 追加约 350ms 的扩散涟漪。 */
final class OverlayView: NSView {
    var isClick = false
    var ripple: CGFloat = 0 // 涟漪进度 0→1
    let anchor = CGPoint(x: 56, y: 56) // 热区在 140x140 视图内的锚点（涟漪最大半径 52 也容纳得下）

    override var isFlipped: Bool { true } // 与屏幕像素同向（y 向下），坐标换算直观

    override func draw(_ dirtyRect: NSRect) {
        // 涟漪：以热区为圆心，半径 8→52、透明度 0.85→0 扩散一圈
        if isClick, ripple > 0 {
            let t = min(max(ripple, 0), 1)
            let radius = 8 + 44 * t
            let ring = NSBezierPath(ovalIn: NSRect(x: anchor.x - radius, y: anchor.y - radius,
                                                   width: radius * 2, height: radius * 2))
            AMBER.withAlphaComponent(0.85 * (1 - t)).setStroke()
            ring.lineWidth = 3 - 2 * t
            ring.stroke()
        }
        // 箭头主体：多边形 × 1.15 平移到锚点（热区尖端精确落在动作坐标上）
        let path = NSBezierPath()
        for (i, pt) in ARROW_POINTS.enumerated() {
            let p = NSPoint(x: anchor.x + pt.x * 1.15, y: anchor.y + pt.y * 1.15)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        // 柔和外发光：给填充挂一圈琥珀阴影（blur 12），再实心填充 + 白描边
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowColor = AMBER.withAlphaComponent(0.55)
        shadow.shadowOffset = .zero
        shadow.set()
        AMBER.setFill()
        path.fill()
        NSShadow().set() // 清除阴影，避免影响描边
        NSColor.white.setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }
}

/**
 * 幽魂光标控制器：懒创建一次 140x140 点击穿透面板并复用；显示 durationMs 后淡出。
 * 仅主线程调用（命令分发处保证）。失败安全：任何异常路径只返回错误文案，不影响主命令循环。
 */
final class OverlayController {
    private let panelSize: CGFloat = 140
    private var panel: NSPanel?
    private var view: OverlayView?
    private var fadeItem: DispatchWorkItem?
    private var rippleTimer: Timer?
    private var generation = 0 // 防串台：新一次显示后，旧淡出/涟漪回调不得动新窗口

    /** 显示；成功返回 nil，失败返回错误文案。 */
    func show(x: Double, y: Double, kind: String, durationMs: Int) -> String? {
        guard let main = NSScreen.screens.first else { return "无可用屏幕（NSScreen.screens 为空）" }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: panelSize, height: panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2) // 盖普通窗口，不抢系统 UI
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true // 点击穿透
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 全屏应用上也显示
            p.isReleasedWhenClosed = false
            let v = OverlayView(frame: NSRect(x: 0, y: 0, width: panelSize, height: panelSize))
            p.contentView = v
            panel = p
            view = v
        }
        guard let panel, let view else { return "叠加窗口创建失败" }

        generation += 1
        let gen = generation
        fadeItem?.cancel()
        rippleTimer?.invalidate()
        rippleTimer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0
            view.animator().alphaValue = 1 // 若正处淡出中，立即回满
        })
        view.isClick = (kind == "click")
        view.ripple = 0
        view.needsDisplay = true

        // 屏幕坐标（CG 系：y 向下、原点在主屏左上）→ AppKit 窗口 frame（y 向上、原点在主屏左下）。
        // 锚点对准 (x, y)，即箭头尖端/涟漪圆心精确落在动作坐标上。
        let topLeftCgY = y - Double(view.anchor.y)
        panel.setFrameOrigin(NSPoint(x: x - Double(view.anchor.x),
                                     y: main.frame.maxY - topLeftCgY - Double(panelSize)))
        panel.orderFrontRegardless() // 显示但绝不 activate（不抢焦点）

        if view.isClick {
            let start = Date()
            rippleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self, let v = self.view else { timer.invalidate(); return }
                v.ripple = CGFloat(min(Date().timeIntervalSince(start) * 1000 / 350, 1))
                v.needsDisplay = true
                if v.ripple >= 1 {
                    timer.invalidate()
                    if self.rippleTimer === timer { self.rippleTimer = nil }
                }
            }
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return } // panel/view 已是本函数解包后的局部常量
            self.rippleTimer?.invalidate()
            self.rippleTimer = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                view.animator().alphaValue = 0
            }, completionHandler: {
                guard self.generation == gen else { return } // 已被新一次显示接管
                panel.orderOut(nil)
                view.alphaValue = 1
            })
        }
        fadeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(durationMs), execute: item)
        return nil
    }

    /** 立即隐藏（自检/收尾用；幂等）。 */
    func hide() {
        generation += 1 // 使一切在途淡出/涟漪回调失效
        fadeItem?.cancel()
        fadeItem = nil
        rippleTimer?.invalidate()
        rippleTimer = nil
        panel?.orderOut(nil)
    }
}

let overlay = OverlayController()

// ---------- 常驻控制指示器（PiP-lite）：不抢焦点、点击穿透，显示目标窗口实时缩略图 ----------
//
// Codex 的 PiP 预览是其产品层的实时视频管线；这里用「目标窗口截图缩略图 + 琥珀标题条」
// 做一个轻量等价物：每次动作时出现，1s 刷新一次，合成激活结束/5s 无动作后自动收起。
// 窗口截图走 CGWindowListCreateImage（macOS 15 起 SDK 标记 obsolete，但系统符号仍在，
// 用 dlsym 动态取；取不到时显示占位图，不影响控制功能）。

private typealias CGWindowListCreateImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

private let cgWindowListCreateImage: CGWindowListCreateImageFn? = {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
    return unsafeBitCast(sym, to: CGWindowListCreateImageFn.self)
}()

final class ControlPiPView: NSView {
    var appName = ""
    var image: CGImage?
    private let headerH: CGFloat = 28

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(srgbRed: 28 / 255, green: 24 / 255, blue: 18 / 255, alpha: 0.94)
        let amber = NSColor(srgbRed: 245 / 255, green: 158 / 255, blue: 11 / 255, alpha: 1)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        bg.setFill(); path.fill()
        amber.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()

        let dot = NSRect(x: 10, y: bounds.height - headerH + 10, width: 8, height: 8)
        amber.setFill(); NSBezierPath(ovalIn: dot).fill()
        let title = "AgentDesk 正在操作 \(appName)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let ts = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: 24, y: bounds.height - headerH + (headerH - ts.height) / 2), withAttributes: attrs)

        let area = NSRect(x: 8, y: 8, width: bounds.width - 16, height: bounds.height - headerH - 8)
        if let image {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = min(area.width / iw, area.height / ih)
            let draw = NSRect(x: area.midX - iw * scale / 2, y: area.midY - ih * scale / 2,
                              width: iw * scale, height: ih * scale)
            NSImage(cgImage: image, size: NSSize(width: iw, height: ih))
                .draw(in: draw, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let placeholder = "预览不可用" as NSString
            let pa: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]
            let ps = placeholder.size(withAttributes: pa)
            placeholder.draw(at: NSPoint(x: area.midX - ps.width / 2, y: area.midY - ps.height / 2), withAttributes: pa)
        }
    }
}

/// ScreenCaptureKit 实时窗口流（macOS 12.3+）：桌面独立窗口捕获，15fps。
/// 只负责取帧/生命周期，UI 更新由 ControlPiPController 回主线程处理。
@available(macOS 12.3, *)
final class PiPLiveStream: NSObject, SCStreamDelegate, SCStreamOutput {
    var onFrame: ((CGImage) -> Void)?
    var onStarted: (() -> Void)?
    var onStop: (() -> Void)?
    private var stream: SCStream?
    private var stopped = false
    private let queue = DispatchQueue(label: "agentdesk.pip.frames", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func start(windowID: Int) {
        stopped = false
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self, !self.stopped else { return }
            guard error == nil,
                  let window = content?.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
                self.onStop?()
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = 480
            config.height = 360
            config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                self.onStop?()
                return
            }
            self.stream = stream
            stream.startCapture { [weak self] error in
                guard let self, !self.stopped else { return }
                if error != nil { self.onStop?() } else { self.onStarted?() }
            }
        }
    }

    func stop() {
        stopped = true
        stream?.stopCapture { _ in }
        stream = nil
        onFrame = nil
        onStarted = nil
        onStop = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        onFrame?(cg)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !stopped else { return }
        onStop?()
    }
}

final class ControlPiPController {
    private var panel: NSPanel?
    private var fallbackTimer: Timer?
    private var hideItem: DispatchWorkItem?
    private var generation = 0
    private var windowId = 0
    private var appName = ""
    private let ttl: TimeInterval = SYNTHETIC_FOCUS_TTL + 1.0
    private let size = NSSize(width: 240, height: 180)
    private var liveStream: AnyObject?
    private var liveToken = 0
    private let stateLock = NSLock()
    private var visible = false
    private var via = "none"
    private var frames = 0

    /** 任意线程可调；pid 必须有窗口（通常由动作路径传入 windowId/bounds）。 */
    func show(pid: pid_t, windowId: Int? = nil, windowBounds: CGRect? = nil) {
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "应用"
        let wid = windowId ?? onScreenWindows().first(where: { $0.pid == Int(pid) })?.windowId ?? 0
        let bounds = windowBounds ?? onScreenWindows().first(where: { $0.pid == Int(pid) })?.bounds
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(appName: app, windowId: wid, windowBounds: bounds)
        }
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in self?.hideOnMain() }
    }

    /** 诊断/自检用：当前预览状态（visible/via/frames/windowId）。 */
    func status() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        return ["visible": visible, "via": via, "frames": frames, "windowId": windowId]
    }

    private func showOnMain(appName: String, windowId: Int, windowBounds: CGRect?) {
        self.appName = appName
        stateLock.lock()
        self.windowId = windowId
        visible = true
        via = "starting"
        frames = 0
        stateLock.unlock()
        let frame = panelFrame(windowBounds: windowBounds)
        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.hasShadow = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.contentView = ControlPiPView(frame: NSRect(origin: .zero, size: size))
            panel = p
        }
        p.setFrame(frame, display: true)
        if let v = p.contentView as? ControlPiPView {
            v.frame = NSRect(origin: .zero, size: frame.size)
            v.appName = appName
            v.image = snapshot()
            v.needsDisplay = true
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        generation += 1
        let gen = generation
        hideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.hideOnMain()
        }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + ttl, execute: item)
        startLive(windowId: windowId)
        startFallbackTimer() // 实时流启动前先用 1s 截图顶着；sc-stream 起来后会停掉
    }

    private func hideOnMain() {
        generation += 1
        hideItem?.cancel(); hideItem = nil
        stateLock.lock()
        visible = false
        via = "none"
        frames = 0
        stateLock.unlock()
        stopLive()
        fallbackTimer?.invalidate(); fallbackTimer = nil
        panel?.orderOut(nil)
    }

    private func startLive(windowId: Int) {
        stopLive()
        guard #available(macOS 12.3, *), windowId > 0 else { startFallbackTimer(); return }
        liveToken += 1
        let token = liveToken
        let s = PiPLiveStream()
        s.onStarted = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard token == self.liveToken, self.isVisibleNow() else { return }
                self.fallbackTimer?.invalidate(); self.fallbackTimer = nil
                self.stateLock.lock(); self.via = "sc-stream"; self.stateLock.unlock()
            }
        }
        s.onFrame = { [weak self] cg in
            guard let self else { return }
            self.stateLock.lock(); self.frames += 1; self.stateLock.unlock()
            DispatchQueue.main.async {
                guard token == self.liveToken, self.isVisibleNow() else { return }
                if let p = self.panel, let v = p.contentView as? ControlPiPView {
                    v.image = cg
                    v.needsDisplay = true
                }
            }
        }
        s.onStop = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard token == self.liveToken, self.isVisibleNow() else { return }
                self.startFallbackTimer()
            }
        }
        liveStream = s
        s.start(windowID: windowId)
    }

    private func stopLive() {
        liveToken += 1
        if #available(macOS 12.3, *), let s = liveStream as? PiPLiveStream { s.stop() }
        liveStream = nil
    }

    private func isVisibleNow() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return visible
    }

    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        stateLock.lock(); via = "screenshot"; stateLock.unlock()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible else { return }
            if let v = p.contentView as? ControlPiPView {
                v.image = self.snapshot()
                v.needsDisplay = true
            }
        }
    }

    private func snapshot() -> CGImage? {
        guard windowId > 0, let fn = cgWindowListCreateImage else { return nil }
        return fn(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(windowId),
                  CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue()
    }

    private func panelFrame(windowBounds: CGRect?) -> NSRect {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var x = screen.width - size.width - 16
        var top = 40.0
        if let b = windowBounds, b.width > 40, b.height > 40 {
            x = min(screen.width - size.width - 8, max(8, b.maxX - size.width - 12))
            top = max(8, b.minY + 12)
        }
        return NSRect(x: x, y: screen.height - top - size.height, width: size.width, height: size.height)
    }
}
let controlPiP = ControlPiPController()

func cmdOverlayShow(_ id: Any?, _ p: [String: Any]) {
    guard let x = (p["x"] as? NSNumber)?.doubleValue, let y = (p["y"] as? NSNumber)?.doubleValue,
          x.isFinite, y.isFinite else {
        respondErr(id, "overlay-show 需要 x/y（数字，屏幕坐标）", code: "bad-args")
        return
    }
    let kind = p["kind"] as? String ?? "arrow"
    guard kind == "arrow" || kind == "click" else {
        respondErr(id, "overlay-show 的 kind 需为 arrow 或 click", code: "bad-kind")
        return
    }
    var durationMs = p["durationMs"] as? Int ?? 700
    if durationMs < 100 { durationMs = 100 }
    if durationMs > 5000 { durationMs = 5000 }
    DispatchQueue.main.async { // 窗口操作必须在主线程（run loop 上）
        if let reason = overlay.show(x: x, y: y, kind: kind, durationMs: durationMs) {
            respondErr(id, reason, code: "overlay-failed")
        } else {
            respondOk(id, [:])
        }
    }
}

func cmdOverlayHide(_ id: Any?) {
    DispatchQueue.main.async {
        overlay.hide()
        respondOk(id, [:])
    }
}

/** 诊断/自检：PiP 预览状态（visible/via/frames/windowId）。 */
func cmdPipStats(_ id: Any?) {
    respondOk(id, controlPiP.status())
}

// ---------- 权限引导悬浮卡片（v0.5.4 起；v1.0.0 升级：560×124 大卡 + 贴靠系统设置 + 拖 .app 授权 + 授权自动检测） ----------

let CARD_W: CGFloat = 560
let CARD_H: CGFloat = 124

/** 拖拽诊断日志（仅追加到 /tmp，便于定位“拖不进系统设置列表”这类只在真机出现的问题）。 */
func dragLog(_ msg: String) {
    let fmt = ISO8601DateFormatter()
    let line = "\(fmt.string(from: Date())) \(msg)\n"
    let p = "/tmp/agentdesk-cua-drag.log"
    let data = Data(line.utf8)
    if let fh = FileHandle(forWritingAtPath: p) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? data.write(to: URL(fileURLWithPath: p))
    }
}
let CARD_GAP: CGFloat = 20 // 双卡同屏时的纵向错位间距（accessibility 在上、screen 在下）
let SETTINGS_BUNDLE_ID = "com.apple.systempreferences" // 系统设置（bundleId 跨语言稳定；ownerName 会本地化）
let CARD_FOLLOW_INTERVAL: TimeInterval = 0.15 // 贴靠跟随轮询：150ms
let CARD_GRANT_WATCH_INTERVAL: TimeInterval = 1.2 // 授权自动检测轮询（AXIsProcessTrusted 不带 prompt）

/** 负责进程的 .app bundle 路径（拖拽句柄 promise 它——TCC 记账、设置列表要加的正是这个 App）。
 *  v1.0.0：从 AgentDesk.app 内运行时拖出的就是本 .app 本体；裸 CLI 运行走 ppid 链（终端）。 */
func responsibleAppBundleURL() -> URL? {
    if Bundle.main.bundleIdentifier != nil { return Bundle.main.bundleURL } // 本进程就是持权 .app
    var pid = parentPid(getpid()) // 与 responsibleProcessName() 同一条 ppid 链
    for _ in 0..<16 {
        if pid <= 1 { break }
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleId = app.bundleIdentifier, !bundleId.isEmpty,
           let url = app.bundleURL {
            return url
        }
        let ppid = parentPid(pid)
        if ppid <= 0 { break }
        pid = ppid
    }
    return nil
}

/** 卡片右上角 ✕：自绘 + mouseUp 触发（不依赖窗口 key 状态，nonactivating 面板里最稳的点击路径）。 */
final class CardCloseButton: NSView {
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let b = bounds.insetBy(dx: 5, dy: 5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.minY))
        path.line(to: NSPoint(x: b.maxX, y: b.maxY))
        path.move(to: NSPoint(x: b.maxX, y: b.minY))
        path.line(to: NSPoint(x: b.minX, y: b.maxY))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.stroke()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/**
 * 左侧琥珀大图标 = 拖拽句柄（v1.0.0：72px 大 tile）：按住它发起一次文件拖拽，拖出的就是
 * 「持权 .app」——从 AgentDesk.app 内运行时是本 .app 本体，裸 CLI 时是负责进程（终端）的
 * .app bundle。用户直接把它放进系统设置 → 隐私与安全性 → 辅助功能/屏幕录制 的列表里
 * （macOS 对拖入的 App 自动建 TCC 条目，效果等同点 + 号再选 App）。fileURL 为 nil（两处都
 * 找不到 .app）时鼠标事件交还父视图，句柄区退化为窗口拖动。拖拽期间经 onDragStateChange
 * 通知控制器冻结贴靠跟随（防卡片追着鼠标跑）。
 */
final class CardIconDragView: NSView, NSDraggingSource {
    var fileURL: URL?
    var onDragStateChange: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    /** 卡片常浮在系统设置之上且 App 未激活：允许“第一下点击”直接开始拖拽，不被激活点击吞掉。 */
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if fileURL != nil { addCursorRect(bounds, cursor: .openHand) } else { super.resetCursorRects() }
    }

    var appIconImage: NSImage? // .app 内运行时用 App 图标（与新品牌一致）；裸 CLI 回退手绘琥珀光标

    override func draw(_ dirtyRect: NSRect) {
        if let icon = appIconImage {
            let r = bounds.insetBy(dx: 1, dy: 1)
            let clip = NSBezierPath(roundedRect: r, xRadius: r.width * 0.22, yRadius: r.width * 0.22)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        // 裸 CLI 回退：琥珀圆 + 白描边（与扩展角标/幽灵光标同色系）
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
        AMBER.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        circle.lineWidth = 2
        circle.stroke()
        // 圆心内嵌大箭头（幽灵光标的品牌符号，热区在左上的箭头形；随 tile 尺寸缩放）
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let s = bounds.width / 72 // 以 72px 基准设计稿等比缩放
        let path = NSBezierPath()
        for (i, pt) in ARROW_POINTS.enumerated() {
            let p = NSPoint(x: c.x - 6.4 * s + pt.x * 1.05 * s, y: c.y - 10.3 * s + pt.y * 1.05 * s)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        NSColor.white.setFill()
        path.fill()
    }

    override func mouseDown(with event: NSEvent) {
        beginAppDrag(with: event)
    }

    /** 发起“把 AgentDesk.app 拖进系统设置列表”的文件拖拽。
     *  - 同时写 public.file-url 与 legacy NSFilenamesPboardType：后者被新版系统设置的 TCC 列表使用；
     *  - 拖拽前激活本 App：非激活态下从 nonactivating 面板发起的拖拽在部分 macOS 版本会被取消；
     *  - 全程写 /tmp/agentdesk-cua-drag.log，拖不动时能直接看到卡在哪一步。 */
    func beginAppDrag(with event: NSEvent) {
        guard let url = fileURL else { super.mouseDown(with: event); return }
        onDragStateChange?(true) // 冻结贴靠跟随：拖拽进行中卡片不得追着鼠标跑
        dragLog("mouseDown drag=\(url.path)")
        NSApp.activate(ignoringOtherApps: true)
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshotImage())
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
        dragLog("draggingSession started")
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        dragLog("drag willBegin at \(Int(screenPoint.x)),\(Int(screenPoint.y))")
    }

    /** 拖拽结束（无论 drop 在哪）：解除贴靠冻结。operation 为空 = 目标没接受（诊断关键）。 */
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLog("drag ended at \(Int(screenPoint.x)),\(Int(screenPoint.y)) operation=\(operation.rawValue)")
        onDragStateChange?(false)
    }

    /** 拖拽随行图像：把自己画进离屏 NSImage（CG 上下文翻转一次，与 flipped 绘制同向）。 */
    private func snapshotImage() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.cgContext.translateBy(x: 0, y: bounds.height)
            ctx.cgContext.scaleBy(x: 1, y: -1)
        }
        draw(bounds)
        img.unlockFocus()
        return img
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/** 卡片内容视图（v1.0.0：560×124）：深色圆角底 + 琥珀描边；产品名/指引/负责进程三行文案。
 *  用户拖动卡片背景（isMovableByWindowBackground）→ onUserMove → 该卡停止自动贴靠。 */
class PermissionCardView: NSView {
    let kind: String // accessibility | screen（决定指引指向哪个列表）
    var appName = "" { didSet { needsDisplay = true } } // 负责进程名（bundled 运行时=AgentDesk）
    var onUserMove: (() -> Void)? // 用户手动挪卡：停止贴靠跟随

    init(frame frameRect: NSRect, kind: String) {
        self.kind = kind
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("PermissionCardView 不走 XIB 路径") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /** 整张卡片都是拖拽句柄（✕ 子视图除外）：按住卡片任意位置拖出 AgentDesk.app。
     *  修复前只有左侧 72px 图标可拖，用户常抓住卡片主体 → 变成挪窗口，往列表里松手无效。 */
    override func mouseDown(with event: NSEvent) {
        if let icon = subviews.compactMap({ $0 as? CardIconDragView }).first, icon.fileURL != nil {
            icon.beginAppDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        NSColor(white: 0.12, alpha: 0.97).setFill() // 近黑底：浅色/深色外观下都衬得住琥珀描边
        bg.fill()
        AMBER.withAlphaComponent(0.9).setStroke()
        bg.lineWidth = 1.5
        bg.stroke()

        // 文案区：左侧 72px 图标 tile（x 18..90）+ 14 间距；右侧给 ✕ 留 44px
        let textX: CGFloat = 104
        let textW = bounds.width - textX - 44
        drawText("AgentDesk",
                 in: NSRect(x: textX, y: 22, width: textW, height: 20),
                 [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
        drawText(kind == "accessibility" ? "按住这张卡片，拖进上面的「辅助功能」列表" : "按住这张卡片，拖进上面的「屏幕录制」列表",
                 in: NSRect(x: textX, y: 50, width: textW, height: 18),
                 [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.white])
        let name = appName.isEmpty ? "AgentDesk" : appName
        drawText("拖到列表里松手即完成授权（也可点列表下方的 + 号选「\(name)」）",
                 in: NSRect(x: textX, y: 78, width: textW, height: 16),
                 [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.white.withAlphaComponent(0.62)])
    }

    private func drawText(_ s: String, in rect: NSRect, _ attrs: [NSAttributedString.Key: Any]) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let full = attrs.merging([.paragraphStyle: para]) { _, new in new }
        NSAttributedString(string: s, attributes: full).draw(in: rect)
    }
}

/** 一张卡片 = 面板 + 内容视图 + 淡出定时器 + 贴靠开关。 */
final class CardEntry {
    let kind: String
    let panel: NSPanel
    let view: PermissionCardView
    var fadeItem: DispatchWorkItem?
    var followsSettings = true // 用户没手动挪过 → 自动贴靠系统设置窗口

    init(kind: String, panel: NSPanel, view: PermissionCardView) {
        self.kind = kind
        self.panel = panel
        self.view = view
    }
}

/**
 * 权限引导卡片控制器：按 kind 管理至多两张卡片（accessibility/screen），可并存、错位不重叠。
 * v1.0.0 新增两组常驻轮询（有卡片在屏才开，全收即停）：
 *   ① 贴靠跟随（150ms）：CGWindowListCopyWindowInfo 找系统设置窗口（无需任何权限），卡片
 *      水平居中于它、贴其下沿上叠 6px，设置窗移动卡片跟随；图标拖拽期间/用户手动挪卡后停止；
 *   ② 授权自动检测（1.2s）：AXIsProcessTrusted（不带 prompt）/ CGPreflightScreenCaptureAccess
 *      轮询，对应权限生效即自动隐藏该卡；卡片全数收起且 stdin 已 EOF → 进程自退（服务端下次
 *      请求自动从 .app 位置重启新实例 = 重读 TCC grant，用户零操作）。
 * 仅主线程调用（命令分发处保证）。失败安全：任何路径只影响自身卡片，不影响主命令循环。
 */
final class PermissionCardController {
    private var cards: [String: CardEntry] = [:]
    private var exitAfterCardsClose = false // stdin 已 EOF 但卡片还在：等最后一张收起再退进程
    private var followTimer: Timer?
    private var grantTimer: Timer?
    private var freezeFollow = false // 图标文件拖拽进行中：冻结贴靠（防卡片追着鼠标跑）

    var hasVisibleCards: Bool { !cards.isEmpty }

    /** 显示（同 kind 已在屏则就地更新文案并重置淡出计时，保留用户拖过的位置）。 */
    func show(kind: String, appName: String, durationSec: Int, dragURL: URL?) -> [String: Any] {
        if let entry = cards[kind] {
            entry.view.appName = appName
            scheduleFade(entry, durationSec)
            syncWatchers()
            return reply(entry, durationSec: durationSec)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: CARD_W, height: CARD_H),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating // 盖在系统设置等普通窗口上方（比幽灵光标低两层：引导不必压系统 UI）
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false // 本项目唯一可交互的叠加窗：它就是给用户操作的引导 UI
        panel.isMovableByWindowBackground = false // 整张卡片都可拖出 .app（拖动 = 授予权限，不是挪窗）；位置由贴靠跟随自动摆
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = PermissionCardView(frame: NSRect(x: 0, y: 0, width: CARD_W, height: CARD_H), kind: kind)
        view.appName = appName
        panel.contentView = view

        let icon = CardIconDragView(frame: NSRect(x: 18, y: (CARD_H - 72) / 2, width: 72, height: 72))
        icon.fileURL = dragURL
        icon.appIconImage = Bundle.main.bundleIdentifier != nil ? NSApp.applicationIconImage : nil
        dragLog("card shown kind=\(kind) drag=\(dragURL?.path ?? "nil") icon=\(icon.appIconImage == nil ? "drawn" : "app")")
        icon.onDragStateChange = { [weak self] on in self?.freezeFollow = on }
        view.addSubview(icon)
        let close = CardCloseButton(frame: NSRect(x: CARD_W - 30, y: 10, width: 20, height: 20))
        view.addSubview(close)

        let entry = CardEntry(kind: kind, panel: panel, view: view)
        view.onUserMove = { [weak self, weak view] in
            guard let self, let view else { return }
            self.cards[view.kind]?.followsSettings = false // 用户接管位置：这张卡停止贴靠
        }
        close.onClick = { [weak self] in
            self?.hide(kind: kind)
            self?.exitIfDone()
        }
        cards[kind] = entry

        // 初始兜底位（无系统设置窗时停留于此）：主屏中央偏右；screen 卡在 accessibility 卡下方错开
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let slot: CGFloat = kind == "accessibility" ? 0 : 1
        let x = vis.midX + vis.width * 0.12 - CARD_W / 2
        let y = vis.midY + 34 - slot * (CARD_H + CARD_GAP) - CARD_H / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless() // 显示但绝不 activate（不抢系统设置的焦点）
        scheduleFade(entry, durationSec)
        syncWatchers()
        repositionCards() // 系统设置窗已开则立即贴上去（不等第一个 150ms 节拍）
        return reply(entry, durationSec: durationSec)
    }

    /** 立即隐藏（幂等；未显示的 kind 静默 ok）。 */
    func hide(kind: String) {
        guard let entry = cards[kind] else { return }
        entry.fadeItem?.cancel()
        entry.fadeItem = nil
        cards[kind] = nil
        entry.panel.orderOut(nil)
        syncWatchers()
    }

    /** stdin EOF 时的退出决策：无卡片立即退（旧行为）；有卡片留守，收齐后由 exitIfDone 收尾。 */
    func noteStdinClosed() {
        if cards.isEmpty {
            NSApp.terminate(nil)
        } else {
            exitAfterCardsClose = true
        }
    }

    /** 卡片全数收起后（且 stdin 已 EOF）退出进程。 */
    func exitIfDone() {
        guard exitAfterCardsClose, cards.isEmpty else { return }
        exitAfterCardsClose = false
        stopWatchers()
        NSApp.terminate(nil)
    }

    // ---- 贴靠跟随（150ms 轮询；窗口清单本身无需任何授权） ----

    /** 系统设置窗口（屏上、常规层、bundleId 匹配者中面积最大）；无则 nil。 */
    private func systemSettingsWindow() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
          as? [[String: Any]] else { return nil }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
            let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
            guard layer == 0, pid > 0 else { continue }
            guard NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == SETTINGS_BUNDLE_ID else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let r = CGRect(x: (b["X"] as? Double) ?? 0, y: (b["Y"] as? Double) ?? 0,
                           width: (b["Width"] as? Double) ?? 0, height: (b["Height"] as? Double) ?? 0)
            let area = r.width * r.height
            if area > bestArea { bestArea = area; best = r }
        }
        return best
    }

    /** 按 kind 重摆所有「未被动过」的卡片：水平居中于设置窗、贴其下沿上叠 6px（screen 卡再下移错开）。 */
    private func repositionCards() {
        guard !freezeFollow else { return }
        guard let s = systemSettingsWindow() else { return } // 无设置窗：停在兜底位
        let mainMaxY = NSScreen.main?.frame.maxY ?? 0
        for kind in ["accessibility", "screen"] {
            guard let entry = cards[kind], entry.followsSettings else { continue }
            let slot: CGFloat = kind == "accessibility" ? 0 : 1
            let cgTopLeftY = s.maxY - 6 // 贴设置窗下沿，上叠 6px（CG 左上原点）
            let originY = mainMaxY - cgTopLeftY - CARD_H - slot * (CARD_H + CARD_GAP) // → AppKit 左下原点
            var f = NSRect(x: s.midX - CARD_W / 2, y: originY, width: CARD_W, height: CARD_H)
            f = clampToVisibleFrame(f, settings: s, mainMaxY: mainMaxY)
            entry.panel.setFrameOrigin(f.origin)
        }
    }

    /** 夹进设置窗所在显示器的工作区（防多屏/贴边时卡片出屏）。 */
    private func clampToVisibleFrame(_ f: NSRect, settings s: CGRect, mainMaxY: CGFloat) -> NSRect {
        let centerAppKit = NSPoint(x: s.midX, y: mainMaxY - s.midY) // CG → AppKit 纵轴换算
        let screen = NSScreen.screens.first { NSPointInRect(centerAppKit, $0.frame) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame, vis.width >= f.width else { return f }
        var r = f
        r.origin.x = min(max(r.origin.x, vis.minX), vis.maxX - r.width)
        r.origin.y = min(max(r.origin.y, vis.minY), vis.maxY - r.height)
        return r
    }

    // ---- 授权自动检测（1.2s 轮询；状态查询一律不带 prompt） ----

    private func checkGrants() {
        var granted: [String] = []
        if cards["accessibility"] != nil, axTrusted() { granted.append("accessibility") }
        if cards["screen"] != nil, CGPreflightScreenCaptureAccess() { granted.append("screen") }
        for k in granted { hide(kind: k) } // 权限生效 → 对应卡片使命完成，自动收起
        if !granted.isEmpty { exitIfDone() } // 非交互留卡场景：全收齐即自退（服务端下次请求自动重启）
    }

    // ---- 轮询的启停（有卡才转，无卡全停） ----

    private func syncWatchers() {
        if cards.isEmpty {
            stopWatchers()
            return
        }
        if followTimer == nil {
            followTimer = Timer.scheduledTimer(withTimeInterval: CARD_FOLLOW_INTERVAL, repeats: true) { [weak self] _ in
                self?.repositionCards()
            }
        }
        if grantTimer == nil {
            grantTimer = Timer.scheduledTimer(withTimeInterval: CARD_GRANT_WATCH_INTERVAL, repeats: true) { [weak self] _ in
                self?.checkGrants()
            }
        }
    }

    private func stopWatchers() {
        followTimer?.invalidate()
        followTimer = nil
        grantTimer?.invalidate()
        grantTimer = nil
    }

    private func scheduleFade(_ entry: CardEntry, _ durationSec: Int) {
        entry.fadeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.cards[entry.kind] != nil else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                entry.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                if self.cards[entry.kind] != nil {
                    self.cards[entry.kind] = nil
                    entry.panel.orderOut(nil)
                    entry.panel.alphaValue = 1 // 下次重建时从全不透明起步
                }
                self.syncWatchers()
                self.exitIfDone()
            })
        }
        entry.fadeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(durationSec), execute: item)
    }

    /** 应答数据：frame 换算成屏幕左上原点（与 windows/overlay 的 CG 坐标系一致）。 */
    private func reply(_ entry: CardEntry, durationSec: Int) -> [String: Any] {
        let f = entry.panel.frame
        let topY = (NSScreen.main?.frame.maxY ?? f.maxY) - f.maxY
        var out: [String: Any] = [
            "kind": entry.kind,
            "autoHideSec": durationSec,
            "frame": ["x": f.minX, "y": topY, "w": f.width, "h": f.height],
        ]
        if let url = entry.view.subviews.compactMap({ ($0 as? CardIconDragView)?.fileURL }).first {
            out["dragFrom"] = url.path
        }
        return out
    }
}

let permissionCards = PermissionCardController()

func cmdShowPermissionCard(_ id: Any?, _ p: [String: Any]) {
    guard let kind = p["kind"] as? String, kind == "accessibility" || kind == "screen" else {
        respondErr(id, "show-permission-card 的 kind 需为 accessibility 或 screen", code: "bad-kind")
        return
    }
    let appName = (p["appName"] as? String) ?? ""
    var durationSec = p["durationSec"] as? Int ?? 120
    if durationSec < 5 { durationSec = 5 }
    if durationSec > 600 { durationSec = 600 }
    DispatchQueue.main.async { // 窗口操作必须在主线程（run loop 上）
        let dragURL = responsibleAppBundleURL()
        respondOk(id, permissionCards.show(kind: kind, appName: appName, durationSec: durationSec, dragURL: dragURL))
    }
}

func cmdHidePermissionCard(_ id: Any?, _ p: [String: Any]) {
    let kind = (p["kind"] as? String) ?? ""
    DispatchQueue.main.async {
        if !kind.isEmpty { permissionCards.hide(kind: kind) } // 未知 kind 幂等 ok
        permissionCards.exitIfDone()
        respondOk(id, [:])
    }
}

// ---------- 主循环（主线程跑 AppKit run loop；stdin 移后台队列逐行读） ----------

/** 解析并执行一行请求；overlay/permission-card 命令切主线程执行，其余在读取线程内联完成（与旧版行为一致）。 */
func handleLine(_ line: String) {
    guard let data = line.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        respondErr(nil, "请求不是合法 JSON 对象（需要单行 {id, cmd, ...}）", code: "bad-request")
        return
    }
    let id = obj["id"]
    guard let cmd = obj["cmd"] as? String else {
        respondErr(id, "缺少 cmd 字段", code: "bad-request")
        return
    }
    switch cmd {
    case "probe": cmdProbe(id, obj)
    case "request-permissions": cmdRequestPermissions(id, obj)
    case "windows": cmdWindows(id, obj)
    case "ax-tree": cmdAxTree(id, obj)
    case "ax-hit": cmdAxHit(id, obj)
    case "element-click": cmdElementClick(id, obj)
    case "set-value": cmdSetValue(id, obj)
    case "perform-action": cmdPerformAction(id, obj)
    case "select-text": cmdSelectText(id, obj)
    case "paste": cmdPaste(id, obj)
    case "scroll": cmdScroll(id, obj)
    case "drag": cmdDrag(id, obj)
    case "xy-click": cmdXyClick(id, obj)
    case "type": cmdType(id, obj)
    case "key": cmdKey(id, obj)
    case "app-focus": cmdAppFocus(id, obj)
    case "release-focus": cmdReleaseFocus(id)
    case "overlay-show": cmdOverlayShow(id, obj)
    case "overlay-hide": cmdOverlayHide(id)
    case "pip-stats": cmdPipStats(id)
    case "show-permission-card": cmdShowPermissionCard(id, obj)
    case "hide-permission-card": cmdHidePermissionCard(id, obj)
    default: respondErr(id, "未知命令: \(cmd)", code: "unknown-cmd")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // 无 Dock 图标；叠加窗 orderFrontRegardless 显示、绝不 activate

/** 进程被服务端 SIGTERM 收掉时先撤销合成激活，避免目标应用停在“以为自己在前台”的状态。 */
func installSyntheticFocusSignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            releaseSyntheticFocus()
            exit(0)
        }
        source.resume()
        syntheticFocusSignalSources.append(source)
    }
}
installSyntheticFocusSignalHandlers()

DispatchQueue.global(qos: .userInitiated).async {
    while let line = readLine() {
        autoreleasepool { handleLine(line) }
    }
    releaseSyntheticFocus() // stdin 关闭：撤销合成激活后再退出
    // stdin EOF：结束主线程 run loop（terminate），保持旧版「管道关闭即退出」的行为；
    // 权限引导卡片还在屏上时留守到卡片全数收起（setup 非交互留卡场景，寿命最长 600s）
    DispatchQueue.main.async { permissionCards.noteStdinClosed() }
}

app.run()
// run() 在 terminate 后返回，进程随之退出（退出码 0，与旧版一致）
