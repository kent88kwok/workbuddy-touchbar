// WorkBuddyTouchBar — Touch Bar 常驻显示 WorkBuddy 任务状态与积分
// 数据源:
//  1. ~/.workbuddy/workbuddy.db (sessions / session_usage)  — 任务列表/上下文/积分消耗
//  2. ~/.workbuddy/sessions/*.json                          — 会话心跳 (判断运行中)
//  3. ~/.workbuddy/wbipc/endpoint.json → wb.request/http.fetch — 账号总积分(宿主登录态)

import AppKit
import CryptoKit
import Darwin
import SQLite3

// MARK: - 诊断日志

enum WbLog {
    static let path = "/tmp/WorkBuddyTouchBar.log"
    static func write(_ s: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + s + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - TouchBar 系统 tray SPI (未在 SDK 头文件声明, 走 ObjC runtime)

private let _addTraySel = NSSelectorFromString("addSystemTrayItem:")
private let _removeTraySel = NSSelectorFromString("removeSystemTrayItem:")

private let _msgSend_tray: @convention(c) (AnyObject, Selector, AnyObject) -> Void = {
    let sym = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    return unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Void).self)
}()

/// 系统 Touch Bar 常驻区 (control strip) 是否可用。macOS 27 起 AppKit 已移除 NSTouchBar* 全部类与 SPI。
enum TouchBarSupport {
    static let hasClasses = NSClassFromString("NSCustomTouchBarItem") != nil
        && NSClassFromString("NSTouchBarItem") != nil
    static let hasTraySPI = (NSClassFromString("NSTouchBarItem") as AnyObject?)
        .map { $0.responds(to: NSSelectorFromString("addSystemTrayItem:")) } ?? false
    static var available: Bool { hasClasses && hasTraySPI }
    static var diagnosis: String {
        if available { return "可用" }
        if !hasClasses { return "不可用 (macOS 已移除 NSTouchBar 类)" }
        return "不可用 (无 addSystemTrayItem SPI)"
    }
}

func addSystemTrayItem(_ item: NSObject) {
    guard TouchBarSupport.hasTraySPI,
          let cls = NSClassFromString("NSTouchBarItem") as AnyObject?, cls.responds(to: _addTraySel) else { return }
    _msgSend_tray(cls, _addTraySel, item)
}

func removeSystemTrayItem(_ item: NSObject) {
    guard TouchBarSupport.hasTraySPI,
          let cls = NSClassFromString("NSTouchBarItem") as AnyObject?, cls.responds(to: _removeTraySel) else { return }
    _msgSend_tray(cls, _removeTraySel, item)
}

// MARK: - Pock 式全屏 modal SPI
//
// 来源: Pock 的 Pock/Private/ApplePrivate.h + TouchBarHelper.swift
//    + (void)presentSystemModalTouchBar:(NSTouchBar *)tb placement:(long long)p systemTrayItemIdentifier:(NSString *)id;
//    + (void)dismissSystemModalTouchBar:(NSTouchBar *)tb;
// 注意这是 **NSTouchBar 的类方法**（不是 NSTouchBarController 的实例方法）。
// 与 tray item 的本质区别: tray 是"挤进"控制条右侧一个小格（空间受限、易被挤掉），
// modal 是"接管整条 Touch Bar" —— 这正是 Pock 能常驻并显示 Dock 的原因，也是我们要走的路线。

private let _presentModalSel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
private let _dismissModalSel = NSSelectorFromString("dismissSystemModalTouchBar:")

/// objc_msgSend(obj, sel, NSTouchBar*, long long, NSString*) —— Swift 里直接调用会 IRGen 崩溃, 必须 dlsym
private let _msgSend_modal5: @convention(c) (AnyObject, Selector, AnyObject?, Int64, AnyObject?) -> Void = {
    let sym = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    return unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, AnyObject?, Int64, AnyObject?) -> Void).self)
}()

private let _msgSend_modal1: @convention(c) (AnyObject, Selector, AnyObject?) -> Void = {
    let sym = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")
    return unsafeBitCast(sym, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self)
}()

enum PockModalSupport {
    private static var cls: AnyObject? { NSClassFromString("NSTouchBar") as AnyObject? }
    static var hasPresent: Bool { cls.map { $0.responds(to: _presentModalSel) } ?? false }
    static var hasDismiss: Bool { cls.map { $0.responds(to: _dismissModalSel) } ?? false }
    static var available: Bool { hasPresent && hasDismiss }
    static var diagnosis: String {
        if available { return "可用" }
        if hasPresent { return "部分可用 (无 dismiss)" }
        return "不可用 (无 presentSystemModalTouchBar)"
    }
}

/// 全屏接管 Touch Bar 显示 bar (placement=1, 与 Pock 同款)
func presentPockModal(_ bar: NSObject) {
    guard let cls = NSClassFromString("NSTouchBar") as AnyObject?, cls.responds(to: _presentModalSel) else { return }
    _msgSend_modal5(cls, _presentModalSel, bar, 1, nil)
}

func dismissPockModal(_ bar: NSObject) {
    guard let cls = NSClassFromString("NSTouchBar") as AnyObject?, cls.responds(to: _dismissModalSel) else { return }
    _msgSend_modal1(cls, _dismissModalSel, bar)
}

// MARK: - 配置

let kWorkbuddyDir = NSString(string: "~/.workbuddy").expandingTildeInPath
let kDbPath = kWorkbuddyDir + "/workbuddy.db"
let kSessionsDir = kWorkbuddyDir + "/sessions"
let kEndpointJson = kWorkbuddyDir + "/wbipc/endpoint.json"
let kHeartbeatFreshSec: TimeInterval = 300   // 心跳 5 分钟内视为活跃会话
let kLocalPollSec: TimeInterval = 3          // 本地任务轮询
let kCloudPollSec: TimeInterval = 30         // 云端积分轮询
let kSnapshotPath = "/tmp/wb-touchbar-state.json"   // 状态快照 (供 BTT widget 秒级读取)
let kSnapshotMaxAge: TimeInterval = 300      // 快照超过 5 分钟视为过期

// MARK: - 数据模型

struct TaskInfo {
    var id: String
    var title: String
    var status: String
    var used: Int        // 上下文已用
    var size: Int        // 上下文总量
    var credits: Double  // 本任务累计积分
    var isActive: Bool   // 心跳活跃
}

struct AccountCredits {
    var remain: Double
    var total: Double
}

final class DataStore {
    static let shared = DataStore()
    private var db: OpaquePointer?

    private func openDb() -> Bool {
        if db != nil { return true }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(kDbPath, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            if handle != nil { sqlite3_close(handle) }
            return false
        }
        db = handle
        return true
    }

    func loadTasks() -> [TaskInfo] {
        guard openDb() else { return [] }
        // 心跳活跃的 sessionId 集合
        var activeIds = Set<String>()
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: kSessionsDir) {
            let now = Date().timeIntervalSince1970 * 1000
            for f in entries where f.hasSuffix(".json") {
                let path = kSessionsDir + "/" + f
                guard let data = FileManager.default.contents(atPath: path),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = obj["sessionId"] as? String,
                      let hb = obj["lastHeartbeat"] as? Double else { continue }
                if now - hb < kHeartbeatFreshSec * 1000 { activeIds.insert(sid) }
            }
        }

        var tasks: [TaskInfo] = []
        let sql = """
        SELECT s.id, COALESCE(s.custom_title, s.title, ''), s.status, u.used, u.size, u.credit_json
        FROM sessions s LEFT JOIN session_usage u ON u.session_id = s.id
        WHERE s.deleted_at IS NULL OR s.deleted_at = -1
        ORDER BY s.updated_at DESC LIMIT 40;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let status = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let used = sqlite3_column_int64(stmt, 3)
            let size = sqlite3_column_int64(stmt, 4)
            var credits = 0.0
            if let cj = sqlite3_column_text(stmt, 5) {
                let raw = String(cString: cj)
                if let data = raw.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
                    credits = dict.values.reduce(0, +)
                }
            }
            tasks.append(TaskInfo(id: id, title: title, status: status,
                                  used: Int(used), size: Int(size),
                                  credits: credits,
                                  isActive: status == "working" || activeIds.contains(id)))
        }
        return tasks
    }
}

// MARK: - 状态快照 (常驻 App 写盘; BTT widget / 离线预览 秒级读取)

struct Snapshot {
    var ts: Double = 0            // unix 秒
    var activeCount = 0
    var ctxPct: Int = -1          // -1 = 未知
    var sessionCredits = 0.0
    var remain: Double = -1       // -1 = 未知
    var total: Double = -1
    var cloudOK = false
    var taskTitle = ""
    var taskStatus = ""

    var fmtCredits: String { String(format: "%.1f", sessionCredits) }
    var fmtRemain: String { remain < 0 ? "?" : String(format: "%.0f", remain) }

    /// 常驻条一行文本: ▶1 29% ⚡44.3 ✦2246
    var oneLine: String {
        var t: String
        if activeCount == 0 {
            t = remain < 0 ? "WB—" : "WB ✓"
        } else {
            t = "▶\(activeCount)"
            if ctxPct >= 0 { t += " \(ctxPct)%" }
            t += " ⚡\(fmtCredits)"
        }
        t += " ✦\(fmtRemain)"
        return t
    }

    func dict() -> [String: Any] {
        ["ts": ts, "activeCount": activeCount, "ctxPct": ctxPct,
         "sessionCredits": sessionCredits, "remain": remain, "total": total,
         "cloudOK": cloudOK, "taskTitle": taskTitle, "taskStatus": taskStatus]
    }

    static func from(_ o: [String: Any]) -> Snapshot {
        var s = Snapshot()
        s.ts = o["ts"] as? Double ?? 0
        s.activeCount = o["activeCount"] as? Int ?? 0
        s.ctxPct = o["ctxPct"] as? Int ?? -1
        s.sessionCredits = o["sessionCredits"] as? Double ?? 0
        s.remain = o["remain"] as? Double ?? -1
        s.total = o["total"] as? Double ?? -1
        s.cloudOK = o["cloudOK"] as? Bool ?? false
        s.taskTitle = o["taskTitle"] as? String ?? ""
        s.taskStatus = o["taskStatus"] as? String ?? ""
        return s
    }

    func write() {
        if let d = try? JSONSerialization.data(withJSONObject: dict(), options: [.sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: kSnapshotPath))
        }
    }

    static func loadFresh() -> Snapshot? {
        guard let d = FileManager.default.contents(atPath: kSnapshotPath),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let s = Self.from(o)
        guard Date().timeIntervalSince1970 - s.ts <= kSnapshotMaxAge else { return nil }
        return s
    }

    /// 常驻 App 没在跑时的兜底: 现算本地部分 (云端积分不可用)
    static func computeLocal() -> Snapshot {
        var s = Snapshot()
        s.ts = Date().timeIntervalSince1970
        let active = DataStore.shared.loadTasks().filter { $0.isActive }
        s.activeCount = active.count
        if let f = active.first {
            s.ctxPct = f.size > 0 ? Int(round(Double(f.used) / Double(f.size) * 100)) : -1
            s.taskTitle = f.title
            s.taskStatus = f.status
        }
        s.sessionCredits = active.reduce(0.0) { $0 + $1.credits }
        return s
    }
}

/// 优先用常驻 App 写的快照(含云端积分), 过期则现算
func wbSnapshot() -> Snapshot {
    Snapshot.loadFresh() ?? Snapshot.computeLocal()
}

// MARK: - wbipc 客户端 (账号积分)

enum WbipcError: Error { case noEndpoint, socketFailed(String), handshake(String), rpc(String) }

final class WbipcClient {
    // 握手 transcript: 长度前缀(4B BE)拼接 ["wbipc-c", "1", endpoint, clientNonce, serverNonce]
    private static func transcript(role: String, protocolVersion: Int, endpoint: String,
                                   clientNonce: String, serverNonce: String) -> Data {
        let roleTag = role == "server" ? "wbipc-s" : "wbipc-c"
        let parts = [roleTag, String(protocolVersion), endpoint, clientNonce, serverNonce]
        var out = Data()
        for p in parts {
            let b = Data(p.utf8)
            var len = UInt32(b.count).bigEndian
            out.append(Data(bytes: &len, count: 4))
            out.append(b)
        }
        return out
    }

    private static func proof(ticket: String, role: String, tr: (Int, String, String, String)) -> String {
        let key = SymmetricKey(data: Data(ticket.utf8))
        let data = transcript(role: role, protocolVersion: tr.0, endpoint: tr.1,
                              clientNonce: tr.2, serverNonce: tr.3)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return base64url(Data(mac))
    }

    private static func base64url(_ d: Data) -> String {
        var s = d.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return s
    }

    private static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// 同步请求账号积分（在后台线程调用）
    static func fetchCredits() -> Result<AccountCredits, WbipcError> {
        guard let raw = FileManager.default.contents(atPath: kEndpointJson),
              let cfg = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let endpoint = cfg["endpoint"] as? String,
              let ticket = cfg["ticket"] as? String else {
            return .failure(WbipcError.noEndpoint)
        }

        // --- 连接 unix socket ---
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.socketFailed("socket() failed")) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(endpoint.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            return .failure(.socketFailed("path too long"))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .failure(.socketFailed("connect failed")) }

        func sendFrame(_ obj: [String: Any]) -> Bool {
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
            var payload = data
            payload.append(0x0A)
            return payload.withUnsafeBytes { raw -> Bool in
                write(fd, raw.baseAddress, raw.count) == raw.count
            }
        }

        func readLine() -> Data? {
            var buf = [UInt8](repeating: 0, count: 1)
            var line = Data()
            while true {
                let n = read(fd, &buf, 1)
                if n <= 0 { return nil }
                if buf[0] == 0x0A { return line }
                line.append(buf[0])
                if line.count > 1_048_576 { return nil }
            }
        }
        func readJson() -> [String: Any]? {
            guard let line = readLine(),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            return obj
        }

        let clientNonce = base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let ticketId = Data(SHA256.hash(data: Data(ticket.utf8)))
            .map { String(format: "%02x", $0) }.joined().prefix(16)

        // --- 1. hello ---
        guard sendFrame(["type": "session_hello",
                         "protocol_min": 1, "protocol_max": 1,
                         "client_nonce": clientNonce,
                         "ticket_id": String(ticketId),
                         "client": ["kind": "app", "id": "wb-touchbar", "version": "1.0.0"]]),
              let challenge = readJson(),
              challenge["type"] as? String == "session_challenge",
              let serverNonce = challenge["server_nonce"] as? String,
              let serverProof = challenge["server_proof"] as? String else {
            return .failure(.handshake("hello failed"))
        }

        // --- 2. 验证服务端证明 ---
        let tr = (1, endpoint, clientNonce, serverNonce)
        guard proof(ticket: ticket, role: "server", tr: tr) == serverProof else {
            return .failure(.handshake("server proof mismatch"))
        }

        // --- 3. 自证 ---
        guard sendFrame(["type": "session_prove",
                         "client_proof": proof(ticket: ticket, role: "client", tr: tr)]),
              let ack = readJson(),
              ack["type"] as? String == "session_hello_ack" else {
            return .failure(.handshake("prove failed"))
        }

        // --- 4. GetPipe ---
        guard sendFrame(["jsonrpc": "2.0", "id": 1,
                         "method": "broker/GetPipe", "params": ["pipe": "wb.request"]]),
              let pipeRes = readJson(), pipeRes["id"] as? Int == 1,
              pipeRes["result"] != nil else {
            return .failure(.rpc("GetPipe failed"))
        }

        // --- 5. http.fetch 调积分接口 ---
        let body = Data("{}".utf8).base64EncodedString()
        guard sendFrame(["jsonrpc": "2.0", "id": 2, "mode": "call",
                         "method": "c:wb.request/http.fetch",
                         "params": ["method": "POST",
                                    "path": "/billing/meter/get-user-resource-summary",
                                    "headers": ["content-type": "application/json"],
                                    "body_b64": body]]) else {
            return .failure(.rpc("fetch send failed"))
        }
        // 循环读帧直到拿到 id=2
        var credits: AccountCredits?
        for _ in 0..<10 {
            guard let frame = readJson() else { break }
            if frame["id"] as? Int == 2 {
                if let result = frame["result"] as? [String: Any],
                   let status = result["status"] as? Int, status == 200,
                   let b64 = result["body_b64"] as? String,
                   let bodyData = b64urlDecode(b64),
                   let payload = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                   (payload["code"] as? Int) == 0,
                   let data = payload["data"] as? [String: Any],
                   let packages = data["Packages"] as? [[String: Any]] {
                    var remain = 0.0, total = 0.0
                    for p in packages {
                        remain += Double(p["CycleRemainCapacity"] as? String ?? "0") ?? 0
                        total += Double(p["CycleTotalCapacity"] as? String ?? "0") ?? 0
                    }
                    credits = AccountCredits(remain: remain, total: total)
                }
                break
            }
        }
        guard let c = credits else { return .failure(.rpc("bad credits payload")) }
        return .success(c)
    }
}

// MARK: - 触控栏

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var trayItem: NSObject?                    // 常驻 control strip (运行时构造)
    var trayButton: NSButton?
    var pockBar: NSObject?                     // Pock 式全屏 modal bar (接管整条 Touch Bar)
    var pockStatusField: NSTextField?          // 全屏条上的主状态文本
    var pockTitleField: NSTextField?           // 全屏条上的当前任务标题
    var detailBarRef: NSObject?                // 详情条 (只构建一次)
    var detailTaskFields: [NSTextField] = []   // 详情条的任务槽位
    var detailCreditField: NSTextField?        // 详情条的账号行
    var pockMode = true                        // 默认走 Pock 式接管
    var lastText = "WB…"
    var lastTitle = ""
    var timer: Timer?
    var cloudTimer: Timer?
    var keepAliveTimer: Timer?
    var accountCredits: AccountCredits?
    var cloudError = false
    var trayVisible = true
    var loggedOnce = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pockMode = UserDefaults.standard.object(forKey: "pockMode") as? Bool ?? true
        WbLog.write("启动 | tray=\(TouchBarSupport.diagnosis)(hasTraySPI=\(TouchBarSupport.hasTraySPI)) | pockModal=\(PockModalSupport.diagnosis)(hasPresent=\(PockModalSupport.hasPresent))")
        setupStatusItem()
        WbLog.write("② 菜单栏就绪")
        scheduleTrayAttach()   // 延迟+重试挂载 (启动期直接挂会与系统 TouchBarServer 死锁)
        schedulePockAttach()
        startKeepAlive()
        refreshLocal()
        timer = Timer.scheduledTimer(withTimeInterval: kLocalPollSec, repeats: true) { [weak self] _ in
            self?.refreshLocal()
        }
        cloudTimer = Timer.scheduledTimer(withTimeInterval: kCloudPollSec, repeats: true) { [weak self] _ in
            self?.refreshCloud()
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refreshCloud() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dismissPockBar()
        if let item = trayItem { removeSystemTrayItem(item) }
    }

    // MARK: 菜单栏

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡WB"
        let menu = NSMenu()
        menu.delegate = self

        let pkItem = menu.addItem(withTitle: "Pock 式全屏接管: \(PockModalSupport.diagnosis)",
                                  action: #selector(togglePock), keyEquivalent: "")
        pkItem.target = self
        pkItem.isEnabled = PockModalSupport.available
        pkItem.state = pockMode ? .on : .off

        let tbItem = menu.addItem(withTitle: "控制条小件(备用): \(TouchBarSupport.diagnosis)",
                                  action: #selector(toggleTray), keyEquivalent: "")
        tbItem.target = self
        tbItem.isEnabled = TouchBarSupport.available
        tbItem.state = trayVisible ? .on : .off

        menu.addItem(withTitle: "立即刷新", action: #selector(forceRefresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "复制 BTT 桥接命令", action: #selector(copyBttCommand), keyEquivalent: "").target = self
        menu.addItem(withTitle: "生成 Touch Bar 预览图", action: #selector(makePreview), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        let auto = menu.addItem(withTitle: "开机自启动", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = autoStartEnabled ? .on : .off
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func toggleTray() {
        trayVisible.toggle()
        if trayVisible { attachTrayItem() }
        else if let item = trayItem { removeSystemTrayItem(item) }
    }

    // MARK: Pock 式全屏常驻 (接管整条 Touch Bar)

    @objc func togglePock() {
        pockMode.toggle()
        UserDefaults.standard.set(pockMode, forKey: "pockMode")
        if pockMode { presentPockBar() } else { dismissPockBar() }
    }

    /// 启动期直接呈现会与系统 TouchBarServer 死锁 → 延后呈现。
    /// 注意: 只呈现, **不重建**。实测反复 rebuild+dismiss 会让系统侧
    /// NSTouchBarItemContainerView 在 autorelease pool 回收时二次释放 → SIGSEGV。
    func schedulePockAttach() {
        guard PockModalSupport.available else {
            WbLog.write("Pock modal 不可用, 跳过: \(PockModalSupport.diagnosis)")
            return
        }
        for delay in [1.5, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pockMode else { return }
                self.presentPockBar()
            }
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, color: NSColor,
                           weight: NSFont.Weight = .semibold) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        tf.textColor = color
        tf.sizeToFit()
        return tf
    }

    /// 构建全屏条: [状态] [当前任务] [详情▸] [✕]
    private func buildPockBar() -> NSObject? {
        guard let barCls = NSClassFromString("NSTouchBar") as? NSObject.Type else { return nil }
        let bar = barCls.init()
        var items: [NSObject] = []
        var ids: [String] = []

        let status = makeLabel(lastText, size: 16, color: .white)
        pockStatusField = status
        if let it = makeCustomItem(id: "p.status", view: status) { items.append(it); ids.append("p.status") }

        let title = makeLabel(lastTitle, size: 12, color: .secondaryLabelColor, weight: .regular)
        pockTitleField = title
        if let it = makeCustomItem(id: "p.title", view: title) { items.append(it); ids.append("p.title") }

        let detail = NSButton(title: "详情 ▸", target: self, action: #selector(pockDetailTapped(_:)))
        detail.bezelStyle = .rounded
        detail.controlSize = .small
        if let it = makeCustomItem(id: "p.detail", view: detail) { items.append(it); ids.append("p.detail") }

        let hide = NSButton(title: "✕", target: self, action: #selector(pockHide(_:)))
        hide.bezelStyle = .rounded
        hide.controlSize = .small
        if let it = makeCustomItem(id: "p.hide", view: hide) { items.append(it); ids.append("p.hide") }

        bar.perform(NSSelectorFromString("setTemplateItems:"), with: NSSet(array: items))
        bar.perform(NSSelectorFromString("setDefaultItemIdentifiers:"), with: ids as NSArray)
        return bar
    }

    /// 呈现全屏条。**bar 只构建一次并长期持有**（参照 Pock: 它从不重建 bar，
    /// 只更新 item 内 view 的内容），重复调用 = 重复 present 同一个对象, 幂等且安全。
    @discardableResult
    func presentPockBar(quiet: Bool = false) -> Bool {
        guard PockModalSupport.available else { return false }
        var reused = true
        if pockBar == nil {
            guard let bar = buildPockBar() else {
                WbLog.write("Pock! NSTouchBar 构造失败")
                return false
            }
            pockBar = bar
            reused = false
        }
        guard let bar = pockBar else { return false }
        presentPockModal(bar)
        if !quiet {
            WbLog.write("Pock-e 全屏条已呈现 (placement=1, \(reused ? "复用" : "新建")) | \(lastText)")
        }
        return true
    }

    /// 保活: 系统在切换前台 App 等情况可能收起 modal bar。
    /// Pock 的做法是 swizzle `NSFunctionRow.markActiveFunctionRowsAsDimmed` 回调后重新呈现;
    /// 这里用等价的轻量做法 —— 定时复用同一个 bar 重新呈现 (不重建, 实测安全)。
    func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.pockMode, let bar = self.pockBar else { return }
            presentPockModal(bar)
            WbLog.write("Pock-keepalive 复用呈现 (存活中)")
        }
    }

    func dismissPockBar() {
        guard let old = pockBar else { return }
        dismissPockModal(old)
        pockStatusField = nil
        pockTitleField = nil
        // 注意: 不把 pockBar 置 nil —— 保留对象以便再次 present 时复用, 避免重建引发崩溃
        WbLog.write("Pock-f 全屏条已撤下 (对象保留)")
    }

    @objc func pockHide(_ sender: Any?) {
        pockMode = false
        UserDefaults.standard.set(false, forKey: "pockMode")
        dismissPockBar()
    }

    /// 详情: 切到详情条 (不 dismiss 主条, 两个 bar 都长期持有)
    @objc func pockDetailTapped(_ sender: Any?) {
        showDetail()
    }

    @objc func pockBack(_ sender: Any?) {
        presentPockBar()
    }

    /// 复制可直接粘进 BetterTouchTool Script Widget 的命令
    @objc func copyBttCommand() {
        let exe = Bundle.main.executablePath ?? "/Applications/WorkBuddyTouchBar.app/Contents/MacOS/WorkBuddyTouchBar"
        let cmd = exe + " --btt --slot main"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        WbLog.write("已复制 BTT 命令: \(cmd)")
        NSSound.beep()
    }

    /// 生成常驻条预览 PNG 并打开 (无需 Touch Bar 即可确认排版/宽度)
    @objc func makePreview() {
        let p = NSString(string: "~/Desktop/wb-touchbar-preview.png").expandingTildeInPath
        if renderTrayPreview(wbSnapshot(), to: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            NSSound.beep()
        }
    }

    @objc func forceRefresh() {
        refreshLocal()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.refreshCloud() }
    }

    // MARK: 开机自启动 (LaunchAgent 方案, 替换 macOS 13+ 的 SMAppService, 兼容 Monterey)

    private static let agentLabel = "local.user.workbuddy-touchbar"

    private var launchAgentPlistPath: String {
        NSString(string: "~/Library/LaunchAgents/\(Self.agentLabel).plist").expandingTildeInPath
    }

    private var autoStartEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }

    @objc func toggleAutoStart() {
        let path = launchAgentPlistPath
        let label = Self.agentLabel
        let runLaunchctl: (String) -> Void = { sub in
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            // load/unload 接 plist 路径, remove 接 label
            t.arguments = [sub, sub == "load" || sub == "unload" ? path : label]
            try? t.run()
            t.waitUntilExit()
        }
        if autoStartEnabled {
            runLaunchctl("remove")
            try? FileManager.default.removeItem(atPath: path)
            WbLog.write("开机自启动: 已关闭 (移除 LaunchAgent)")
        } else {
            let exe = Bundle.main.executablePath ?? "/Applications/WorkBuddyTouchBar.app/Contents/MacOS/WorkBuddyTouchBar"
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(exe)</string>
                </array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            do {
                let dir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try plist.write(toFile: path, atomically: true, encoding: .utf8)
                runLaunchctl("load")
                WbLog.write("开机自启动: 已开启 (LaunchAgent 已写入并加载)")
            } catch {
                NSSound.beep()
                WbLog.write("开机自启动: 写入失败 \(error)")
            }
        }
    }

    // MARK: TouchBar 常驻项 (全部走 runtime, 兼容类被移除的系统)

    private func makeCustomItem(id: String, view: NSView) -> NSObject? {
        guard let cls = NSClassFromString("NSCustomTouchBarItem") as? NSObject.Type else { return nil }
        // 规范构造: [[NSCustomTouchBarItem alloc] initWithIdentifier:]
        guard let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject,
              let item = alloc.perform(NSSelectorFromString("initWithIdentifier:"),
                                       with: NSString(string: id))?.takeRetainedValue() as? NSObject else { return nil }
        item.perform(NSSelectorFromString("setView:"), with: view)
        return item
    }

    /// 构造并挂载常驻项。幂等: 重复调用会先摘再挂 (用于系统侧重注册)
    @discardableResult
    func attachTrayItem() -> Bool {
        // Pock 式全屏条已接管整条 Touch Bar 时, 不再挂控制条小件 (避免两套并存互相干扰)
        guard !(pockMode && PockModalSupport.available) else { return false }
        guard TouchBarSupport.available else {
            WbLog.write("Touch Bar 不可用, 跳过常驻项: \(TouchBarSupport.diagnosis)")
            return false
        }
        if let old = trayItem { removeSystemTrayItem(old) }

        let button = NSButton(title: "WB…", target: self, action: #selector(trayTapped(_:)))
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        button.bezelStyle = .rounded
        button.controlSize = .small
        // 不在这里 sizeToFit: 否则宽度被钉死, 之后变长的文本会被裁掉。
        // 宽度交给 refreshLocal() 每次更新 title 后重新计算。

        guard let item = makeCustomItem(id: "com.kentkwok.wbtouchbar.tray", view: button) else {
            WbLog.write("TB! NSCustomTouchBarItem 构造失败")
            return false
        }
        // 提高可见优先级: 控制条空间不足时系统优先保留高优先级项 (默认 0)
        item.perform(NSSelectorFromString("setVisibilityPriority:"), with: NSNumber(value: 1000))
        trayItem = item
        trayButton = button
        addSystemTrayItem(item)
        WbLog.write("TB-d 常驻项已挂载 (id=com.kentkwok.wbtouchbar.tray, 宽≈\(Int(button.frame.width))pt, priority=1000)")
        return true
    }

    /// 启动期直接挂载会与 TouchBarServer 死锁 → 延后, 并多试几次让系统完成注册
    func scheduleTrayAttach() {
        for delay in [1.0, 3.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.trayVisible else { return }
                self.attachTrayItem()
                if delay == 1.0 { self.refreshLocal() }
            }
        }
    }

    @objc func trayTapped(_ sender: Any?) {
        showDetail()
    }

    /// 显示详情条 (与主条互切, 两个 bar 对象都长期持有, 不做 dismiss)
    func showDetail() {
        if detailBarRef == nil { detailBarRef = buildDetailBar() }
        guard let bar = detailBarRef else { return }
        refreshDetailBar()
        presentPockModal(bar)
    }

    /// 详情条: 固定槽位 (4 个任务 + 账号行 + 返回), **只构建一次**, 内容由 refreshDetailBar() 更新
    func buildDetailBar() -> NSObject? {
        guard let barCls = NSClassFromString("NSTouchBar") as? NSObject.Type else { return nil }
        let bar = barCls.init()
        var items: [NSObject] = []
        var ids: [String] = []

        detailTaskFields = []
        for i in 0..<4 {
            let tf = makeLabel("", size: 14, color: .systemGreen, weight: .regular)
            detailTaskFields.append(tf)
            if let item = makeCustomItem(id: "d.t\(i)", view: tf) { items.append(item); ids.append("d.t\(i)") }
        }
        let credit = makeLabel("", size: 14, color: .systemYellow, weight: .regular)
        detailCreditField = credit
        if let item = makeCustomItem(id: "d.credits", view: credit) { items.append(item); ids.append("d.credits") }

        let back = NSButton(title: "◂ 返回", target: self, action: #selector(pockBack(_:)))
        back.bezelStyle = .rounded
        back.controlSize = .small
        if let item = makeCustomItem(id: "d.back", view: back) { items.append(item); ids.append("d.back") }

        bar.perform(NSSelectorFromString("setTemplateItems:"), with: NSSet(array: items))
        bar.perform(NSSelectorFromString("setDefaultItemIdentifiers:"), with: ids as NSArray)
        refreshDetailBar()
        return bar
    }

    /// 就地更新详情条文本 (不重建 bar)
    func refreshDetailBar() {
        let active = DataStore.shared.loadTasks().filter { $0.isActive }
        if !active.isEmpty {
            for (i, tf) in detailTaskFields.enumerated() {
                guard i < active.count else { tf.stringValue = ""; continue }
                let t = active[i]
                let pct = t.size > 0 ? Int(round(Double(t.used) / Double(t.size) * 100)) : 0
                tf.stringValue = "▶\(i + 1) \(String(t.title.prefix(9))) \(pct)% ⚡\(String(format: "%.1f", t.credits))"
            }
        } else if let first = detailTaskFields.first {
            first.stringValue = "没有运行中的任务"
            for tf in detailTaskFields.dropFirst() { tf.stringValue = "" }
        }
        if let c = accountCredits {
            detailCreditField?.stringValue = "✦余 \(String(format: "%.0f", c.remain))/\(String(format: "%.0f", c.total))"
        } else {
            detailCreditField?.stringValue = cloudError ? "✦获取失败" : "✦加载中"
        }
    }

    @objc func closeDetail(_ sender: Any?) {
        dismissPockBar()
    }

    // MARK: 数据刷新

    func refreshLocal() {
        let tasks = DataStore.shared.loadTasks()
        let active = tasks.filter { $0.isActive }

        var snap = Snapshot()
        snap.ts = Date().timeIntervalSince1970
        snap.activeCount = active.count
        if let f = active.first {
            snap.ctxPct = f.size > 0 ? Int(round(Double(f.used) / Double(f.size) * 100)) : -1
            snap.taskTitle = f.title
            snap.taskStatus = f.status
        }
        snap.sessionCredits = active.reduce(0.0) { $0 + $1.credits }
        if let c = accountCredits {
            snap.remain = c.remain
            snap.total = c.total
            snap.cloudOK = true
        }
        snap.write()   // 落盘: 供 BTT widget / 离线预览秒级读取

        let text = snap.oneLine
        let sub: String
        if let first = active.first {
            sub = "\(String(first.title.prefix(18))) · ctx \(first.used / 1000)k/\(first.size / 1000)k"
        } else {
            sub = snap.remain < 0 ? "WorkBuddy 未运行或未登录" : "当前没有运行中的任务"
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastText = text
            self.lastTitle = sub
            self.trayButton?.title = text
            self.trayButton?.sizeToFit()   // 宽度跟随内容 (否则会被钉在初始宽度上)
            // 全屏条: 直接改文本字段, 不必重建 bar
            self.pockStatusField?.stringValue = text
            self.pockTitleField?.stringValue = sub
            if self.detailBarRef != nil { self.refreshDetailBar() }
            if self.loggedOnce < 3 {
                self.loggedOnce += 1
                WbLog.write("状态文本: \(text) | \(sub)")
            }
        }
    }

    func refreshCloud() {
        switch WbipcClient.fetchCredits() {
        case .success(let c):
            accountCredits = c
            if cloudError { WbLog.write("积分恢复: 剩余 \(c.remain)/\(c.total)") }
            cloudError = false
        case .failure(let e):
            if accountCredits == nil { cloudError = true }
            WbLog.write("积分获取失败: \(e)")
        }
        refreshLocal()
    }
}

// MARK: - 离线预览 (借鉴 agent-status-pock 的 render-test 思路: 没 Touch Bar 也能看渲染结果)

/// 按 Touch Bar control strip 的视觉(黑底白字 / 30pt 高)渲染常驻条, 导出 PNG
@discardableResult
func renderTrayPreview(_ s: Snapshot, to path: String) -> Bool {
    let text = s.oneLine
    let font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: text, attributes: attrs)
    let ts = str.size()
    let padX: CGFloat = 14
    let h: CGFloat = 30
    let w = ceil(ts.width) + padX * 2
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    str.draw(at: NSPoint(x: padX, y: (h - ts.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

/// 渲染「整条 Touch Bar 被接管」的样子 (黑底, 默认 1000pt 宽 ≈ 13" MBP 触控栏)
@discardableResult
func renderFullPreview(_ s: Snapshot, to path: String, width: CGFloat = 1000) -> Bool {
    let h: CGFloat = 30
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(width * scale), pixelsHigh: Int(h * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    rep.size = NSSize(width: width, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: h).fill()

    var x: CGFloat = 14
    func draw(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .semibold) {
        let f = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        let a = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color])
        let sz = a.size()
        a.draw(at: NSPoint(x: x, y: (h - sz.height) / 2))
        x += sz.width + 12
    }

    draw(s.oneLine, size: 16, color: .white)
    draw("│", size: 14, color: NSColor(white: 1, alpha: 0.25))
    let title = s.taskTitle.isEmpty
        ? "没有运行中的任务"
        : "\(String(s.taskTitle.prefix(18))) · ctx \(max(s.ctxPct, 0))%"
    draw(title, size: 12, color: NSColor(white: 0.75, alpha: 1), weight: .regular)

    // 右侧两个按钮 (与真实 bar 里的 NSButton 视觉近似)
    func button(_ label: String, rightEdge: CGFloat) -> CGFloat {
        let f = NSFont.systemFont(ofSize: 12, weight: .medium)
        let a = NSAttributedString(string: label, attributes: [.font: f, .foregroundColor: NSColor.white])
        let sz = a.size()
        let bw = sz.width + 18
        let rect = NSRect(x: rightEdge - bw, y: (h - 20) / 2, width: bw, height: 20)
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        a.draw(at: NSPoint(x: rect.minX + 9, y: rect.minY + (20 - sz.height) / 2))
        return rect.minX - 10
    }
    var right = width - 14
    right = button("✕", rightEdge: right)
    _ = button("详情 ▸", rightEdge: right)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

// MARK: - 入口

// Pock 式全屏条预览: 按整条 Touch Bar 的宽度(默认 1000pt)渲染出接管后的样子
// 用法: WorkBuddyTouchBar --render-full [路径] [宽度]
if CommandLine.arguments.contains("--render-full") {
    let args = CommandLine.arguments
    let path = args.firstIndex(of: "--render-full").flatMap { i -> String? in
        (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
    } ?? NSString(string: "~/Desktop/wb-touchbar-full.png").expandingTildeInPath
    let width = args.firstIndex(of: "--width").flatMap { i -> CGFloat? in
        (i + 1 < args.count) ? CGFloat(Double(args[i + 1]) ?? 1000) : nil
    } ?? 1000
    var s = wbSnapshot()
    if s.taskTitle.isEmpty { s.taskTitle = "（无运行中任务）" }
    if renderFullPreview(s, to: path, width: width) {
        print("已生成全屏条预览: \(path)  (宽 \(Int(width))pt)")
    } else {
        print("渲染失败")
    }
    exit(0)
}

// BTT 桥接模式: 输出 BetterTouchTool Touch Bar Script Widget 可识别的 JSON
// 用法: WorkBuddyTouchBar --btt --slot main|count|task|timer|credits|all
if CommandLine.arguments.contains("--btt") {
    let args = CommandLine.arguments
    func argValue(_ name: String, _ def: String) -> String {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
        return args[i + 1]
    }
    let s = wbSnapshot()
    let slot = argValue("--slot", "main")
    var out: [String: Any] = [:]
    var fontColor = "255,255,255,255"
    switch slot {
    case "count":
        out["text"] = s.activeCount == 0 ? "WB ✓" : "▶\(s.activeCount)"
    case "task":
        out["text"] = s.taskTitle.isEmpty ? "空闲" : "▶ " + String(s.taskTitle.prefix(14))
    case "timer":
        out["text"] = s.ctxPct >= 0 ? "\(s.ctxPct)%" : "--"
    case "credits":
        out["text"] = "⚡\(s.fmtCredits) ✦\(s.fmtRemain)"
        fontColor = "255,214,102,255"
    case "all":
        out["text"] = s.oneLine
    default:  // main
        var t = s.activeCount == 0 ? "WB ✓" : "▶\(s.activeCount)"
        if s.ctxPct >= 0 { t += " \(s.ctxPct)%" }
        if s.activeCount > 0 { t += " ⚡\(s.fmtCredits)" }
        out["text"] = t
    }
    out["background_color"] = "0,0,0,0"
    out["font_color"] = fontColor
    out["font_size"] = 14
    let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    if let d = data { print(String(data: d, encoding: .utf8) ?? "{}") } else { print("{}") }
    exit(0)
}

// 离线预览模式: 把常驻条渲染成 PNG (无需 Touch Bar / 无需 GUI, 用于确认排版与宽度)
// 用法: WorkBuddyTouchBar --render /tmp/preview.png
if let ri = CommandLine.arguments.firstIndex(of: "--render") {
    let out = (ri + 1 < CommandLine.arguments.count) ? CommandLine.arguments[ri + 1] : "/tmp/wb-touchbar-preview.png"
    let ok = renderTrayPreview(wbSnapshot(), to: out)
    print(ok ? "已输出预览: \(out)" : "渲染失败")
    exit(ok ? 0 : 1)
}

// 自检模式: 打印一次任务列表与账号积分后退出 (用于验证数据链路)
if CommandLine.arguments.contains("--selftest") {
    let tasks = DataStore.shared.loadTasks()
    print("=== 本地任务 (工作目录库) ===")
    for t in tasks.prefix(8) {
        let pct = t.size > 0 ? Int(round(Double(t.used) / Double(t.size) * 100)) : 0
        print(String(format: "%@ | %@ | %@ | ctx %d/%d (%d%%) | 积分 %.2f",
                     t.isActive ? "运行中" : "  --  ", t.status, t.title,
                     t.used, t.size, pct, t.credits))
    }
    print("=== 账号积分 (wbipc → /billing/meter/get-user-resource-summary) ===")
    switch WbipcClient.fetchCredits() {
    case .success(let c): print(String(format: "剩余 %.2f / 总量 %.2f credits", c.remain, c.total))
    case .failure(let e): print("失败: \(e)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
