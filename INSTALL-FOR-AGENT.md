# 安装说明（给 AI agent 执行）

你要把 **win-popup** 装到这台 Windows 机器上的 Claude Code 里。
它是一个 hook 插件：Claude Code 需要用户确认、或一轮任务答完时，弹一个 Windows 置顶窗口，
用户点一下就把对应的终端窗口拉到最前。

**全程不需要用户手动操作**，但下面标了 ⛔ 的地方必须先问过用户再继续。

---

## 步骤 0：前置检查

**逐条跑，任何一条不通过就停下来告诉用户，不要自行绕过。**

### 0.1 操作系统

```bash
uname -s 2>/dev/null || echo Windows
```

- 是 Windows → 继续
- ⛔ 不是 Windows（macOS / Linux）→ **停下**。这个插件用了 WPF 和 Win32 API，**在其他系统上完全无法运行**，装了也没用。

### 0.2 PowerShell 执行策略 ⚠️ 最容易翻车的一步

```bash
powershell.exe -NoProfile -Command "Get-ExecutionPolicy -Scope CurrentUser"
```

| 输出 | 动作 |
|---|---|
| `RemoteSigned` / `Unrestricted` / `Bypass` | ✅ 通过，继续 |
| `Restricted` / `Undefined` | ⛔ **先问用户** |

如果是 `Restricted`，**脚本会被系统禁止运行，而且完全静默** —— 插件看起来装好了，
但永远不会有任何反应，日志里也查不到原因。

修法是放开当前用户范围（不需要管理员）：

```bash
powershell.exe -NoProfile -Command "Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
```

⛔ **这是修改安全设置，必须先征得用户明确同意**，不要擅自执行。

### 0.3 Claude Code CLI

```bash
claude --version
```

- 能输出版本号 → 继续
- 命令不存在 → **停下**，告诉用户需要先装 Claude Code

### 0.4 插件系统可用性

```bash
claude plugin --help
```

- 有输出 → 继续
- 报错说没有 `plugin` 子命令 → **停下**，用户版本太旧，需要升级 Claude Code（要 2.1.x 或更新）

---

## 步骤 1：安装

### 方式 A：从 GitHub 装（推荐）

```bash
claude plugin marketplace add riyue248/win-popup
claude plugin install win-popup@win-popup
```

这是最省事的方式 —— Claude Code 自己管理副本，用户**不需要**关心文件夹在哪、也**不会**因为移动文件夹而失效。

### 方式 B：从本地文件夹装

用户如果拿到的是解压出来的目录，把**包含 `.claude-plugin/` 那一层**的绝对路径填进去：

```bash
claude plugin marketplace add "<包路径>"
claude plugin install win-popup@win-popup
```

> ⚠️ 这种方式是**就地加载**的：**装完之后不要移动、改名或删除那个文件夹**，
> 否则插件立刻静默失效。要放别处请**先移动再安装**。

两条命令都应该成功。任一条报错就把**原始错误信息**给用户看，不要反复重试。

---

## 步骤 2：验证

```bash
claude plugin details win-popup
```

**检查 `Hooks` 那一行，必须是 `7`。** 例如：

```
Component inventory
  Skills (0)
  Agents (0)
  Hooks (7)  PermissionRequest, PreToolUse, Notification, UserPromptSubmit, PostToolUse, Stop, SessionEnd
```

> ⚠️ 是 **7** 不是 8 —— 这里显示的是**不同事件名**的数量。
> `Stop` 这个事件挂了两个脚本（一个建弹窗、一个写关闭信号），
> 所以 `hooks.json` 里的条目是 8 个，但事件名只有 7 个。
> 装的人看到 7 是**正常的**，别当成失败。

- 显示 **7** → ✅ 安装成功
- 显示其他数字或 0 → 安装不完整，回到步骤 1 检查路径是否正确

---

## 步骤 3：告诉用户这几件事

1. **要新开一个 Claude Code 会话才生效**（当前已开着的会话需要 `/reload-plugins`）。
2. **不需要做任何操作** —— 它是 hook 插件，Claude Code 自己会触发，没有"调用"这个动作。
3. **会看到什么**：
   - 琥珀色 = 要你确认（命令 / 提问 / 计划批准）
   - 绿色 = 这一轮任务答完了
   - 点窗口上**任何地方** → 跳到对应的终端窗口并关闭
   - **不点就不会消失**，一直留着
4. **配置文件**：`%LOCALAPPDATA%\claude-win-notify\config.json`
   常见的两个开关：
   - `notifyOnStop: false` —— 只在"需要确认"时弹，任务完成不弹
   - `timeoutSeconds: 30` —— 让它 30 秒后自动消失（默认 0 = 永不）
   改完立即生效，不用重启。
5. **日志**（出问题时看这里）：
   - `hook.log` —— 每次事件的判定过程，包括**为什么没弹**
   - `popup.log` —— 弹窗的生命周期，包括**点击后跳去了哪**

---

## 步骤 4：可选 —— 做一次真实验证

可以建议用户：随便让 Claude 做一件需要授权的事（比如删一个临时文件），
弹窗应该立刻出现，点一下应该跳回终端。

如果**没弹**，先看 `%LOCALAPPDATA%\claude-win-notify\hook.log`：
- 文件根本不存在或没有新行 → 回到步骤 0.2 检查执行策略
- 有新行但写着"跳过" → 那是正常的判定逻辑，日志里会写明原因

---

## 已知限制（用户问起时如实说明）

| 限制 | 说明 |
|---|---|
| **仅 Windows** | macOS / Linux 完全不支持 |
| **Windows Terminal 多标签** | 只能把整个终端窗口拉到最前，**切不到具体某个标签页**（系统层面拿不到这个信息） |
| **多显示器** | 弹窗固定出现在主屏右下角 |
| **全屏独占程序** | 游戏 / 全屏播放器里可能看不到 |
| **找不到终端窗口时** | 点击只会关闭、不跳转（**不会跳到错误的地方**）。原因写在 `popup.log` |
| **其他终端** | 跳转功能针对 Windows Terminal 和传统控制台验证过；VS Code 内置终端 / WezTerm / mintty 等**未经验证**，可能只能关闭不能跳转 |

---

## 隐私说明（如果用户问）

- **零网络请求** —— 插件不联网、不上传任何东西、不依赖云服务
- 只在本地写两个日志和一个待弹窗内容文件，全在 `%LOCALAPPDATA%\claude-win-notify\`
- 删掉这个目录即可清空
- **不修改 Claude Code 本身，不接管权限** —— 它只能通知，**不能远程批准任何操作**
