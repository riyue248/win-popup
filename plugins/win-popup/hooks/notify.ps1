#
# win-popup / notify.ps1
#
# Claude Code 需要你确认时，弹一个 Windows 原生置顶窗口。
# 由 hooks.json 以 exec 形式调用，事件 JSON 从 stdin 进来（UTF-8）。
#
# 设计约束：
#   1. 必须快 —— PermissionRequest 会等这个进程返回。真正的窗口是 Start-Process
#      甩出去的子进程，这里只负责拼内容、落盘、发射，然后立刻退出。
#   2. 必须静默 —— 绝不往 stdout 写任何东西，否则会被 Claude Code 当成 hook 决策。
#   3. 绝不能让 hook 报错影响会话 —— 每个可能出错的环节各自 try/catch，
#      所有退出路径都走 Exit-Quiet（exit 0）。注意：这不是一个包住全文的大 try/catch。
#   4. 宁可多弹一次，不能漏弹 —— 漏弹意味着 Claude 卡住而你毫不知情。
#

$ErrorActionPreference = 'Stop'

$StateRoot = Join-Path $env:LOCALAPPDATA 'claude-win-notify'
if (-not (Test-Path $StateRoot)) {
    New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
}

function Exit-Quiet { exit 0 }

# 审计日志：每次触发都记一行「为什么弹 / 为什么没弹」。
# 存在的意义是让「到底什么事件会弹」这件事可验证 —— 尤其是 auto mode 下
# 自动放行的操作到底有没有产生 PermissionRequest，光靠推测不如看日志。
$HookLog = Join-Path $StateRoot 'hook.log'
function Write-HookLog([string]$m) {
    try {
        if ((Test-Path $HookLog) -and (Get-Item $HookLog).Length -gt 256KB) {
            Move-Item $HookLog "$HookLog.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $HookLog -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) -Encoding UTF8
    } catch { }
}

# 大扫除：弹窗被强杀 / 进程崩掉时不会自己清 msg 文件，而残留的 msg 会让
# clear.ps1 永远以为「有弹窗挂着」，此后每回合都写 flag（反过来又会误关新弹窗）。
# 所以定期扫一次。最多每小时跑一次，别给每个事件都加 I/O。
try {
    $marker = Join-Path $StateRoot '.lastgc'
    $needGc = $true
    if (Test-Path $marker) {
        $needGc = ((Get-Date) - (Get-Item $marker).LastWriteTime).TotalHours -ge 1
    }
    if ($needGc) {
        $cutoff = (Get-Date).AddHours(-24)
        Get-ChildItem $StateRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(msg_|clear_|dedupe_).*\.(json|flag)$' -and $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::WriteAllText($marker, '', (New-Object System.Text.UTF8Encoding($false)))
    }
} catch { }

# ---------------------------------------------------------------- 读 stdin
# PowerShell 5.1 的 [Console]::In 走的是控制台代码页（本机是 GBK），
# 中文会变乱码。必须拿原始字节流按 UTF-8 自己解。
try {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { Exit-Quiet }
    $e = $raw | ConvertFrom-Json
} catch {
    # 解析失败也要留痕 —— 否则「明明触发了却没弹窗」会完全查不到原因。
    Write-HookLog ("输入解析失败（hook 协议变了？）: " + $_.Exception.Message)
    Exit-Quiet
}

$session   = [string]$e.session_id
$session   = ($session -replace '[^A-Za-z0-9\-_]', '')   # session_id 会进文件名，先净化
# 净化后可能变空串 —— 那会生成 clear_.flag，而且 popup.ps1 里 "*$session*" 的
# 模糊匹配会退化成 "**"，误杀其它会话的弹窗。给个兜底名字。
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'nosession' }
$eventName = [string]$e.hook_event_name
$toolName  = [string]$e.tool_name
$notifType = [string]$e.notification_type
$cwd       = [string]$e.cwd
$transcript = [string]$e.transcript_path

# ---------------------------------------------------------------- 硬闸门
# 只对「真的在问你要东西」的工具弹窗。
# 这道闸门必须在脚本里再判一次，不能只靠 hooks.json 的 matcher：
#   - matcher 是会话启动时缓存的，改了 hooks.json 要 /reload-plugins 或重开会话才生效
#   - 而脚本每次事件都从磁盘现读
# 所以在脚本里判 = 立即生效，也能挡住 matcher 被改宽后误报（踩过这个坑）。
Write-HookLog "事件=$eventName 工具=$toolName 类型=$notifType 会话=$session"

if ($eventName -eq 'PreToolUse' -and $toolName -ne 'AskUserQuestion' -and $toolName -ne 'ExitPlanMode') {
    Write-HookLog '  └ 跳过：PreToolUse 但不是提问/计划工具'
    Exit-Quiet
}

# 子智能体 / 后台任务里根本没有能互动的聊天框：那里的权限请求会被直接拒绝，
# Claude 自己就往下走了，你没被卡住，不需要知道。
# （判断依据：子智能体的事件里带 agent_id，主会话没有。）
if ($e.agent_id) {
    Write-HookLog "  └ 跳过：子智能体/后台任务（agent_id=$($e.agent_id)），没有可互动的聊天框"
    Exit-Quiet
}

# Stop = 这一轮答完了。用户要求「任务结束后也弹一下」。
# stop_hook_active=true 表示 Claude 是因为某个 stop hook 才继续的，
# 那次 Stop 不是真正的回合结束，跳过（否则会连环弹）。
if ($eventName -eq 'Stop' -and $e.stop_hook_active) {
    Write-HookLog '  └ 跳过：stop_hook_active，这不是真正的回合结束'
    Exit-Quiet
}

# 「任务完成」弹窗可以关掉 —— 有人只想要「卡住了才提醒」，不想要每轮都弹。
# 这个开关对分发给别人用尤其重要：不同人对打扰的容忍度差很多。
if ($eventName -eq 'Stop') {
    $notifyOnStop = $true
    try {
        $cfgFile = Join-Path $StateRoot 'config.json'
        if (Test-Path $cfgFile) {
            $uc = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($uc.PSObject.Properties.Name -contains 'notifyOnStop') {
                $v = $uc.notifyOnStop
                if ($v -is [bool]) { $notifyOnStop = $v }
                elseif ($v -is [string]) { $notifyOnStop = [bool]($v -match '^(?i:true|1|yes|on)$') }
                else { $notifyOnStop = [bool]$v }
            }
        }
    } catch { }
    if (-not $notifyOnStop) {
        Write-HookLog '  └ 跳过：config.notifyOnStop=false，不弹任务完成'
        Exit-Quiet
    }
}

# ---------------------------------------------------------------- 归类
# kind: permission | question | plan | notice
$kind = 'permission'
if ($eventName -eq 'PreToolUse' -and $toolName -eq 'AskUserQuestion') { $kind = 'question' }
elseif ($eventName -eq 'PreToolUse' -and $toolName -eq 'ExitPlanMode') { $kind = 'plan' }
elseif ($eventName -eq 'Notification') { $kind = 'notice' }
elseif ($eventName -eq 'Stop')         { $kind = 'done' }
elseif ($eventName -eq 'PermissionRequest') { $kind = 'permission' }

$nowSec = [long][Math]::Floor(([DateTimeOffset]::UtcNow).ToUnixTimeMilliseconds() / 1000)

# ---------------------------------------------------------------- 文案
function Get-ToolLabel([string]$name) {
    switch -Regex ($name) {
        '^Bash$'                 { '运行命令' }
        '^PowerShell$'           { '运行 PowerShell' }
        '^(Write)$'              { '写入文件' }
        '^(Edit|MultiEdit)$'     { '修改文件' }
        '^Read$'                 { '读取文件' }
        '^NotebookEdit$'         { '修改 Notebook' }
        '^(WebFetch|WebSearch)$' { '联网访问' }
        '^(Task|Agent)$'         { '启动子智能体' }
        '^AskUserQuestion$'      { '向你提问' }
        '^ExitPlanMode$'         { '提交计划待批' }
        '^mcp__'                 { 'MCP 工具' }
        default                  { if ($name) { $name } else { '未知操作' } }
    }
}

$toolLabel = Get-ToolLabel $toolName
$project   = if ($cwd) { Split-Path $cwd -Leaf } else { '' }

# 把 tool_input 里最能说明问题的一段抽出来
$detail = ''
$ti = $e.tool_input
try {
    # 注意：这些分支按【工具】判，不能按【事件类型】判。
    # 同一个 AskUserQuestion 既会走 PreToolUse（kind=question）也会走 PermissionRequest
    # （kind=permission），按 event 判会导致两次抽出的文本不同、去重键不同、去重失效。
    if ($ti.questions) {
        $lines = @()
        foreach ($q in $ti.questions) {
            if ($q.question) { $lines += ('? ' + [string]$q.question) }
            if ($q.options) {
                foreach ($o in $q.options) { if ($o.label) { $lines += ('   - ' + [string]$o.label) } }
            }
        }
        $detail = ($lines -join "`r`n")
    }
    elseif ($ti.plan)       { $detail = [string]$ti.plan }
    elseif ($ti.todos)      {
        $lines = @()
        foreach ($t in $ti.todos) { if ($t.content) { $lines += ('- ' + [string]$t.content) } }
        $detail = ($lines -join "`r`n")
    }
    elseif ($ti.command)    { $detail = [string]$ti.command }
    elseif ($ti.file_path)  { $detail = [string]$ti.file_path }
    elseif ($ti.url)        { $detail = [string]$ti.url }
    elseif ($ti.query)      { $detail = [string]$ti.query }
    elseif ($ti.pattern)    { $detail = [string]$ti.pattern }
    elseif ($ti.description){ $detail = [string]$ti.description }
}
catch { }
if (-not $detail -and $e.message) { $detail = [string]$e.message }
# Stop 事件带 last_assistant_message = Claude 这轮的最终回复原文。
# 官方文档明确建议通知类 hook 用它，而不是去读 transcript_path
# （transcript 在 Stop 时刻不保证已经写入最后一条）。
if (-not $detail -and $e.last_assistant_message) { $detail = [string]$e.last_assistant_message }
if ($detail.Length -gt 700) {
    # 别切在代理对中间 —— emoji 是 UTF-16 双码元，Substring 正好切开会留下孤立代理，
    # 序列化成 JSON 时变成 U+FFFD（显示成一个问号方块）。
    $cut = 700
    if ([char]::IsHighSurrogate($detail[$cut - 1])) { $cut-- }
    $detail = $detail.Substring(0, $cut) + "`r`n..."
}

switch ($kind) {
    'permission' { $title = '需要你确认' }
    'question'   { $title = '有问题要问你' }
    'plan'       { $title = '计划等你批准' }
    'done'       { $title = '任务完成' }
    default      { $title = '需要你处理' }
}

$meta = @()
if ($project) { $meta += $project }
# done 的 toolName 是空的，别把「未知操作」塞进去
if ($kind -ne 'notice' -and $kind -ne 'done') { $meta += $toolLabel }

# 后台还有活没干完时，这一轮 Stop 只是"暂停"而不是"结束"，标注出来
if ($kind -eq 'done') {
    try {
        # ⚠️ 必须先判 null 再取 Count。PowerShell 里 @($null).Count 是 1，
        # 字段缺失时（任务注册表不可达）不加这层判断就会**每轮谎报「后台还有 1 个任务在跑」**。
        if ($null -ne $e.background_tasks) {
            $bg = @($e.background_tasks)
            if ($bg.Count -gt 0) { $meta += "后台还有 $($bg.Count) 个任务在跑" }
        }
        if ($null -ne $e.session_crons) {
            $cr = @($e.session_crons)
            if ($cr.Count -gt 0) { $meta += '有定时任务待触发' }
        }
    } catch { }
}
$metaText = $meta -join '  ·  '

# ---------------------------------------------------------------- 去重
# 同一次确认会触发多个事件，必须只弹一次：
#   - AskUserQuestion / ExitPlanMode：先走 PreToolUse，紧接着走 PermissionRequest
#   - 权限提示：PermissionRequest 之后约 6 秒，Notification 还会补一个 permission_prompt
#
# 关键判据是【事件名是否相同】，而不只是内容是否相同：
#   同一个 key 但事件名不同 = 同一次确认的第二个事件  -> 去重
#   同一个 key 且事件名相同   = 两次独立的新确认      -> 都要弹
# 少了这半条判断，会把「同一条命令重试」「两次内容不同的 TodoWrite」
# （tool_input 里没有可抽取字段，key 退化成 "TodoWrite|"）当成重复静默吞掉，
# 结果就是 Claude 卡住等你、而你毫不知情。
$dedupeFile = Join-Path $StateRoot "dedupe_$session.json"
$keyRaw     = $toolName + '|' + $detail
try {
    $sha      = [System.Security.Cryptography.SHA1]::Create()
    $dedupeKey = ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($keyRaw))) -replace '-', '').Substring(0, 16)
} catch { $dedupeKey = $keyRaw.Substring(0, [Math]::Min(200, $keyRaw.Length)) }

$lastKey   = ''
$lastEvent = ''
$lastAt    = 0
if (Test-Path $dedupeFile) {
    try {
        $last      = Get-Content $dedupeFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $lastKey   = [string]$last.key
        $lastEvent = [string]$last.event
        $lastAt    = [long]$last.at
    } catch { }
}
$age = $nowSec - $lastAt

if ($kind -eq 'notice') {
    # 兜底通知：60 秒内已经报过任何东西就不重复打扰
    if ($lastAt -gt 0 -and $age -lt 60) {
        Write-HookLog "  └ 跳过：兜底通知，${age}s 前已报过"
        Exit-Quiet
    }
} elseif ($lastAt -gt 0 -and $age -lt 15 -and $lastKey -eq $dedupeKey -and $lastEvent -ne $eventName) {
    Write-HookLog "  └ 跳过：同一次确认的重复事件（${age}s 前 $lastEvent 已弹过）"
    Exit-Quiet
}

# ---------------------------------------------------------------- 父进程
# 记下父进程 PID —— 弹窗靠它顺进程链找到「这个会话的终端窗口」，点击时才能跳过去。
# 必须在这里（被闸门筛掉的事件就别付这个钱了）且必须是本进程还活着的时候取：
# 本进程交完差就退出，而弹窗是 Start-Process 甩出去的子进程，
# 等弹窗启动时这条链的第一跳已经断了（查不到 ParentProcessId）。
$parentPid = 0
try {
    $pp = Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction SilentlyContinue
    if ($pp) { $parentPid = [int]$pp.ParentProcessId }
} catch { }
Write-HookLog "  └ 父进程 ppid=$parentPid（弹窗用它定位终端窗口）"

# ---------------------------------------------------------------- 落盘
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
# 带上 PID：同一毫秒内的两个事件光靠时间戳会撞名，后写的覆盖先写的，
# 两个弹窗会显示同一内容、或其中一个报 "msg file missing"。
$msgName   = "msg_${session}_${stamp}_$PID.json"
$msgFile   = Join-Path $StateRoot $msgName
$clearFlag = Join-Path $StateRoot "clear_$session.flag"

# 新消息来了，旧的 clear 标记作废
if (Test-Path $clearFlag) { Remove-Item $clearFlag -Force -ErrorAction SilentlyContinue }

# 上一个弹窗会被新弹窗「顶替」掉 —— 而顶替是 Stop-Process 强杀，
# 被杀的进程没机会跑自己的善后，msg 文件会留在磁盘上。这里替它清掉。
Get-ChildItem $StateRoot -Filter "msg_${session}_*.json" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

$payload = [ordered]@{
    kind       = $kind
    title      = $title
    meta       = $metaText
    detail     = $detail
    time       = (Get-Date -Format 'HH:mm:ss')
    session    = $session
    msgName    = $msgName
    transcript = $transcript
    ppid       = $parentPid
}
$jsonOut = $payload | ConvertTo-Json -Depth 5
# 显式 UTF-8 无 BOM —— PS 5.1 的 Out-File -Encoding UTF8 会带 BOM
[System.IO.File]::WriteAllText($msgFile, $jsonOut, (New-Object System.Text.UTF8Encoding($false)))

# 记录去重状态
@{
    key   = $dedupeKey
    event = $eventName
    at    = $nowSec
} | ConvertTo-Json | ForEach-Object {
    [System.IO.File]::WriteAllText($dedupeFile, $_, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 发射
# 关键：不 -Wait，弹窗是独立进程活着，本进程立刻退出，hook 不阻塞。
try {
    $popup = Join-Path $PSScriptRoot 'popup.ps1'
    $argLine = '-NoProfile -WindowStyle Hidden -File "{0}" -MsgFile "{1}"' -f $popup, $msgFile
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
    Write-HookLog "  └ 弹窗：$title  [$metaText]"
} catch {
    Write-HookLog "  └ 弹窗失败：$($_.Exception.Message)"
}

Exit-Quiet
