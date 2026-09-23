#
# win-popup / clear.ps1
#
# 你已经回到终端了 —— 把还挂着的弹窗收掉。
# 挂在 UserPromptSubmit / Stop / PostToolUse(AskUserQuestion|ExitPlanMode) 上，
# 都是低频事件，不会拖慢工具调用。
#
# flag 里写的不是「关掉一切」，而是**具体哪几个 msg 文件该关**（点名的）。
# 原因是竞态：新弹窗从落盘到第一次轮询要 1.5~1.8 秒，如果这期间有个并发 clear
# 写了无差别 flag，新弹窗会在第一次 tick 就自杀 —— 通知等于没发出去。
# 点名之后，写给旧弹窗的 flag 不会误伤新弹窗。
#

$ErrorActionPreference = 'Stop'

try {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
    $e = $raw | ConvertFrom-Json
    $session = [string]$e.session_id
    $event   = [string]$e.hook_event_name
} catch { exit 0 }

$session = ($session -replace '[^A-Za-z0-9\-_]', '')
if ([string]::IsNullOrWhiteSpace($session)) { $session = 'nosession' }   # 与 notify.ps1 保持一致

$StateRoot = Join-Path $env:LOCALAPPDATA 'claude-win-notify'
if (-not (Test-Path $StateRoot)) { exit 0 }

$isEnd = ($event -eq 'SessionEnd')

# ⚠️ 只清「已经存在一会儿」的弹窗，刚冒出来的不算。
# 原因：Stop 同时挂了 notify.ps1（建弹窗）和本脚本（写关闭信号）。
# 不加这层时间守卫的话，clear 会在 notify 落盘后立刻把新弹窗的名字写进 flag ——
# 开了 closeOnClear 时，那个「任务完成」弹窗会在第一个 tick（600ms）就自杀。
# 「你回来了」这个语义只对**之前就挂着**的弹窗成立。
$minAge = 5
$pending = @(Get-ChildItem $StateRoot -Filter "msg_${session}_*.json" -ErrorAction SilentlyContinue |
    Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -ge $minAge })

# 没有挂着的弹窗就什么都不做（留着 flag 只会让下一个弹窗秒关）。
# 但 SessionEnd 例外：大扫除可能已经把活弹窗的 msg 文件清掉了（超过 24 小时），
# 此时 pending 为空、弹窗却还在屏幕上 —— 不写这条 flag，那个弹窗就永远关不掉了。
if ($pending.Count -eq 0 -and -not $isEnd) { exit 0 }

$flag = Join-Path $StateRoot "clear_$session.flag"
$names = ($pending | ForEach-Object { $_.Name }) -join "`n"
# 非 SessionEnd 的 clear 只是「你回终端了」—— 用户明确要求「不点击就不消失」，
# 所以弹窗默认不认这种 flag。
# FORCE 前缀 = 一定关（会话都结束了，留着弹窗既没意义也没东西可跳转）。
# FORCEALL = 连名字都不用对，本会话所有弹窗全关 —— 用于 msg 文件已丢失的情况。
$prefix = if ($isEnd) { "FORCEALL`n" } else { '' }
[System.IO.File]::WriteAllText($flag, ($prefix + $names), (New-Object System.Text.UTF8Encoding($false)))

# 诊断：会话结束时把真实的祖先链记一行。
# 弹窗能不能「点击跳回终端」全靠这条链 —— 而不同终端/不同启动方式的拓扑差别很大，
# 只有真实会话的数据才算数。每会话一行，开销可忽略。
if ($isEnd) {
    try {
        $parents = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            ForEach-Object { $parents[[int]$_.ProcessId] = @{ pp = [int]$_.ParentProcessId; nm = [string]$_.Name } }
        $chain = @("hook($PID)")
        $cur = $PID
        for ($i = 0; $i -lt 8; $i++) {
            if (-not $parents.ContainsKey($cur)) { $chain += '(断)'; break }
            $cur = [int]$parents[$cur].pp
            if ($cur -le 0) { break }
            if (-not $parents.ContainsKey($cur)) { $chain += "pid=$cur(已退出)"; break }
            $chain += "$($parents[$cur].nm)($cur)"
            if ($parents[$cur].nm -match '^(explorer|WindowsTerminal|Code|wezterm|wt|mintty)\.exe$') { break }
        }
        # 顺带看看 hook 进程自己能不能直接拿到控制台窗口 ——
        # 能拿到的话，定位终端就完全不用爬进程链（最可靠的一条路）。
        $con = ''
        try {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ConProbe {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
"@ -ErrorAction SilentlyContinue
            $cw = [ConProbe]::GetConsoleWindow().ToInt64()
            $con = " GetConsoleWindow=$cw"
        } catch { $con = ' GetConsoleWindow=(编译失败)' }

        Add-Content -Path (Join-Path $StateRoot 'hook.log') `
            -Value ("{0} 会话结束 祖先链: {1}{2}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), ($chain -join ' <- '), $con) -Encoding UTF8
    } catch { }
}

# 兜底：弹窗进程如果已经死了（被任务管理器杀掉之类），标记会永远留着。
# 顺手清理超过 10 分钟还没人认领的。
try {
    $stale = Get-ChildItem $StateRoot -Filter 'clear_*.flag' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) }
    foreach ($f in $stale) {
        $sid = $f.BaseName -replace '^clear_', ''
        if (-not (Get-ChildItem $StateRoot -Filter "msg_${sid}_*.json" -ErrorAction SilentlyContinue)) {
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        }
    }
} catch { }

exit 0
