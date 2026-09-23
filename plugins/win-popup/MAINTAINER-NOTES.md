# win-popup

Claude Code **需要你确认、或一轮任务答完时**，在屏幕右下角弹一个 Windows 原生置顶窗口。

纯 PowerShell + WPF，零依赖（不用装 jq、不用装模块、不用跑服务）。

```
┌────────────────────────────────────┐
│▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔│  ← 琥珀色=确认 / 蓝=提问 / 紫=计划
│ ● 需要你确认                        │
│   claude-plugins  ·  运行命令       │
│ ┌────────────────────────────────┐ │
│ │ rm -rf ./build && npm run build│ │
│ └────────────────────────────────┘ │
│ 点击跳转到该会话（cmd）              │
└────────────────────────────────────┘
```

## 什么时候弹

**原则：只在「要你动手」或「要你知道」的两种时刻弹。** 其余一律不打扰。
- **要你动手** = 聊天框卡住了在等你确认（权限 / 提问 / 计划批准）
- **要你知道** = 这一轮任务答完了（`Stop`）

| 事件 | 说明 |
|---|---|
| `PermissionRequest` | **主力**。Claude 要弹权限框时**立即**触发 |
| `PreToolUse` → `AskUserQuestion` | Claude 用选择题问你时 |
| `PreToolUse` → `ExitPlanMode` | Claude 提交计划等你批准时 |
| `Stop` | **任务完成**。这一轮答完了也弹一下，内容就是 Claude 的最终回复 |
| `Notification` → `permission_prompt` | **兜底**。官方这个事件要等权限框挂 6 秒才发，所以只在前面几个都没报过时才弹 |

「任务完成」的弹窗是**绿条**，正文取 `last_assistant_message`（Claude 这轮的最终回复原文）。
`stop_hook_active=true` 时跳过 —— 那表示 Claude 是被别的 stop hook 拽着继续的，
不是真正的回合结束，弹了会连环。

如果这一轮结束时后台还有任务在跑，meta 里会标 `后台还有 N 个任务在跑` ——
说明只是"暂停"不是"结束"。

### 两道闸门（别删）

脚本在判定前会先过两道闸门，专门挡住「看着像要确认、其实没卡住」的假阳性：

1. **`PreToolUse` 只认 `AskUserQuestion` / `ExitPlanMode`。**
   `PreToolUse` 对**每一次**工具调用都会触发，不设闸门的话你每跑一条命令都弹窗。

2. **带 `agent_id` 的事件直接丢弃。**
   子智能体 / 后台任务里没有能互动的聊天框，那里的权限请求会被自动拒绝、
   Claude 自己继续往下走 —— 你根本没被卡住，不该收到通知。

### 去重（判据是「事件名」，别改错）

同一次确认可能触发多个事件（`AskUserQuestion` 会同时走 `PreToolUse` 和 `PermissionRequest`），
所以要按「会话 + 工具 + 内容」15 秒去重。**但必须再加一条判据**：

| 情况 | 判定 |
|---|---|
| key 相同且**事件名不同** | 同一次确认的第二个事件 → 去重 |
| key 相同且**事件名相同** | **两次独立的新确认 → 都要弹** |

少了后半条，会把「同一条命令被拒后重试」「两次内容不同的 `TodoWrite`」
（`tool_input` 里没有可抽取字段，key 退化成常量）当成重复**静默吞掉** ——
Claude 卡住等你而你毫不知情。**宁可多弹一次，不能漏弹。**
`Notification` 兜底则是 60 秒内有过推送就丢弃。

## 点击 = 跳回那个会话

**点弹窗上【任何地方】都能跳** —— 标题、正文文字、空白、边缘都行。

用的是**隧道事件 `PreviewMouseLeftButtonDown`**，不是冒泡的 `MouseLeftButtonDown`。
原因见下方坑位 18：正文框里的 `TextBlock` 会把冒泡事件标记为 `Handled`，
事件就再也到不了 `Window` —— 表现就是「点正文文字完全没反应」。

**点弹窗不只是关掉它，还会把发起这次确认的那个终端窗口拉到最前。**

`notify.ps1` 记下自己的父进程 PID，弹窗顺进程链往上爬找终端。但**关键是最后那一跳**：

```
shell(cmd/powershell)  ──进程树──▶  找不到窗口
       │
       └──窗口所有权──▶ PseudoConsoleWindow ──owner──▶ CASCADIA_HOSTING_WINDOW_CLASS
                                                       （Windows Terminal 的真窗口）
```

Windows Terminal 下 shell 自己**没有窗口**，它有一个 `PseudoConsoleWindow`，
而这个窗口的 owner 才是终端窗口。**进程树在这里没用，得顺着窗口所有权走一跳**。
（而且 `PseudoConsoleWindow` 是 owned 窗口，常规「跳过 owned 窗口」的枚举会把它筛掉。）

点击时 `SetForegroundWindow` 把终端抢到前台，然后弹窗自己关闭。日志：

```
找到会话窗口: pid=43540 (cmd) hwnd=18026850 class=CASCADIA_HOSTING_WINDOW_CLASS (爬了 1 层)
跳转到会话窗口: SetForegroundWindow=True (attach-failed)
```

> `attach-failed` 不代表失败 —— 用户刚点了弹窗、本进程已获得前台权限，
> 所以即使 `AttachThreadInput` 没成功，`SetForegroundWindow` 照样生效（实测）。
> 显示 `same-thread` 则说明当时前台就是本进程。

**实测**（模拟「你正在别的应用里」）：

| | hwnd |
|---|---|
| 弹窗认准的目标 | 4985496 |
| 点击**前**前台（别的应用） | 42472428 |
| 点击**后**前台 | **4985496** ✅ |

> ⚠️ **局限**：Windows Terminal 是「一个窗口多个标签页」，系统层面拿不到「哪个标签」，
> 所以只能把整个终端窗口拉到前面，不能切到具体那个 tab。多标签时你还要自己点一下。
> 找不到时点击只关闭、不跳转，原因写在 `popup.log`。

## 什么时候消失

**默认：只有你点它才关。** 会自动消失的提醒等于没有提醒 —— 你离开电脑回来时它已经没了。

| 路径 | 默认 | 说明 |
|---|---|---|
| **你点它** | ✅ 总是 | 跳转到会话窗口 + 关闭 |
| 同一会话来了新的确认 | ✅ 总是 | 新的顶替旧的（否则会叠一屏） |
| 会话结束（`SessionEnd`） | ✅ 总是 | 带 `FORCE` 标记，会话都没了留着它没意义 |
| 你回终端处理了 | ❌ 关掉 | 想开就把 `closeOnClear` 设成 `true` |
| 操作已通过（transcript 变长） | ❌ 关掉 | `closeOnProgress` |
| 超时 | ❌ 关掉 | `timeoutSeconds` 默认 `0` = 永不 |

## 配置

`%LOCALAPPDATA%\claude-win-notify\config.json`：

```json
{
  "timeoutSeconds": 0,
  "sound": true,
  "position": "bottom-right",
  "closeOnClear": false,
  "closeOnProgress": false
}
```

| 键 | 默认 | 说明 |
|---|---|---|
| `timeoutSeconds` | `0` = 永不 | 嫌它赖着不走就设成 `30` |
| `sound` | `true` | 响两声（间隔 0.9 秒），音量小的时候更容易被注意到 |
| `position` | `bottom-right` | `bottom-right` / `bottom-left` / `top-right` / `top-left` / `center` |
| `closeOnClear` | `false` | 你在终端回答了（`UserPromptSubmit` / `Stop` 等）就自动关 |
| `closeOnProgress` | `false` | 该确认已通过（transcript 变长）就自动关，只对权限类生效 |

> 所有值都做了容错：`"timeoutSeconds": "abc"` 会退回默认值而不是让弹窗整个失效；
> `"sound": "false"`（字符串）会被正确解析成 `false` 而不是真值。

改完立即生效，不用重启。

## 排查

两份日志，分工不同：

**`hook.log`** —— 每次事件都记一行「为什么弹 / 为什么没弹」。想知道「这个操作到底该不该弹」就看它：

```
09-22 14:26:01 事件=PreToolUse 工具=AskUserQuestion 类型= 会话=k2
09-22 14:26:01   └ 弹窗：有问题要问你  [Demo  ·  向你提问]
09-22 14:26:03 事件=PermissionRequest 工具=AskUserQuestion 类型= 会话=k2
09-22 14:26:03   └ 跳过：同一次确认的重复事件（2s 前已弹过）
09-22 14:26:05 事件=PermissionRequest 工具=Bash 类型= 会话=k9
09-22 14:26:05   └ 跳过：子智能体/后台任务（agent_id=sub-7），没有可互动的聊天框
```

**`popup.log`** —— 弹窗本体的生命周期：

```
11:56:14.581 [pid 24512] closed: reason=clicked after 30s
```

`reason` 有五种：

| reason | 含义 |
|---|---|
| `clicked` | 你点的 |
| `cleared` | 你回终端了（clear flag 点名关掉的） |
| `progress` | transcript 变长了，说明这个确认已经过去了（需开 `closeOnProgress`） |
| `timeout` | 超时（需设 `timeoutSeconds`） |
| `unknown` | 异常关闭 |

常见问题：

- **权限框出来了但没弹窗** —— 看 `hook.log` 有没有新行。没有的话是 hook 没触发，
  检查 `claude plugin details win-popup` 里 Hooks 是不是 **7 个**（事件名数，非条目数）。
- **点击没跳到终端** —— 看 `popup.log` 里的 `找到会话窗口` / `没找到会话窗口` 那行。
  显示 `跳过桌面/任务栏窗口` 说明防护起作用了（宁可不跳也不跳到任务栏）。
- **弹窗一闪就没了** —— `clear_*.flag` 残留。删掉 `%LOCALAPPDATA%\claude-win-notify\clear_*.flag`。

## 已知限制

- **多开 Claude Code 时**，不同会话各自维护弹窗，互不顶替 —— 可能同时挂几个。
  同会话内新的会顶掉旧的。
- **Windows Terminal 多标签**：只能把整个终端窗口拉到前面，不能切到具体那个 tab。
- **爬不到窗口时点击就只关闭**（不跳转）。`popup.log` 里会写明原因。
- 全屏独占的游戏/播放器里可能看不到（置顶窗口盖不过独占全屏）。

## 踩过的坑（改代码前必读）

> 全部是实测撞出来的，不是理论推演。按「症状 → 根因」记。

### 平台陷阱

**1. `.ps1` 必须存成 UTF-8 带 BOM。**
PowerShell 5.1 读无 BOM 的 `.ps1` 会按 GBK 解码，中文注释会把**下一行代码整个吞掉**，
而且报错信息也是乱码，极难定位。反过来 `plugin.json` / `hooks.json` **绝对不能有 BOM**
（Claude Code 2.1.204 会直接报 JSON 解析失败）。

**2. `Add-Type` 用的是 C# 5 编译器，不是现代 C#。**
PowerShell 5.1 的 `Add-Type` 走老的 `CSharpCodeProvider`，**不支持内联 out 变量**
（`GetWindowThreadProcessId(h, out uint pid)`）、字符串插值 `$"..."`、表达式体成员等。
必须写成 `uint pid; GetWindowThreadProcessId(h, out pid);`。

**3. `GetCurrentThreadId` 在 `kernel32.dll`，不在 `user32.dll`。**
写错是**运行时**才炸的 `EntryPointNotFoundException`，不是编译错误。
`GetWindowThreadProcessId` / `AttachThreadInput` / `SetForegroundWindow` 确实在 `user32`。

**4. `GetClassNameW` / `GetWindowTextW` 必须显式 `CharSet = CharSet.Unicode`。**
`[DllImport("user32.dll")]` 默认是 **Ansi**，而这两个是 W 函数（收 UTF-16 缓冲），
不写的话读回来的类名和标题是**乱码**。后果很隐蔽：跟 `"Shell_TrayWnd"` 之类的
字符串比较**永远不成立**，于是「排除桌面窗口」的防护形同虚设，点击会跳到任务栏。
（表现为日志里窗口标题是一串 `?` 和乱码 —— 那就是 ANSI 封送 UTF-16 的典型症状。）

**5. 防抢焦点要写 `ShowActivated="False"`，`MA_NOACTIVATE` 管不着它。**
`MA_NOACTIVATE` 只拦**鼠标激活**；窗口 `Show()` 时的激活是另一条路径。
不写 `ShowActivated="False"` 时实测 **10/10 抢焦点**，写了 **0/10**。
少了它，弹窗一冒出来你在终端打的字就进弹窗了。

**6. 找终端窗口不能只爬进程树，要顺着窗口所有权走一跳。**
Windows Terminal 下 shell 自己没窗口，它有个 `PseudoConsoleWindow`，
owner 才是终端窗口（`CASCADIA_HOSTING_WINDOW_CLASS`）。
而且 `PseudoConsoleWindow` 是 owned 窗口 —— 常规「跳过 owned」的枚举会把它筛掉。
只爬进程树的后果：`explorer.exe` 往往正是链上第一个有窗口的进程，于是**跳到任务栏**。

**6.5 点击处理器必须用【隧道】事件，不能用冒泡事件。**
正文框里的 `DetailText`（`TextBlock` 套在 `ScrollViewer` 里）会把
`MouseLeftButtonDown` 标记为 `Handled`，事件就再也冒泡不到 `Window` ——
**点正文文字完全没反应**（既不跳转也不关闭），而点标题、空白、边缘都正常。
实测：20 次点击只有 13 次冒泡成功，**丢掉的那 7 次正好都是打在 `DetailText` 上的**。

改用 `PreviewMouseLeftButtonDown`（隧道方向：根 → 叶子，Window 先拿到）任何子元素都拦不住。
**副作用**：拖正文框的滚动条也会触发跳转+关闭——正文一般一两行，不影响。

> 这个 bug 特别容易漏，因为**它只在你点到文字上时才出现**：
> 框的 `Padding="11,9"` 意味着框内上方 9px 是"空白"，点那里是好的，
> 只有点在文字上才失效。我一开始就是测到了 padding 上，误判成"没问题"。

**6.6 `closeOnClear` 会和 Stop 打架 —— 新弹窗必须躲开「你回来了」信号。**
`Stop` 同时挂了 `notify.ps1`（建弹窗）和 `clear.ps1`（写关闭信号）。notify 刚落盘，
clear 就看到了这个 msg 并把它写进 flag → 开了 `closeOnClear` 时，
**「任务完成」弹窗会在第一个 tick（600ms）里自杀**，Stop 提醒形同虚设。
修法：clear.ps1 只清**存在超过 5 秒**的 msg —— 「你回来了」这个语义只对**之前就挂着**的弹窗成立。

**6.7 Preview 事件无条件关窗，会吃掉滚动条。**
正文超过 210px 会出滚动条，而 Preview 在隧道阶段就 `Close()`，
用户想拖滚动条看长命令时会被直接关窗。
现在点击处理器会先 `InputHitTest` + 往上遍历视觉树，命中 `ScrollBar` 就跳过不关。

**6.8 `Substring` 截断会切断代理对。**
700 字上限如果正好切在 emoji 的 UTF-16 高低代理之间，会留下孤立代理，
序列化成 JSON 时变成 `U+FFFD`（一个问号方块）。截断前先看 `IsHighSurrogate`，是就退一格。

**7. 置顶窗口要拦 `WM_MOUSEACTIVATE` 返回 `MA_NOACTIVATE`。**
否则窗口未激活时，第一次点击会被 Windows 拿去「激活窗口」而不派发给程序 ——
表现就是「点了没反应，得点两次」。（它**不负责**防止显示时抢焦点，见第 5 条。）

### 逻辑陷阱

**8. 去重要判【事件名】，不能只判内容。**
`PreToolUse` 和 `PermissionRequest` 会为**同一次**确认各触发一次，所以要去重；
但写成「内容相同就跳过」会误杀两种情况：① 同一条命令被拒绝后重试；
② `TodoWrite` 这类 `tool_input` 里没有可抽取字段的工具，内容恒为空、
去重键退化成 `"TodoWrite|"`，**两次完全不同的确认会被当成重复吞掉**。
判据要加一条：**事件名相同 = 两次独立的新确认，都要弹**。
宁可多弹一次，不能漏弹 —— 漏弹意味着 Claude 卡住而你毫不知情。

**9. 抽取文案要按【工具】分支，不能按【事件】分支。**
同一个 `AskUserQuestion` 既走 `PreToolUse`（kind=question）也走 `PermissionRequest`（kind=permission）。
按 event 分支抽文案，两次抽出来的文本不同 → 去重键不同 → **同一次确认弹两次**。

**10. clear flag 必须「点名」要关哪一个。**
新弹窗从落盘到第一次轮询有 1.5~1.8 秒。这期间如果有个并发的 clear 写了
「无差别关闭」的 flag，新弹窗会在第一次 tick 就自杀，**通知等于没发出去**。
现在 flag 里写具体 msg 文件名，弹窗只认写着自己名字的 flag。

**11. 残留文件会互相放大。**
弹窗被任务管理器杀掉时来不及清自己的 msg 文件；残留的 msg 又会让 `clear.ps1`
永远以为「有弹窗挂着」，此后每回合都写 flag，把第 11 条的竞态从偶发变成常驻。
`notify.ps1` 里有一个每小时最多跑一次的大扫除（清 24 小时前的 msg/clear/dedupe）。

### 性能与健壮性

**12. 配置里的一个坏值不能让整个弹窗罢摆。**
`"timeoutSeconds": "abc"` 会让 `[int]` 转换抛错 → 撞 `ErrorActionPreference='Stop'`
的 trap → `exit 1` → **一个窗口都不弹，而且只在 popup.log 里留个堆栈**。
所有配置项都走带默认值的容错转换。顺带：`"sound": "false"`（字符串）在
PowerShell 里是**真值**，会被当成开启声音 —— 布尔值也要显式解析。

**13. 装饰性功能不能连累主功能。**
`popup.ps1` 里 `WM_MOUSEACTIVATE` 那段 C# 编译失败过一次（Add-Type 抛错 → 撞上
`ErrorActionPreference='Stop'` 的 trap → 整个弹窗进程退出，**弹窗根本不出现**）。
现在它被 try/catch 包住：编译失败只降级成「点击要两下」，弹窗照常弹。

**14. 点击要能「补算」跳转目标，否则开头一秒内点击会失灵。**
跳转目标是在第一次 timer tick 里算的（全量进程快照 ~500ms），
所以弹窗刚出现的头一秒内点下去，目标还是 0 → 只关不跳，**看起来像随机失灵**。
现在点击处理器里会检查 `lookupDone`，没算过就当场补算一次再关。

**15. 进程快照 500ms，别放在弹窗显示之前。**
`Get-CimInstance Win32_Process`（全量 441 个进程）实测 **517ms**，单条带 filter 的 **178ms**。
把全量快照放在 `ShowDialog` 之前会把弹出硬生生拖慢半秒。
现在它在第一次 timer tick 里做 —— 窗口先出现，跳转目标后确定。

**16. 进程链的第一跳最容易断。**
弹窗是 `notify.ps1` 甩出去的子进程，而 `notify.ps1` 交完差就退出了 ——
等弹窗启动时想从**自己**往上爬，第一跳就查不到（已死进程没有 ParentProcessId）。
所以必须在 `notify.ps1` 里先把父进程 PID 取出来传过去。
另外：**被记录的那个父进程必须还活着**。真实场景里它是 claude 进程（全程存活）所以没问题，
但如果哪天变成某个调完即退的中间 shell，爬链会断在第一步 —— `popup.log` 里会写「进程链在 pid=X 断了」。

**17. `hooks.json` 的 matcher 是「会话启动时」缓存的，脚本不是。**
改了 `hooks.json` 要 `/reload-plugins` 或重开会话才生效；改了 `.ps1` **立即生效**，
因为每次事件都从磁盘现读。所以能写在脚本里的判据就别只写在 matcher 里 ——
闸门同时写在两处，脚本那道是立即生效的保险。

## 结构

```
win-popup/
├─ .claude-plugin/plugin.json   插件清单
└─ hooks/
   ├─ hooks.json                6 个事件的注册（exec 形式，直接 call powershell.exe）
   ├─ notify.ps1                判定 + 去重 + 拼文案 + 甩出弹窗（<1s 返回）
   ├─ popup.ps1                 窗口本体，独立进程常驻，轮询关闭信号
   └─ clear.ps1                 你回终端了就写 clear flag 收窗
```

运行时状态全在 `%LOCALAPPDATA%\claude-win-notify\`，插件目录本身只读。
