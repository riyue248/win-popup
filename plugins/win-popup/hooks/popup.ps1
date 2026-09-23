#
# win-popup / popup.ps1
#
# 真正的弹窗。由 notify.ps1 以独立进程甩出来，所以它可以一直活着等你看。
# 生命周期由四个信号决定：
#   - 你点了它                              -> 关
#   - clear flag 点名要关「这一个」          -> 关（你回终端答了）
#   - transcript 变长了（说明确认已通过）    -> 关
#   - 超时（config.json，默认不超时）
#
# 全程写 popup.log，排查「为什么不弹」就看它。
#

param(
    [Parameter(Mandatory = $true)][string]$MsgFile
)

$StateRoot = Join-Path $env:LOCALAPPDATA 'claude-win-notify'
if (-not (Test-Path $StateRoot)) { New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null }
$LogFile = Join-Path $StateRoot 'popup.log'

function Write-Log([string]$m) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
            Move-Item $LogFile "$LogFile.1" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -Path $LogFile -Value ("{0} [pid {1}] {2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $PID, $m) -Encoding UTF8
    } catch { }
}

trap {
    Write-Log ("FATAL: " + $_.Exception.ToString())
    exit 1
}

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

Write-Log "--- start, MsgFile=$MsgFile"

# config.json 里一个坏值绝不能让整个弹窗罢摆 —— 例如 "timeoutSeconds": "abc"
# 会让 [int] 转换抛错、撞上 ErrorActionPreference='Stop' 的 trap、exit 1，
# 结果就是「改了配置之后再也没弹过」。所有取值都走带默认值的容错函数。
function Get-CfgInt($v, $def) {
    try { if ($null -ne $v -and "$v" -ne '') { return [int]$v } } catch { }
    return $def
}
function Get-CfgBool($v, $def) {
    if ($v -is [bool])   { return $v }
    if ($v -is [string]) { return [bool]($v -match '^(?i:true|1|yes|on)$') }   # "false" 曾被当真值
    if ($v -is [int])    { return ($v -ne 0) }
    return $def
}

# ---------------------------------------------------------------- 读消息
if (-not (Test-Path $MsgFile)) { Write-Log 'msg file missing, exit'; exit 0 }
$m = Get-Content $MsgFile -Raw -Encoding UTF8 | ConvertFrom-Json
$msgName = if ($m.msgName) { [string]$m.msgName } else { Split-Path $MsgFile -Leaf }
Write-Log "msg loaded: kind=$($m.kind) title=$($m.title) name=$msgName"

$session   = [string]$m.session
$clearFlag = Join-Path $StateRoot "clear_$session.flag"

# ---------------------------------------------------------------- 配置
# 默认：只有「你点它」才会关。
# 这是刻意的 —— 会自动消失的提醒等于没有提醒，你离开电脑回来时它已经没了。
# 想恢复自动消失就把对应开关打开。
$timeoutSec      = 0        # 0 = 永不超时
$sound           = $true
$position        = 'bottom-right'
$closeOnClear    = $false   # 你回终端处理了就关
$closeOnProgress = $false   # transcript 变长（确认已通过）就关
$cfgFile = Join-Path $StateRoot 'config.json'
if (Test-Path $cfgFile) {
    try {
        $user = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $timeoutSec      = Get-CfgInt  $user.timeoutSeconds 0
        $sound           = Get-CfgBool $user.sound          $true
        $closeOnClear    = Get-CfgBool $user.closeOnClear    $false
        $closeOnProgress = Get-CfgBool $user.closeOnProgress $false
        if ($user.position) { $position = [string]$user.position }
    } catch { Write-Log "config parse failed, 用默认值: $($_.Exception.Message)" }
}
Write-Log "config: timeout=$timeoutSec position=$position sound=$sound closeOnClear=$closeOnClear closeOnProgress=$closeOnProgress"

# ---------------------------------------------------------------- 收起旧弹窗
# 一次只留一个，免得你离开两小时后回来看到一屏窗口。
# 只收同会话、且比我早启动的。
try {
    $me = (Get-Process -Id $PID).StartTime
    $old = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -like '*popup.ps1*' -and
            $_.CommandLine -clike "*msg_${session}_*" -and   # -clike：会话名大小写敏感，别误杀别的会话
            $_.ProcessId -ne $PID -and
            $_.CreationDate -lt $me
        }
    foreach ($o in $old) {
        Write-Log "closing older popup pid=$($o.ProcessId)"
        Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Log "old-popup sweep failed: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 配色
$accent = switch ([string]$m.kind) {
    'question' { '#4C9AFF' }
    'plan'     { '#9B7BFF' }
    'done'     { '#34C759' }   # 任务完成 = 绿
    default    { '#F5A623' }
}

# ---------------------------------------------------------------- 界面
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Write-Log 'WPF assemblies loaded'

# 关键：拦 WM_MOUSEACTIVATE 返回 MA_NOACTIVATE。
# 否则置顶窗口未激活时，第一次点击会被系统拿去「激活窗口」而不派发给程序，
# 表现就是「点了没反应，得点两次」。顺带的好处是永远不会抢走你的输入焦点。
#
# 这段是纯锦上添花，编译失败绝不能连累弹窗本身：脚本开头把 ErrorActionPreference
# 设成了 Stop，Add-Type 抛错会直接走 trap 退出，结果就是「一个装饰性功能把主功能
# 干掉了」。所以必须自己兜住。
try {
    Add-Type -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

public class NoActivateHook {
    public static void Install(IntPtr hwnd) {
        HwndSource src = HwndSource.FromHwnd(hwnd);
        if (src == null) return;
        src.AddHook(delegate(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
            if (msg == 0x0021) { handled = true; return (IntPtr)3; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE
            return IntPtr.Zero;
        });
    }
}

public class WinJump {
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);

    private const uint GW_OWNER = 4;

    // ⚠️ 必须显式 CharSet.Unicode！默认是 Ansi，而这两个是 W 函数（UTF-16 参数），
    // 不写的话读回来的类名/标题是乱码，跟 "Shell_TrayWnd" 之类的比较永远不成立。
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);

    // 找某个进程的可见顶层窗口（跳过 owned 的 tool window）
    public static long FindForPid(uint pid) {
        long found = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h) && GetWindow(h, GW_OWNER) == IntPtr.Zero) {
                found = h.ToInt64();
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // 找某个 shell 进程真正该跳过去的那个窗口。
    //
    // Windows Terminal 下，shell（cmd/powershell/claude）自己【没有】窗口，
    // 它有一个 class=PseudoConsoleWindow 的窗口，而这个窗口的 owner 才是
    // Windows Terminal 的真窗口（class=CASCADIA_HOSTING_WINDOW_CLASS）。
    // 也就是说：进程树在这里是没用的，得顺着【窗口所有权】走一跳。
    //
    // 注意 PseudoConsoleWindow 是 owned 窗口 —— 上面那个 FindForPid 专门跳过 owned，
    // 所以它永远找不到终端，必须用这个函数。
    public static long FindTerminalForPid(uint pid) {
        long pseudo = 0;
        long plain  = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p != pid || !IsWindowVisible(h)) { return true; }
            var sb = new System.Text.StringBuilder(256);
            GetClassNameW(h, sb, 256);
            string cls = sb.ToString();
            if (cls == "PseudoConsoleWindow") { pseudo = h.ToInt64(); return false; }
            if (GetWindow(h, GW_OWNER) == IntPtr.Zero && plain == 0) { plain = h.ToInt64(); }
            return true;
        }, IntPtr.Zero);
        if (pseudo != 0) {
            long owner = GetWindow(new IntPtr(pseudo), GW_OWNER).ToInt64();
            if (owner != 0) { return owner; }      // Windows Terminal 的真窗口
            return pseudo;                          // 没有 owner，就用它自己
        }
        return plain;                               // 传统 conhost / 带窗口的终端进程
    }

    // 按窗口类名找窗口：**只在全屏有且仅有一个时**才返回它。
    // 用于进程链断掉时的兜底 —— 只有一个终端窗口的话，它几乎必然就是目标；
    // 有多个就不猜（宁可只关闭，也不要跳到错误的终端）。
    public static long FindSingleWindowOfClass(string cls) {
        long found = 0;
        int count = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) { return true; }
            var sb = new System.Text.StringBuilder(256);
            GetClassNameW(h, sb, 256);
            if (sb.ToString() == cls) { count++; found = h.ToInt64(); }
            return true;
        }, IntPtr.Zero);
        return count == 1 ? found : 0;
    }

    public static string ClassOf(long hwnd) {
        var sb = new System.Text.StringBuilder(256);
        GetClassNameW(new IntPtr(hwnd), sb, 256);
        return sb.ToString();
    }

    public static string TitleOf(long hwnd) {
        var sb = new System.Text.StringBuilder(512);
        GetWindowTextW(new IntPtr(hwnd), sb, 512);
        return sb.ToString();
    }

    // SetForegroundWindow 受前台锁限制。裸调用常常就够（用户点弹窗时我们就是前台），
    // 但弹窗装了 MA_NOACTIVATE 不会激活自己，所以再 AttachThreadInput 到当前前台
    // 线程借它的权限兜底。
    public static string Focus(long hwnd) {
        IntPtr h = new IntPtr(hwnd);
        if (IsIconic(h)) ShowWindow(h, 9);            // SW_RESTORE
        uint dummy;
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out dummy);
        uint myThread = GetCurrentThreadId();
        // 返回值只用 ASCII —— Add-Type 把源码写进临时 .cs 时的编码不可控，
        // C# 字符串里放中文有乱码风险。文案交给 PowerShell 那边拼。
        string note = "same-thread";
        bool attached = false;
        if (fgThread != myThread) {
            // 返回 false 只代表这次 attach 没成功，不代表不需要 ——
            // 实测即使 attach 失败，因为用户刚点了弹窗、本进程已获得前台权限，
            // SetForegroundWindow 依然成功。
            attached = AttachThreadInput(myThread, fgThread, true);
            note = attached ? "attach-ok" : "attach-failed";
        }
        bool ok;
        try {
            BringWindowToTop(h);
            ok = SetForegroundWindow(h);
        } finally {
            if (attached) AttachThreadInput(myThread, fgThread, false);
        }
        return "SetForegroundWindow=" + ok + " (" + note + ")";
    }
}
"@
    Write-Log 'C# 编译成功（no-activate hook + 窗口跳转）'
} catch {
    Write-Log "no-activate hook compile FAILED (弹窗照常弹出，只是点击要两下): $($_.Exception.Message)"
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize"
        ShowActivated="False"
        SizeToContent="Height" Width="410" MaxHeight="560">
  <Border CornerRadius="12" Background="#F71B1B22" BorderBrush="#3A3A46" BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="26" ShadowDepth="4" Opacity="0.55" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <Border Height="4" CornerRadius="11,11,0,0" Background="$accent"/>
      <StackPanel Margin="18,13,18,15">
        <StackPanel Orientation="Horizontal">
          <Border Width="8" Height="8" CornerRadius="4" Background="$accent"
                  VerticalAlignment="Center" Margin="0,1,9,0"/>
          <TextBlock x:Name="TitleText" FontSize="15" FontWeight="SemiBold"
                     Foreground="#F2F2F7" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="MetaText" FontSize="11.5" Foreground="#9A9AA8"
                   Margin="17,5,0,0" TextWrapping="Wrap"/>
        <Border x:Name="DetailBox" Background="#FF0D0D13" CornerRadius="7"
                Padding="11,9" Margin="0,11,0,0">
          <ScrollViewer MaxHeight="210" VerticalScrollBarVisibility="Auto">
            <TextBlock x:Name="DetailText" FontFamily="Consolas, Microsoft YaHei UI"
                       FontSize="12" Foreground="#D8D8E2" TextWrapping="Wrap"/>
          </ScrollViewer>
        </Border>
        <Grid Margin="0,11,0,0">
          <TextBlock x:Name="HintText" FontSize="11" Foreground="#6E6E7E"
                     VerticalAlignment="Center"/>
          <TextBlock x:Name="TimeText" FontSize="11" Foreground="#58586A"
                     HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@

$w = [System.Windows.Markup.XamlReader]::Parse($xaml)
Write-Log 'xaml parsed'

$w.FindName('TitleText').Text = [string]$m.title
$w.FindName('MetaText').Text  = [string]$m.meta
$w.FindName('TimeText').Text  = [string]$m.time

$detailText = [string]$m.detail
if ([string]::IsNullOrWhiteSpace($detailText)) {
    $w.FindName('DetailBox').Visibility = 'Collapsed'
} else {
    $w.FindName('DetailText').Text = $detailText
}
Write-Log 'content bound'

# ---------------------------------------------------------------- 找这个会话的终端窗口
# 点击弹窗要跳到「发起这次确认的那个终端」。做法：从 claude 的 node 进程出发，
# 顺着 ParentProcessId 往上爬，第一个有可见顶层窗口的祖先就是终端。
#
# 只能用 notify.ps1 传过来的 ppid 起爬：本进程是 notify 的子进程，但 notify
# 交完差就退出了，从自己往上爬第一跳就断（查不到一个已死进程的父进程）。
# 注意：真正的查找放在窗口显示【之后】的第一次 tick 里做。
# 全量进程快照要 500ms 上下，放在显示前会把弹出硬生生拖慢半秒，
# 而这个查找只影响「点击后跳去哪」，不影响窗口本身何时出现。
$script:targetHwnd = 0
$script:targetName = ''
$script:lookupDone = $false

$w.FindName('HintText').Text = '点击关闭'

# 桌面 / 任务栏这类窗口绝不能跳。
# explorer.exe 常常正好是祖先链上第一个「有窗口的进程」（它的窗口就是任务栏），
# 不排除的话点击会把任务栏拉到前台 —— 第一版就栽在这。
$Script:DesktopClasses = @(
    'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW',
    'Windows.UI.Core.CoreWindow', 'ApplicationManager_DesktopShellWindow'
)

function Test-UsableWindow([int64]$h) {
    if ($h -eq 0) { return $false }
    $cls = [WinJump]::ClassOf($h)
    if ($Script:DesktopClasses -contains $cls) {
        Write-Log "  跳过桌面/任务栏窗口 hwnd=$h class=$cls"
        return $false
    }
    return $true
}

function Find-SessionWindow {
    try {
        $ppid = [int]$m.ppid
        if ($ppid -le 0) { Write-Log '没有 ppid，无法定位会话窗口'; return }

        # 一次全量快照建两张表：往上找父、往下找子
        $parents  = @{}
        $children = @{}
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
            $cp = [int]$_.ProcessId
            $pp = [int]$_.ParentProcessId
            $parents[$cp] = $pp
            if (-not $children.ContainsKey($pp)) { $children[$pp] = New-Object System.Collections.ArrayList }
            [void]$children[$pp].Add([pscustomobject]@{ pid = $cp; name = [string]$_.Name })
        }

        $cur = $ppid
        $hop = 0
        while ($cur -gt 0 -and $hop -lt 10) {
            $pn = (Get-Process -Id $cur -ErrorAction SilentlyContinue).ProcessName

            # ① 祖先自己的窗口 —— Windows Terminal / VS Code / mintty 这类终端的窗口
            #    属于终端进程本身，它在链上，直接命中。
            if ($pn -and $pn -ne 'explorer') {
                # FindTerminalForPid 会顺着 PseudoConsoleWindow 的 owner 一跳，
                # 拿到 Windows Terminal 的真窗口；传统 conhost 下则直接拿自己的窗口。
                $h = [WinJump]::FindTerminalForPid([uint32]$cur)
                if (Test-UsableWindow $h) {
                    $script:targetHwnd = $h
                    $script:targetName = $pn
                    Write-Log "找到会话窗口: pid=$cur ($pn) hwnd=$h class=$([WinJump]::ClassOf($h)) (爬了 $hop 层)"
                    $w.FindName('HintText').Text = "点击跳转到该会话（$pn）"
                    return
                }
            }

            # ② 祖先的 conhost / OpenConsole 子进程的窗口。
            #    ⚠️ 这一步是关键：Windows 上普通控制台窗口归 conhost.exe 所有，
            #    而 conhost 是控制台程序的【子进程】—— 只往上爬永远够不到它。
            if ($children.ContainsKey($cur)) {
                foreach ($c in $children[$cur]) {
                    if ($c.name -match '^(conhost|OpenConsole|WindowsTerminal)\.exe$') {
                        $h = [WinJump]::FindForPid([uint32]$c.pid)
                        if (Test-UsableWindow $h) {
                            $script:targetHwnd = $h
                            $script:targetName = $c.name -replace '\.exe$', ''
                            Write-Log "找到会话窗口(经 conhost): 祖先pid=$cur ($pn) -> $($c.name) hwnd=$h"
                            $w.FindName('HintText').Text = "点击跳转到该会话（$($script:targetName)）"
                            return
                        }
                    }
                }
            }

            if (-not $parents.ContainsKey($cur)) { Write-Log "进程链在 pid=$cur 断了（该进程可能已退出），试兜底"; break }
            $cur = [int]$parents[$cur]
            $hop++
        }

        # 兜底：链断了（中间某个进程已退出）时，如果屏幕上只有一个 Windows Terminal 窗口，
        # 那它几乎必然就是目标。**只在唯一时才用** —— 有多个就不猜，宁可不跳也不跳错。
        $fb = [WinJump]::FindSingleWindowOfClass('CASCADIA_HOSTING_WINDOW_CLASS')
        if (Test-UsableWindow $fb) {
            $script:targetHwnd = $fb
            $script:targetName = 'WindowsTerminal'
            Write-Log "找到会话窗口(兜底：全屏唯一终端窗口) hwnd=$fb"
            $w.FindName('HintText').Text = '点击跳转到终端窗口'
            return
        }

        Write-Log "没找到会话窗口（ppid=$ppid 往上爬了 $hop 层，兜底也没命中）"
    } catch { Write-Log "找窗口失败: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 摆位
$script:placed = $false
$w.Add_ContentRendered({
    try {
        $wa = [System.Windows.SystemParameters]::WorkArea
        switch ($position) {
            'center' {
                $w.Left = $wa.Left + ($wa.Width  - $w.ActualWidth)  / 2
                $w.Top  = $wa.Top  + ($wa.Height - $w.ActualHeight) / 2
            }
            'top-right' {
                $w.Left = $wa.Right - $w.ActualWidth - 22
                $w.Top  = $wa.Top + 22
            }
            'top-left' {
                $w.Left = $wa.Left + 22
                $w.Top  = $wa.Top + 22
            }
            default {
                $w.Left = $wa.Right  - $w.ActualWidth  - 22
                $w.Top  = $wa.Bottom - $w.ActualHeight - 22
            }
        }
        $script:placed = $true
        Write-Log ("rendered: size=$([int]$w.ActualWidth)x$([int]$w.ActualHeight) at ($([int]$w.Left),$([int]$w.Top))")
    } catch {
        Write-Log "place failed: $($_.Exception.Message)"
    }
})

# 装 no-activate 钩子（必须在窗口有 hwnd 之后）
$w.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($w)
        [NoActivateHook]::Install($helper.Handle)
        Write-Log 'no-activate hook installed'
    } catch { Write-Log "no-activate hook failed: $($_.Exception.Message)" }
})

# 点窗口上【任何地方】都行：先把终端窗口拉到前台，再关掉自己。
#
# ⚠️ 必须用【隧道】事件 PreviewMouseLeftButtonDown，不能用冒泡的 MouseLeftButtonDown。
# 正文框里的 DetailText（TextBlock + ScrollViewer）会把 MouseLeftButtonDown 标记为
# Handled，事件就再也冒泡不到 Window 了 —— 表现就是「点正文文字完全没反应」。
# 实测：20 次点击只有 13 次冒泡成功，丢掉的那 7 次正好都是打在 DetailText 上的。
# 隧道事件从根往叶子走，Window 先拿到，任何子元素都拦不住。
$w.Add_PreviewMouseLeftButtonDown({
    # 例外：点在滚动条上时不关窗。
    # Preview 是隧道事件、无条件 Close，会把「拖滚动条看长命令」也吃掉 ——
    # 700 字的正文超过 210px 就会出滚动条，那时用户想滚动而不是跳转。
    try {
        $pt = $_.GetPosition($w)
        $hitEl = $w.InputHitTest($pt)
        $node = $hitEl
        for ($i = 0; $i -lt 8 -and $node; $i++) {
            if ($node -is [System.Windows.Controls.Primitives.ScrollBar]) {
                Write-Log '点击落在滚动条上，不关窗'
                return
            }
            $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
        }
    } catch { }
    try {
        # 跳转目标是在第一次 timer tick 里算的（全量进程快照 ~500ms）。
        # 如果你在弹窗刚出现的那一秒内就点了，目标还没算出来 —— 那就会「点了但没跳」，
        # 表现出来就是随机失灵。所以这里补算一次再关，不让它漏。
        # 没有目标就【再找一次】——不只是"还没找过"时补算。
        # 第一次查找可能因为进程链瞬时状态而失败；点击时环境可能已经变了。
        # 多花 500ms 换一次真正的跳转，值得。
        if ($script:targetHwnd -eq 0) {
            $script:lookupDone = $true
            Find-SessionWindow
        }
        if ($script:targetHwnd -ne 0) {
            $r = [WinJump]::Focus([int64]$script:targetHwnd)
            Write-Log "跳转到会话窗口: $r"
        } else {
            Write-Log '没有跳转目标，只关闭'
        }
    } catch { Write-Log "跳转失败: $($_.Exception.Message)" }
    $script:reason = 'clicked'
    $w.Close()
})

# ---------------------------------------------------------------- 声音
if ($sound) {
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    $beep = New-Object System.Windows.Threading.DispatcherTimer
    $beep.Interval = [TimeSpan]::FromMilliseconds(900)
    $beep.Add_Tick({
        $beep.Stop()
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    })
    $beep.Start()
}

# ---------------------------------------------------------------- 进度探测
# 批准一个权限之后，Bash/Write 这类弹窗要等回合结束（Stop）才会被清掉，
# 中间可能挂着好几分钟，窗口上那句「操作通过后自动消失」就成了假话。
# 这里直接盯 transcript：卡住时它不增长，一旦增长就说明这个确认已经过去了。
# 不需要额外挂 hook，每 600ms 看一眼文件大小而已。
$watchedPath = ''
$watchedLen  = -1
if ($closeOnProgress -and [string]$m.kind -eq 'permission' -and $m.transcript) {
    try {
        $tp = [string]$m.transcript
        if (Test-Path $tp) {
            $watchedPath = $tp
            $watchedLen  = (Get-Item $tp).Length
            Write-Log "watching transcript, initial=$watchedLen"
        }
    } catch { }
}

# ---------------------------------------------------------------- 轮询
$script:ticks = 0
$script:elapsed = 0.0
$script:reason = 'unknown'
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(600)
$timer.Add_Tick({
    $script:ticks++
    $script:elapsed += 0.6

    # 第一次 tick 才去找会话窗口 —— 把 500ms 的进程快照从「弹出前」挪到「弹出后」
    if (-not $script:lookupDone) {
        $script:lookupDone = $true
        Find-SessionWindow
    }

    if ($timeoutSec -gt 0 -and $script:elapsed -ge $timeoutSec) {
        $script:reason = 'timeout'; $w.Close(); return
    }

    # clear flag 现在点名关哪一个：只有写着我这个 msg 名字的才认。
    # 否则并发的 clear（它的「有无弹窗」判断早于新弹窗落盘、写 flag 晚于它）
    # 会把刚冒出来的新弹窗在第一次 tick 就关掉，通知等于白发。
    if (Test-Path $clearFlag) {
        try {
            $txt = Get-Content $clearFlag -Raw -Encoding UTF8
            # FORCEALL：连名字都不对，本会话的弹窗一律关。
            # 用于 msg 文件已被大扫除清掉、没法点名的场合。
            if ($txt -and ($txt.StartsWith('FORCEALL') -or $txt -like "*$msgName*")) {
                # SessionEnd 写的 flag 带 FORCE 前缀：会话都结束了，这时必须关 ——
                # 否则弹窗永远留在屏幕上，而且已经没有会话可以跳过去了。
                if ($closeOnClear -or $txt.StartsWith('FORCE')) {
                    $script:reason = 'cleared'; $w.Close(); return
                }
            }
        } catch { }
    }

    if ($closeOnProgress -and $watchedPath) {
        try {
            if (Test-Path $watchedPath) {
                $len = (Get-Item $watchedPath).Length
                if ($len -gt $watchedLen) {
                    $script:reason = 'progress'; $w.Close(); return
                }
            }
        } catch { }
    }

    if ($script:ticks -le 2) { Write-Log "tick $($script:ticks): placed=$($script:placed) visible=$($w.IsVisible)" }
})
$timer.Start()

Write-Log 'entering ShowDialog'

$w.ShowDialog() | Out-Null

Write-Log "closed: reason=$($script:reason) after $([int]$script:elapsed)s"

# ---------------------------------------------------------------- 善后
try {
    Remove-Item $MsgFile -Force -ErrorAction SilentlyContinue
    # 这个 flag 是给我自己的，用完就撤；如果它其实是给更新的弹窗的，别动它
    if (Test-Path $clearFlag) {
        $txt = Get-Content $clearFlag -Raw -Encoding UTF8
        if ($txt -and $txt -like "*$msgName*") { Remove-Item $clearFlag -Force -ErrorAction SilentlyContinue }
    }
} catch { }

Write-Log 'cleanup done'
