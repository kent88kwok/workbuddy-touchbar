# WorkBuddyTouchBar

在 MacBook Pro 的 Touch Bar 上常驻显示 **WorkBuddy 运行中任务状况 + 任务积分消耗 + 账号总积分**。

![全屏接管效果](docs/touchbar-full.png)

> 上图是 `--render-full` 渲染的「接管整条 Touch Bar」后的实际布局（宽 1000pt ≈ 13" MBP 触控栏）。
> 下图是控制条小件（备用通道）的宽度参考，约 198pt。

![控制条小件预览](docs/touchbar-preview.png)

## 显示效果

**全屏接管模式（默认，走 Pock 同款机制）**

整条 Touch Bar 被接管成 WorkBuddy 监控条，任何 App 在前台都保持：

```
▶1 49% ⚡55.2 ✦2234  |  开发Touch Bar版workbu · ctx 145k/300k  |  详情 ▸  |  ✕
```

- `▶1` 运行中任务数
- `49%` 当前任务上下文占用（used/size）
- `⚡55.2` 运行中任务累计消耗积分
- `✦2234` 账号剩余积分
- 第二格：当前任务标题 + 上下文明细
- `详情 ▸` 展开每个运行中任务与其消耗；`✕` 退出接管（交还系统 Touch Bar）

**菜单栏 ⚡WB 图标**：Pock 式接管开关 / 控制条小件开关 / 立即刷新 / 复制 BTT 桥接命令 / 生成 Touch Bar 预览图 / 开机自启动 / 退出

## 展示通道

| 通道 | 常驻性 | 依赖 | 说明 |
|---|---|---|---|
| **A. 全屏接管**（默认） | ✅ 任何 App 前台 | 私有 API `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:` | **Pock 用的就是这条**；接管整条 Touch Bar，免费 |
| B. 控制条小件 | ✅ | 私有 SPI `addSystemTrayItem:` | 只在控制条右侧挤一格，空间受限；A 生效时自动停用避免冲突 |
| C. 菜单栏 ⚡WB | ✅ | 无 | 兜底，永远可用 |
| D. BetterTouchTool widget | ✅ | 需 BTT **许可（付费）** | 读同一份状态快照，没许可可忽略 |

> A 与 B 互斥（同时挂两套会互相干扰，代码里已保证 A 生效时不挂 B）。
> D 与 A/B 不冲突，它读的是同一份 `/tmp/wb-touchbar-state.json`。

## 关于 Pock（为什么没装它本体）

Pock 是免费开源的，但**本项目不需要装 Pock**，因为：

- Pock 最后一次提交是 **2022-06-26**（版本 `0.9.0-22`），已停更 4 年多，构建环境停留在 macOS 10.14 时代；
- 即使能启动，它接管 Touch Bar 后显示的是**它自己的 Dock/天气等 widget**，要显示 WorkBuddy 数据得写 PockKit widget
  （要编译 `.pock` bundle，依赖 2021 年的 PockKit 框架，Swift 版本兼容风险很高）；
- 而 Pock 能常驻的**全部关键机制只有一条私有 API**，已经直接搬进本项目（见「技术要点」），
  效果等同、零依赖、且可自由显示我们要的内容。

一句话：**用的是 Pock 的原理，不是 Pock 这个壳。**

## 安装

```bash
cd wb-touchbar
./install.sh          # 编译 + 装到 /Applications + 启动
```

## 通道 B：接到 BetterTouchTool（可选，需 BTT 许可）

> BTT 是付费软件。**没有许可就不用看这一节** —— 通道 A 是免费的，通道 C 永远可用。
> 如果你已经有 BTT，这是最稳的常驻方式（官方支持的 Script Widget，不依赖任何私有 API）。

**步骤**

1. 菜单栏 ⚡WB → **复制 BTT 桥接命令**（已复制到剪贴板）。
2. 打开 BTT → **Touch Bar** 标签 → 新建一个 **Shell Script / Task Widget**（或 AppleScript Widget）。
3. 命令粘贴为：

   ```
   /Applications/WorkBuddyTouchBar.app/Contents/MacOS/WorkBuddyTouchBar --btt --slot main
   ```

   > 若建的是 **AppleScript / JavaScript 小组件**且 `Source Type = Apple Script`，要包一层：
   > ```
   > return do shell script "/Applications/WorkBuddyTouchBar.app/Contents/MacOS/WorkBuddyTouchBar --btt --slot main"
   > ```
4. 刷新间隔设 `1` 或 `2` 秒。
5. 想用满 Touch Bar 宽度，可以加多个 widget，只改 `--slot`：

| 槽位 | 内容 | 示例输出 |
|---|---|---|
| `main` | 任务数 + 上下文（默认） | `▶1 44% ⚡47.1` |
| `count` | 只有运行中任务数 | `▶1` |
| `task` | 当前任务标题（14 字内） | `▶ 开发Touch Bar版wo` |
| `timer` | 当前任务上下文占用 | `44%` |
| `credits` | 本任务积分 + 账号剩余（琥珀色） | `⚡47.1 ✦2243` |
| `all` | 一行全量 | `▶1 44% ⚡47.1 ✦2243` |

输出就是 BTT 认的 JSON：`{"text": "...", "background_color": "...", "font_color": "...", "font_size": 14}`，
颜色用 `r,g,b,a`（0-255），背景默认全透明。

数据由常驻 App 每 3 秒写入 `/tmp/wb-touchbar-state.json`，所以 BTT widget 只是读文件，**毫秒级**返回；
App 没在跑时脚本会自动现算本地任务（账号积分显示 `?`），不会报错。

## 命令行

```bash
B=/Applications/WorkBuddyTouchBar.app/Contents/MacOS/WorkBuddyTouchBar

# 数据链路自检: 打印本地任务 + 账号积分
"$B" --selftest

# BTT widget 用: 输出 JSON
"$B" --btt --slot main

# 离线预览: 把常驻条渲染成 PNG (不需要 Touch Bar, 用来确认排版与宽度)
"$B" --render /tmp/preview.png

# 全屏条预览: 渲染"接管整条 Touch Bar"后的样子 (默认 1000pt 宽)
"$B" --render-full /tmp/full.png
"$B" --render-full /tmp/full.png --width 1085     # 16" MBP 的触控栏约 1085pt
```

`--render` / `--render-full` 都很有用：它们**不需要 Touch Bar** 就能确认排版与真实宽度
（控制条小件实测 **198pt**，超过就该拆槽位；全屏接管则是整条触控栏、宽度可指定）。
这也是本项目「看不到也能验证」的手段。

## 数据来源

| 显示项 | 来源 | 方式 |
|---|---|---|
| 任务列表 / 状态 / 上下文 | `~/.workbuddy/workbuddy.db` → `sessions` + `session_usage` | SQLite 只读，3 秒轮询 |
| 运行中判定 | `status='working'` 或 `~/.workbuddy/sessions/*.json` 心跳（5 分钟内） | 文件读取 |
| 任务积分消耗 | `session_usage.credit_json` 逐轮积分求和 | JSON 求和 |
| 账号剩余/总积分 | `~/.workbuddy/wbipc/endpoint.json` → wb.request pipe → `http.fetch` → `POST /billing/meter/get-user-resource-summary` | 宿主登录态代发，30 秒轮询 |

## 技术要点

1. **全屏接管 Touch Bar（默认通道）**：`NSTouchBar.presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`
   —— 这是 **Pock 赖以常驻的唯一关键 API**（源码见 Pock 的 `Pock/Private/ApplePrivate.h` + `Private/TouchBarHelper.swift`，
   调用处 `TouchBarHelper.presentOnTop`，`placement: 1`）。它是 `NSTouchBar` 的**类方法**，SDK 无声明，
   经 `dlsym("objc_msgSend")` + `@convention(c)` 函数指针动态调用。
   与 tray item 的本质区别：tray 是「挤进控制条右侧一格」，modal 是「接管整条 Touch Bar」。
2. **控制条小件（备用通道）**：`NSTouchBarItem.addSystemTrayItem:`（MTMR / Pock 同族的系统 tray SPI）。
3. **展开详情**：详情条是另一条 bar，同样走 `presentSystemModalTouchBar` 切换，`◂ 返回` 切回主条。
4. **运行时探测 + 降级**：所有私有调用前先 `NSClassFromString` / `responds(to:)` 探测，
   不可用就跳过（某条通道失效不影响其它通道与菜单栏）。
4. **wbipc 握手**（官方对外契约，agent-cli 同款通道）：
   读 `endpoint.json` 拿 `{endpoint, ticket}` → 连 unix socket →
   `session_hello`(protocol_min/max + client_nonce + ticket_id=sha256(ticket)[:16]) →
   校验 `server_proof` → 回 `session_prove`(client_proof) → `session_hello_ack` →
   JSON-RPC `broker/GetPipe{pipe:"wb.request"}` → `c:wb.request/http.fetch` 带宿主登录态请求。
   证明算法：`HMAC-SHA256(ticket, len-prefixed(["wbipc-s"|"wbipc-c", "1", endpoint, clientNonce, serverNonce]))`，base64url。
   坑：角色前缀必须是 `wbipc-s` / `wbipc-c`，写 `server`/`client` 会握手失败。

### ⚠️ Touch Bar 的三个坑（都已在代码里绕过）

1. `NSTouchBar*` 类与那些 SPI **只在真实 GUI 进程（经 LaunchServices 启动）里存在**；
   从终端直接跑的 CLI 进程里查不到这些类 —— 所以 `--selftest` 只验证数据链路，不验证 Touch Bar。
   （本项目曾因此误判「macOS 已移除 Touch Bar API」，实际是探测方式不对。）
2. 在 `applicationDidFinishLaunching` 里直接呈现会**与系统 TouchBarServer 死锁**
   （表现为 App 卡在启动阶段、Touch Bar 什么都不显示）。必须延迟约 1.5 秒再呈现。
3. **bar 只能构建一次，之后只更新内容**。反复 `build → dismiss → present` 新 bar，会让系统侧的
   `NSTouchBarItemContainerView` 在 autorelease pool 回收时二次释放，直接
   `EXC_BAD_ACCESS / SIGSEGV`（崩溃栈顶：`-[NSTouchBarItemContainerView dealloc]` → `objc_msgSend`）。
   本项目实测崩过两次才定位到。Pock 从不重建 bar、只更新 view 内容 —— 本实现照此做：
   主条与详情条各构建一次并长期持有，刷新只改 `stringValue`，保活也只重复 present 同一个对象。

## Touch Bar 上看不到？按顺序排查

1. **先碰一下 Touch Bar**。空闲约 60 秒它会自动变暗/收起，这是系统行为，不是没生效。
2. **看呈现日志**：

   ```bash
   cat /tmp/WorkBuddyTouchBar.log
   ```

   正常应能看到（`新建` 只出现一次，之后都是 `复用`）：

   ```
   启动 | tray=可用(hasTraySPI=true) | pockModal=可用(hasPresent=true)
   Pock-e 全屏条已呈现 (placement=1, 新建) | ▶1 49% ⚡55.2 ✦2234
   Pock-e 全屏条已呈现 (placement=1, 复用) | ▶1 49% ⚡55.2 ✦2234
   Pock-keepalive 复用呈现 (存活中)
   ```

   - 第一行 `pockModal=不可用` → 该系统版本没有这条私有 API，退回菜单栏（通道 C）。
   - 有 `Pock-e` 但 Touch Bar 上仍无 → 系统侧阻挡，见第 3、4 步。
3. **确认显示模式**：

   ```bash
   defaults read com.apple.touchbar.agent PresentationModeGlobal
   ```

   期望 `appWithControlStrip` 或 `app`。若是 `functionKeys`（仅功能键），第三方内容不会显示。
4. **切换一次显示模式**：系统设置 → 键盘 → 触控栏设置 →「触控栏显示」，在
   「App 控件」与「App 控件 + 控制条」之间切一下，再看 Touch Bar。
   某些系统版本只在其中一种模式下接纳第三方内容。
5. **仍未出现**：说明该系统版本已封锁私有 Touch Bar 通道（Apple 从未承诺兼容性）。
   此时菜单栏 ⚡WB 里的数字与 Touch Bar 上完全一致，零依赖可用。

## 参考项目

| 项目 | 它的做法 | 本项目借鉴的点 |
|---|---|---|
| [pock/pock](https://github.com/pock/pock) | 免费开源的 Touch Bar widgets 管理器。用私有 `NSTouchBar.presentSystemModalTouchBar:placement:` **接管整条 Touch Bar**，并 swizzle `NSFunctionRow.markActiveFunctionRowsAsDimmed` 监听系统收起后重新呈现 | **默认通道 A 的全部机制**：`Pock/Private/ApplePrivate.h` 的私有声明 + `TouchBarHelper.presentOnTop`（`placement: 1`）；以及「**bar 只构建一次、之后只更新内容**」这条生命周期纪律 |
| [therswamhtet/agent-status-pock](https://github.com/therswamhtet/agent-status-pock) | Pock widget + 本地桥 daemon（127.0.0.1:3939），agent hooks 推事件，widget 轮询渲染 | **离线渲染自检**（它的 render tests 把 UI 各状态导到 `dist/`）→ 我们做成 `--render` 出 PNG；widget 零符号依赖、运行时解析的做法 |
| [PPPHUANG/touch-bar-agent-status](https://github.com/PPPHUANG/touch-bar-agent-status) | 不写常驻程序，交给 **BetterTouchTool Script Widget**；Node 脚本输出 JSON（text/bg/font），并按 `--slot` 拆成多个 widget | **通道 D**（`--btt --slot …`）、槽位拆分思路、用状态文件解耦（它写 `.state/*.json`，我们写 `/tmp/wb-touchbar-state.json`） |
| [yizhigou/codex-usage-bar](https://github.com/yizhigou/codex-usage-bar) | 公开 `NSApplication.touchBar` 做页面 + 未公开 `presentSystemModalTouchBar:` 做常驻；每条私有调用都做运行时检查，不支持就退回普通模式 | **「可选路径失败绝不影响主功能」的隔离原则**、内置 `--self-test`、把「私有接口会随系统更新失效」明确写进文档 |

## 卸载

```bash
./uninstall.sh
```

（若配过通道 B，请自行在 BTT 里删掉对应 widget。）

## 已知限制

- 依赖 WorkBuddy 内部实现（数据库表、wbipc 管道名、云端接口路径）。WorkBuddy 大版本升级后可能失效；
  失效时优先看 `--selftest` 输出定位是本地库还是 wbipc 变了。
- `http.fetch` 只允许 `content-type` / `accept` 自定义头，鉴权头由宿主注入；只能打宿主后端同源路径。
- WorkBuddy 未登录或未运行时，账号积分显示 `✦?`，任务部分仍可用。
- 全屏接管（通道 A）用的是未公开接口，macOS 升级后可能失效 —— 届时 App 会自动跳过并留日志，
  退路是菜单栏 ⚡WB（永远可用）或 BTT widget。
- 保活逻辑每 30 秒重复呈现同一个 bar（对抗系统收起）。若遇到偶发不稳定，把 `startKeepAlive()` 里的间隔调大或注释掉即可，
  主条仍会在启动时呈现。
- 通道 A 一旦生效就**接管整条 Touch Bar**（系统音量/亮度控制条会被顶掉）。点 `✕` 或菜单里的开关即可交还。
