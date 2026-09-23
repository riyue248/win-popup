# win-popup — Claude Code 桌面弹窗提醒

> 如果你是让 AI agent 来装，把 **`INSTALL-FOR-AGENT.md`** 给它，那份是给机器看的（含前置检查和不许自行绕过的判断点）。
> 本文件是给人看的。

Claude Code 在终端里跑长任务时，你不必一直盯着它。这个插件会在两种时刻弹一个
Windows 原生置顶窗口**提醒你**，**点一下就把对应的终端窗口拉到最前**。

```
┌────────────────────────────────────┐
│▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔│  ← 琥珀=要你确认 / 蓝=提问 / 紫=计划 / 绿=任务完成
│ ● 需要你确认                        │
│   my-project  ·  运行命令           │
│ ┌────────────────────────────────┐ │
│ │ npm run build && docker rm app │ │
│ └────────────────────────────────┘ │
│ 点击跳转到该会话（WindowsTerminal） │
└────────────────────────────────────┘
```

**两种时刻会弹：**

| 时刻 | 场景 |
|---|---|
| **要你动手** | Claude 停下来等你批准命令 / 回答选择题 / 批准计划 |
| **要你知道** | 这一轮任务答完了（弹窗里是 Claude 的最终回复） |

**不会**在自动放行的操作、子智能体、后台任务上打扰你——只有真正的"卡住了"才弹。

---

## 安装前提

| 要求 | 说明 |
|---|---|
| **Windows 10 / 11** | 用了 WPF 和 Win32 API，**不支持 macOS / Linux** |
| **Windows PowerShell 5.1** | 系统自带，无需安装 |
| **Claude Code 2.1.x 或更新** | 需要插件系统 + hooks 支持 |
| **执行策略不是 Restricted** | ⚠️ **见下方，这是最常见的翻车点** |

### ⚠️ 先检查执行策略

企业电脑上经常被组策略设成 `Restricted`，**那样脚本根本不会运行，而且完全没有报错** ——
你会以为装好了，但永远等不到弹窗。

安装前先跑这一条确认：

```powershell
Get-ExecutionPolicy -Scope CurrentUser
```

- 显示 `RemoteSigned` / `Unrestricted` / `Bypass` → **没问题，继续安装**
- 显示 `Restricted` / `Undefined` → 需要放开（这是**当前用户范围**的改动，不需要管理员）：

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  ```

---

## 安装

在终端里执行两条命令：

**从 GitHub 装（推荐）** —— Claude Code 自己管理副本，不用管文件夹在哪：

```bash
claude plugin marketplace add riyue248/win-popup
claude plugin install win-popup@win-popup
```

**从本地文件夹装** —— 把包含 `.claude-plugin/` 那一层的绝对路径填进去：

```bash
claude plugin marketplace add "<解压后的绝对路径>"
claude plugin install win-popup@win-popup
```

> ⚠️ 本地文件夹方式是**就地加载**的，装完**不要移动/改名/删除那个文件夹**，否则会静默失效。

装完**新开一个 Claude Code 会话**即可生效——不需要任何"调用"动作，
它是 hook 插件，Claude Code 会自己触发。

> 如果当前会话已经开着，执行一次 `/reload-plugins` 就能立即生效，不用重开。

### 确认装好了

```bash
claude plugin details win-popup
```

`Hooks` 一栏应该显示 **8 个**。

---

## 使用

**不需要做任何事。** 该弹的时候自己会弹。

- **点窗口上任何地方** → 跳转到发起这次确认的终端窗口，弹窗关闭
- **不点** → 它一直留着，直到你点它（或会话结束）

想验证是否生效，随便让 Claude 做一件需要授权的事（比如 `rm` 一个文件），
弹窗应该立刻出现。

---

## 配置（可选）

配置文件在 `%LOCALAPPDATA%\claude-win-notify\config.json`，改完**立即生效**，不用重启：

```json
{
  "timeoutSeconds": 0,
  "sound": true,
  "position": "bottom-right",
  "closeOnClear": false,
  "closeOnProgress": false,
  "notifyOnStop": true
}
```

| 键 | 默认 | 说明 |
|---|---|---|
| `notifyOnStop` | `true` | **「任务完成」也弹**。嫌每轮都弹就改成 `false`，只保留"卡住了"的提醒 |
| `timeoutSeconds` | `0`（永不） | 想让它自动消失就设成秒数，比如 `30` |
| `sound` | `true` | 响两声，音量小的时候更容易注意到 |
| `position` | `bottom-right` | `bottom-right` / `bottom-left` / `top-right` / `top-left` / `center` |
| `closeOnClear` | `false` | 你在终端回答了就自动关 |
| `closeOnProgress` | `false` | 该确认已通过（transcript 变长）就自动关 |

> 配置值都做了容错：写错了会退回默认值，不会让插件整个失效。

---

## 排查

两份日志在 `%LOCALAPPDATA%\claude-win-notify\`：

**`hook.log`** —— 每次事件一行，说明**为什么弹 / 为什么没弹**：

```
09-23 20:39:28 事件=PermissionRequest 工具=Bash 会话=19160301-...
09-23 20:39:29   └ 弹窗：需要你确认  [my-project  ·  运行命令]
09-23 20:39:34 事件=Notification 类型=permission_prompt
09-23 20:39:34   └ 跳过：兜底通知，6s 前已报过
```

**`popup.log`** —— 弹窗自己的生命周期，比如点击后跳去了哪：

```
20:39:32.616 找到会话窗口: pid=11204 (cmd) hwnd=36771200 class=CASCADIA_HOSTING_WINDOW_CLASS (爬了 2 层)
20:39:38.322 跳转到会话窗口: SetForegroundWindow=True
20:39:38.336 closed: reason=clicked
```

| 症状 | 先看 |
|---|---|
| 该弹没弹 | `hook.log` **完全没有新行** → 多半是执行策略（见上）或 Claude Code 版本太旧 |
| 弹了但点击不跳转 | `popup.log` 里的 `找到会话窗口` / `没找到会话窗口` |
| 每轮都弹太吵 | 把 `notifyOnStop` 设成 `false` |

---

## 隐私

- **零网络请求**。插件不联网、不上传任何东西、不依赖任何云服务。
- 它只在本地写两类文件：
  - `msg_*.json` —— 待弹窗的内容（含 Claude 待执行的命令 / 最终回复），弹窗关闭即删
  - `hook.log` / `popup.log` —— 运行日志，记录事件类型、工具名、会话 ID
- 全部在 `%LOCALAPPDATA%\claude-win-notify\`，删掉这个目录即可清空。
- 不修改 Claude Code 本身，不接管权限——**它只是通知，不能远程批准任何操作**。

---

## 已知限制

- **仅 Windows**。
- **Windows Terminal 多标签页**：只能把整个终端窗口拉到前面，切不到具体那个标签页。
- **找不到终端窗口时**，点击只关闭、不跳转（不会跳错地方）。原因写在 `popup.log`。
- **多显示器**：弹窗固定出现在主屏右下角。
- **全屏独占**的游戏/播放器里可能看不到。
- 依赖 Claude Code 的 hooks 事件。**如果 Claude Code 大版本升级改了 hook 协议，可能需要跟进更新。**
