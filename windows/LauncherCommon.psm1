#Requires -Version 7.0
#
# LauncherCommon.psm1 — shared engine behind `claude-launcher.ps1` and
# `copilot-launcher.ps1`. Windows port of `launcher-common.sh`; see
# docs/windows-port-plan.md for the full design. Tiles windows on the
# current desktop:
#
#   Left half   -> Visual Studio Code, opened on the target folder.
#   Right half  -> Windows Terminal console(s), each running an AI coding CLI
#                  in that folder (which CLI, and with which flags, is the
#                  ONLY part that differs between launchers — see the
#                  `-BuildCommand` hook consumed by Invoke-LauncherMain).
#
# Two layouts, chosen from the monitor's effective (DPI-independent) width:
#
#   grid     (wide display)   FOUR consoles over the right half, arranged
#                              2x2. Realized either as one Windows Terminal
#                              window split into four panes (${PREFIX}_GRID_MODE
#                              = panes, default) or as four separate tiled
#                              windows (${PREFIX}_GRID_MODE = windows).
#   stacked  (narrow display) ONE console over the whole right half.
#
# There is no virtual-desktop handling: VS Code and Windows Terminal always
# open on the desktop that is currently active, so "current Space" behavior on
# macOS falls out for free on Windows.
#
# ---------------------------------------------------------------------------
# Contract for a launcher wrapper script
# ---------------------------------------------------------------------------
# A wrapper (e.g. claude-launcher.ps1) imports this module and calls:
#
#   Invoke-LauncherMain -Name <string> -EnvPrefix <string> -Usage <string> `
#       -Record <bool> -BuildCommand <scriptblock> -Folder <string> -ToolArgs <string[]>
#
# `-BuildCommand` is invoked as `& $BuildCommand $folder $ToolArgs` and MUST
# return either:
#   * $null                                    — no CLI available; the engine
#                                                 opens a plain interactive
#                                                 shell instead.
#   * [PSCustomObject]@{ Exe = <path>; Args = <string[]> }
#                                               — the CLI binary and its
#                                                 arguments, run under the
#                                                 keep-awake wrapper.
#
# Environment overrides honored (namespaced by ${EnvPrefix}):
#   ${PREFIX}_LAYOUT     auto (default) | grid | stacked
#   ${PREFIX}_MIN_COL    minimum console width in DIP/points that `auto`
#                        requires before it chooses the grid (default 640)
#   ${PREFIX}_GRID_MODE  panes (default) | windows — how a `grid` layout is
#                        realized (see above)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'LauncherCommon.psm1 requires Windows.'
}

# ---------------------------------------------------------------------------
# Win32 interop (Phase 1). One P/Invoke block, loaded once per process.
# ---------------------------------------------------------------------------
if (-not ('LauncherWin32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LauncherWin32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("shcore.dll")]
    public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@ -ErrorAction Stop
}

# Win32 constants used throughout this module.
$script:SW_RESTORE = 9
$script:SWP_NOZORDER = 0x0004
$script:SWP_NOACTIVATE = 0x0010
$script:WM_CLOSE = 0x0010
$script:MONITOR_DEFAULTTONEAREST = 2
$script:MDT_EFFECTIVE_DPI = 0
$script:DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = [IntPtr]::new(-4)
$script:ES_CONTINUOUS = 2147483648   # 0x80000000 — decimal, so it parses positive (see Keep-Awake.ps1)
$script:ES_SYSTEM_REQUIRED = 0x00000001
$script:CASCADIA_HOSTING_WINDOW_CLASS = 'CASCADIA_HOSTING_WINDOW_CLASS'
$script:DWMWA_EXTENDED_FRAME_BOUNDS = 9

# Per-monitor DPI awareness must be set before any geometry read, or every
# measurement returns DPI-virtualized and every window lands wrong.
[void][LauncherWin32]::SetProcessDpiAwarenessContext($script:DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# ConvertTo-LauncherLiteral <value>
#   Escape a string for embedding inside a single-quoted PowerShell string
#   literal (doubles embedded single quotes). Used everywhere a path built
#   from user input (folder, plugin dir, ...) is written into a generated
#   pane script, so a maliciously-named directory cannot break out of the
#   literal and inject further PowerShell.
# ---------------------------------------------------------------------------
function ConvertTo-LauncherLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "''")
}

# ---------------------------------------------------------------------------
# Get-LauncherGeometry
#   Read the working area (taskbar-aware, the analog of NSScreen.visibleFrame)
#   of the monitor under the cursor, plus its DPI scale factor. Returns both
#   physical-pixel and effective/DIP width, since the grid-vs-stacked test
#   must compare against effective width (see docs/windows-port-plan.md §4).
# ---------------------------------------------------------------------------
function Get-LauncherGeometry {
    [CmdletBinding()]
    param()

    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $wa = $screen.WorkingArea

    $pt = [LauncherWin32+POINT]@{ X = $cursor.X; Y = $cursor.Y }
    $hMonitor = [LauncherWin32]::MonitorFromPoint($pt, $script:MONITOR_DEFAULTTONEAREST)

    [uint32]$dpiX = 96
    [uint32]$dpiY = 96
    [void][LauncherWin32]::GetDpiForMonitor($hMonitor, $script:MDT_EFFECTIVE_DPI, [ref]$dpiX, [ref]$dpiY)
    $scaleFactor = $dpiX / 96.0
    if ($scaleFactor -le 0) { $scaleFactor = 1.0 }

    [PSCustomObject]@{
        X               = $wa.X
        Y               = $wa.Y
        Width           = $wa.Width
        Height          = $wa.Height
        ScaleFactor     = $scaleFactor
        EffectiveWidth  = [double]$wa.Width / $scaleFactor
        EffectiveHeight = [double]$wa.Height / $scaleFactor
    }
}

# ---------------------------------------------------------------------------
# Select-LauncherLayout <geometry> <envPrefix>
#   Apply the `width / 4 >= MinCol` test against effective width. Honors
#   ${PREFIX}_LAYOUT (auto/grid/stacked) and ${PREFIX}_MIN_COL, same as the
#   macOS engine.
# ---------------------------------------------------------------------------
function Select-LauncherLayout {
    param(
        [Parameter(Mandatory)]$Geometry,
        [Parameter(Mandatory)][string]$Prefix
    )

    $layout = [Environment]::GetEnvironmentVariable("${Prefix}_LAYOUT")
    if ([string]::IsNullOrEmpty($layout)) { $layout = 'auto' }

    $minCol = 640
    $minColRaw = [Environment]::GetEnvironmentVariable("${Prefix}_MIN_COL")
    if (-not [string]::IsNullOrEmpty($minColRaw)) {
        $parsed = 0
        if ([int]::TryParse($minColRaw, [ref]$parsed)) { $minCol = $parsed }
    }

    switch ($layout) {
        'auto' {
            if (($Geometry.EffectiveWidth / 4) -ge $minCol) { return 'grid' } else { return 'stacked' }
        }
        'grid' { return 'grid' }
        'stacked' { return 'stacked' }
        default {
            throw "${Prefix}_LAYOUT must be auto, grid, or stacked (got '$layout')"
        }
    }
}

# ---------------------------------------------------------------------------
# Get-LauncherGridMode <envPrefix>
#   ${PREFIX}_GRID_MODE: panes (default, one WT window split 2x2) | windows
#   (four separate tiled WT windows, macOS parity).
# ---------------------------------------------------------------------------
function Get-LauncherGridMode {
    param([Parameter(Mandatory)][string]$Prefix)

    $gridMode = [Environment]::GetEnvironmentVariable("${Prefix}_GRID_MODE")
    if ([string]::IsNullOrEmpty($gridMode)) { $gridMode = 'panes' }
    if ($gridMode -notin @('panes', 'windows')) {
        throw "${Prefix}_GRID_MODE must be panes or windows (got '$gridMode')"
    }
    return $gridMode
}

# ---------------------------------------------------------------------------
# Get-LauncherWindows
#   Snapshot every visible top-level window: Hwnd, ClassName, Title, ProcessId.
#   The building block Get-TopLevelWindows and Wait-ForNewWindow filter down
#   from.
# ---------------------------------------------------------------------------
function Get-LauncherWindows {
    [CmdletBinding()]
    param()

    $list = [System.Collections.Generic.List[object]]::new()
    $callback = {
        param($hWnd, $lParam)
        if ([LauncherWin32]::IsWindowVisible($hWnd)) {
            $classBuf = New-Object System.Text.StringBuilder 256
            [void][LauncherWin32]::GetClassName($hWnd, $classBuf, $classBuf.Capacity)
            $titleLen = [LauncherWin32]::GetWindowTextLength($hWnd)
            $titleBuf = New-Object System.Text.StringBuilder ($titleLen + 1)
            [void][LauncherWin32]::GetWindowText($hWnd, $titleBuf, $titleBuf.Capacity)
            [uint32]$procId = 0
            [void][LauncherWin32]::GetWindowThreadProcessId($hWnd, [ref]$procId)
            $list.Add([PSCustomObject]@{
                Hwnd      = $hWnd
                ClassName = $classBuf.ToString()
                Title     = $titleBuf.ToString()
                ProcessId = $procId
            })
        }
        return $true
    }.GetNewClosure()

    $delegate = [LauncherWin32+EnumWindowsProc]$callback
    [void][LauncherWin32]::EnumWindows($delegate, [IntPtr]::Zero)
    # The comma forces this array through the pipeline as ONE object, so a
    # 0- or 1-element result reaches the caller as an array and not $null/a
    # scalar (PowerShell otherwise enumerates array returns).
    return , $list.ToArray()
}

# ---------------------------------------------------------------------------
# Get-TopLevelWindows [-ClassName] [-ProcessName]
#   Get-LauncherWindows filtered by window class and/or owning process name.
# ---------------------------------------------------------------------------
function Get-TopLevelWindows {
    param(
        [string]$ClassName,
        [string]$ProcessName
    )

    $all = Get-LauncherWindows
    if ($ClassName) {
        $all = @($all | Where-Object { $_.ClassName -eq $ClassName })
    }
    if ($ProcessName) {
        $all = @($all | Where-Object {
                try { (Get-Process -Id $_.ProcessId -ErrorAction Stop).ProcessName -eq $ProcessName }
                catch { $false }
            })
    }
    return , $all
}

# ---------------------------------------------------------------------------
# Wait-ForNewWindow
#   Poll until at least -Count windows matching -ClassName/-ProcessName/
#   -TitleContains appear that were not present in -Before, or the timeout
#   elapses. Returns whatever matched (possibly fewer than -Count).
# ---------------------------------------------------------------------------
function Wait-ForNewWindow {
    param(
        [string]$ClassName,
        [string]$ProcessName,
        [string]$TitleContains,
        [AllowNull()][object[]]$Before = @(),
        [int]$TimeoutSeconds = 8,
        [int]$Count = 1
    )

    $beforeArr = @($Before)
    $beforeSet = [System.Collections.Generic.HashSet[IntPtr]]::new([IntPtr[]]@($beforeArr | ForEach-Object { $_.Hwnd }))
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $matched = @()
    while ((Get-Date) -lt $deadline) {
        $current = Get-TopLevelWindows -ClassName $ClassName -ProcessName $ProcessName
        $matched = @($current | Where-Object {
                (-not $beforeSet.Contains($_.Hwnd)) -and
                ([string]::IsNullOrEmpty($TitleContains) -or $_.Title -like "*$TitleContains*")
            })
        if ($matched.Count -ge $Count) { return , $matched }
        Start-Sleep -Milliseconds 200
    }
    return , $matched
}

# ---------------------------------------------------------------------------
# Get-LauncherWindowBorderMargins <hwnd>
#   Windows 10/11 wraps most top-level windows in an invisible resize border
#   that GetWindowRect includes but nothing ever draws — so tiling two windows
#   edge-to-edge by that rect leaves a visible gap between their real borders.
#   DWMWA_EXTENDED_FRAME_BOUNDS gives the actual visible bounds; the delta
#   against GetWindowRect is the margin Set-WindowRect must compensate for.
#   Falls back to zero margins if either call fails (e.g. DWM composition off).
# ---------------------------------------------------------------------------
function Get-LauncherWindowBorderMargins {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)

    $zero = [PSCustomObject]@{ Left = 0; Top = 0; Right = 0; Bottom = 0 }

    $winRect = New-Object LauncherWin32+RECT
    if (-not [LauncherWin32]::GetWindowRect($Hwnd, [ref]$winRect)) { return $zero }

    $frameRect = New-Object LauncherWin32+RECT
    $rectSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'LauncherWin32+RECT')
    $hr = [LauncherWin32]::DwmGetWindowAttribute($Hwnd, $script:DWMWA_EXTENDED_FRAME_BOUNDS, [ref]$frameRect, $rectSize)
    if ($hr -ne 0) { return $zero }

    [PSCustomObject]@{
        Left   = $frameRect.Left - $winRect.Left
        Top    = $frameRect.Top - $winRect.Top
        Right  = $winRect.Right - $frameRect.Right
        Bottom = $winRect.Bottom - $frameRect.Bottom
    }
}

# ---------------------------------------------------------------------------
# Set-WindowRect
#   Position/size a window so its VISIBLE edges land on (X, Y, Width, Height)
#   — not its non-client rect, which is what SetWindowPos otherwise places.
#   ShowWindow(SW_RESTORE) first: a maximized window silently ignores
#   SetWindowPos.
# ---------------------------------------------------------------------------
function Set-WindowRect {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    [void][LauncherWin32]::ShowWindow($Hwnd, $script:SW_RESTORE)

    $margins = Get-LauncherWindowBorderMargins -Hwnd $Hwnd
    $adjX = $X - $margins.Left
    $adjY = $Y - $margins.Top
    $adjWidth = $Width + $margins.Left + $margins.Right
    $adjHeight = $Height + $margins.Top + $margins.Bottom

    [void][LauncherWin32]::SetWindowPos(
        $Hwnd, [IntPtr]::Zero, $adjX, $adjY, $adjWidth, $adjHeight,
        ($script:SWP_NOZORDER -bor $script:SWP_NOACTIVATE))
}

# ---------------------------------------------------------------------------
# Resolve-LauncherWindowOwnership <hwnds>
#   Build the ownership triple (HWND, PID, PID start time) for each window —
#   strictly stronger proof than macOS's (window id, tty) pair, since Windows
#   never recycles PID+StartTime together.
# ---------------------------------------------------------------------------
function Resolve-LauncherWindowOwnership {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Hwnds)

    $result = @()
    foreach ($h in $Hwnds) {
        [uint32]$procId = 0
        [void][LauncherWin32]::GetWindowThreadProcessId($h, [ref]$procId)
        $startTime = $null
        try { $startTime = (Get-Process -Id $procId -ErrorAction Stop).StartTime } catch {}
        $result += [PSCustomObject]@{
            Hwnd      = $h
            ProcessId = [int]$procId
            StartTime = $startTime
        }
    }
    return , $result
}

# ---------------------------------------------------------------------------
# Test-LauncherWindowOwnership
#   Verify a recorded (HWND, PID, StartTime) triple still holds before a
#   teardown touches the window: IsWindow, the owning PID unchanged, and (if
#   known) the process start time unchanged.
# ---------------------------------------------------------------------------
function Test-LauncherWindowOwnership {
    param(
        [Parameter(Mandatory)][IntPtr]$Hwnd,
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()][Nullable[datetime]]$StartTime
    )

    if (-not [LauncherWin32]::IsWindow($Hwnd)) { return $false }

    [uint32]$actualPid = 0
    [void][LauncherWin32]::GetWindowThreadProcessId($Hwnd, [ref]$actualPid)
    if ([int]$actualPid -ne $ProcessId) { return $false }

    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($StartTime -and $proc.StartTime -ne $StartTime) { return $false }
    }
    catch {
        return $false
    }
    return $true
}

# ---------------------------------------------------------------------------
# Close-LauncherWindow
#   WM_CLOSE, never a force-kill — the loaded gun the original deliberately
#   refuses. If the window ignores it, it is left standing.
# ---------------------------------------------------------------------------
function Close-LauncherWindow {
    param([Parameter(Mandatory)][IntPtr]$Hwnd)
    [void][LauncherWin32]::PostMessage($Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

# ---------------------------------------------------------------------------
# New-LauncherPaneScript <folder> <command-text>
#   Write a console's startup code to a temp .ps1, run as
#   `pwsh -NoExit -File <path>`. Sidesteps both `wt`'s `;`-splitting and
#   PowerShell quoting in one move (see docs/windows-port-plan.md §3).
# ---------------------------------------------------------------------------
function New-LauncherPaneScript {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CommandText
    )

    $dir = Join-Path $env:TEMP 'claude-launcher'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ("pane-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))

    $folderLiteral = ConvertTo-LauncherLiteral $Folder
    $content = "Set-Location -LiteralPath '$folderLiteral'`n$CommandText`n"
    Set-Content -LiteralPath $path -Value $content -Encoding utf8
    return $path
}

# ---------------------------------------------------------------------------
# Resolve-VSCodeCommand
#   `code.cmd` on PATH, else the two well-known install locations.
# ---------------------------------------------------------------------------
function Resolve-VSCodeCommand {
    $onPath = Get-Command code.cmd -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd')
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Start-LauncherVSCode <folder> <box>
#   Launch VS Code on the folder (new window), find the window it created —
#   diffing HWNDs of class Chrome_WidgetWin_1 owned by Code.exe whose title
#   contains the folder's basename and was not open before — and position it.
#   Needs no Accessibility-style permission at all.
# ---------------------------------------------------------------------------
function Start-LauncherVSCode {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)]$Box
    )

    $folderName = Split-Path -Leaf $Folder
    $before = Get-TopLevelWindows -ClassName 'Chrome_WidgetWin_1' -ProcessName 'Code'

    $codeCmd = Resolve-VSCodeCommand
    if (-not $codeCmd) {
        Write-Warning 'code.cmd was not found on PATH or in the well-known install locations — VS Code was not launched.'
        return $null
    }

    Start-Process -FilePath $codeCmd -ArgumentList @('-n', $Folder) | Out-Null

    $found = Wait-ForNewWindow -ClassName 'Chrome_WidgetWin_1' -ProcessName 'Code' `
        -TitleContains $folderName -Before $before -TimeoutSeconds 8 -Count 1

    # Fallback: a window for this same folder was already open before we
    # launched (VS Code reused it instead of opening a second one), so no
    # "new" window ever appears. Match on title alone rather than leave VS
    # Code unpositioned.
    if ($found.Count -eq 0) {
        $codeWindows = Get-TopLevelWindows -ClassName 'Chrome_WidgetWin_1' -ProcessName 'Code'
        $found = @($codeWindows | Where-Object { $_.Title -like "*$folderName*" })
    }


    if ($found.Count -eq 0) {
        Write-Warning "could not find the new VS Code window to position (folder '$folderName')."
        return $null
    }

    $target = @($found)[0]
    Set-WindowRect -Hwnd $target.Hwnd -X $Box.X -Y $Box.Y -Width $Box.Width -Height $Box.Height
    return (Resolve-LauncherWindowOwnership -Hwnds @($target.Hwnd))[0]
}

# ---------------------------------------------------------------------------
# Start-LauncherTerminal
#   Launch the right-half console(s) and return their ownership triples.
#   -Layout: grid | stacked (from Select-LauncherLayout)
#   -GridMode: panes | windows (from Get-LauncherGridMode; ignored when stacked)
# ---------------------------------------------------------------------------
function Start-LauncherTerminal {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][ValidateSet('grid', 'stacked')][string]$Layout,
        [Parameter(Mandatory)][ValidateSet('panes', 'windows')][string]$GridMode,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PaneCommand,
        [Parameter(Mandatory)]$RightHalfBox,
        [Parameter(Mandatory)][object[]]$QuarterBoxes
    )

    $consoles = @()

    if ($Layout -eq 'stacked') {
        $box = $RightHalfBox
        $script1 = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
        $before = Get-TopLevelWindows -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS
        $wtArgs = @(
            '-w', "cl-$SessionId", '--pos', "$($box.X),$($box.Y)",
            'new-tab', '-d', $Folder, 'pwsh', '-NoExit', '-File', $script1
        )
        Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
        $found = Wait-ForNewWindow -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS -Before $before -Count 1
        foreach ($w in $found) { Set-WindowRect -Hwnd $w.Hwnd -X $box.X -Y $box.Y -Width $box.Width -Height $box.Height }
        $consoles += Resolve-LauncherWindowOwnership -Hwnds @($found | ForEach-Object { $_.Hwnd })
        return , $consoles
    }

    if ($GridMode -eq 'windows') {
        # Grid parity: four separate tiled windows, one per quarter.
        for ($i = 0; $i -lt $QuarterBoxes.Count; $i++) {
            $box = $QuarterBoxes[$i]
            $paneScript = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
            $before = Get-TopLevelWindows -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS
            $wtArgs = @(
                '-w', "cl-$SessionId-$i", '--pos', "$($box.X),$($box.Y)",
                'new-tab', '-d', $Folder, 'pwsh', '-NoExit', '-File', $paneScript
            )
            Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
            $found = Wait-ForNewWindow -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS -Before $before -Count 1
            foreach ($w in $found) { Set-WindowRect -Hwnd $w.Hwnd -X $box.X -Y $box.Y -Width $box.Width -Height $box.Height }
            $consoles += Resolve-LauncherWindowOwnership -Hwnds @($found | ForEach-Object { $_.Hwnd })
        }
        return , $consoles
    }

    # panes (default): one window, split 2x2, sized over the whole right half.
    # `--size` is skipped entirely (it takes columns/rows, not pixels); `--pos`
    # places the window and Set-WindowRect corrects it to exact pixels after.
    $box = $RightHalfBox
    $s1 = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
    $s2 = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
    $s3 = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
    $s4 = New-LauncherPaneScript -Folder $Folder -CommandText $PaneCommand
    $before = Get-TopLevelWindows -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS
    $wtArgs = @(
        '-w', "cl-$SessionId", '--pos', "$($box.X),$($box.Y)",
        'new-tab', '-d', $Folder, 'pwsh', '-NoExit', '-File', $s1, ';'
        'split-pane', '-V', '-d', $Folder, 'pwsh', '-NoExit', '-File', $s2, ';'
        'move-focus', 'left', ';'
        'split-pane', '-H', '-d', $Folder, 'pwsh', '-NoExit', '-File', $s3, ';'
        'move-focus', 'right', ';'
        'split-pane', '-H', '-d', $Folder, 'pwsh', '-NoExit', '-File', $s4
    )
    Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs | Out-Null
    $found = Wait-ForNewWindow -ClassName $script:CASCADIA_HOSTING_WINDOW_CLASS -Before $before -Count 1
    foreach ($w in $found) { Set-WindowRect -Hwnd $w.Hwnd -X $box.X -Y $box.Y -Width $box.Width -Height $box.Height }
    $consoles += Resolve-LauncherWindowOwnership -Hwnds @($found | ForEach-Object { $_.Hwnd })
    return , $consoles
}

# ---------------------------------------------------------------------------
# Session recording (Phase 4)
# ---------------------------------------------------------------------------
function Get-LauncherStateDir {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path $env:LOCALAPPDATA $Name
}

function Get-LauncherSessionsDir {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path (Get-LauncherStateDir -Name $Name) 'sessions'
}

function ConvertTo-LauncherConsoleRecord {
    param($Console)
    [PSCustomObject]@{
        hwnd       = [int64]$Console.Hwnd
        pid        = $Console.ProcessId
        start_time = if ($Console.StartTime) { $Console.StartTime.ToString('o') } else { $null }
    }
}

# ---------------------------------------------------------------------------
# Save-LauncherSession
#   Record a launch as JSON, tagged engine = "windows-terminal", and point
#   last.session at it. There is no symlink (Developer Mode/admin would be
#   required); last.session is a plain text file holding the session id.
# ---------------------------------------------------------------------------
function Save-LauncherSession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Layout,
        [Parameter(Mandatory)][string]$GridMode,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Consoles,
        [AllowNull()]$VSCodeConsole
    )

    $sessDir = Get-LauncherSessionsDir -Name $Name
    New-Item -ItemType Directory -Path $sessDir -Force | Out-Null

    $record = [PSCustomObject]@{
        session    = $SessionId
        engine     = 'windows-terminal'
        created_at = (Get-Date).ToString('o')
        folder     = $Folder
        layout     = $Layout
        grid_mode  = $GridMode
        vscode     = if ($VSCodeConsole) { ConvertTo-LauncherConsoleRecord $VSCodeConsole } else { $null }
        consoles   = @($Consoles | ForEach-Object { ConvertTo-LauncherConsoleRecord $_ })
    }

    $path = Join-Path $sessDir "$SessionId.session.json"
    $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
    Set-Content -LiteralPath (Join-Path (Get-LauncherStateDir -Name $Name) 'last.session') -Value $SessionId -Encoding utf8
    return $path
}

# ---------------------------------------------------------------------------
# Get-LauncherSessionRecords <name>
#   All recorded sessions as parsed objects (Path + the parsed JSON), newest
#   first.
# ---------------------------------------------------------------------------
function Get-LauncherSessionRecords {
    param([Parameter(Mandatory)][string]$Name)

    $sessDir = Get-LauncherSessionsDir -Name $Name
    if (-not (Test-Path -LiteralPath $sessDir)) { return @() }

    $files = Get-ChildItem -LiteralPath $sessDir -Filter '*.session.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    $records = @()
    foreach ($f in $files) {
        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $records += [PSCustomObject]@{ Path = $f.FullName; Data = $data }
        }
        catch {
            Write-Warning "skipping unreadable session record: $($f.FullName)"
        }
    }
    return , $records
}

function Get-LauncherLastSessionId {
    param([Parameter(Mandatory)][string]$Name)
    $p = Join-Path (Get-LauncherStateDir -Name $Name) 'last.session'
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw).Trim() }
    return $null
}

function Clear-LauncherLastSessionId {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$SessionId)
    $p = Join-Path (Get-LauncherStateDir -Name $Name) 'last.session'
    if ((Test-Path -LiteralPath $p) -and (Get-Content -LiteralPath $p -Raw).Trim() -eq $SessionId) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Invoke-LauncherMain
#   The whole flow: resolve folder, measure the monitor, launch VS Code and
#   the terminal console(s), tile both, and (optionally) record the launch.
#   Mirrors launcher_main in launcher-common.sh.
# ---------------------------------------------------------------------------
function Invoke-LauncherMain {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$EnvPrefix,
        [string]$Usage = "Usage: $Name [folder]",
        [bool]$Record = $false,
        [Parameter(Mandatory)][scriptblock]$BuildCommand,
        [string]$Folder,
        [string[]]$ToolArgs = @()
    )

    $target = if ($Folder) { $Folder } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Error "$Name`: '$target' is not a directory`n$Usage"
        exit 1
    }
    $folder = (Resolve-Path -LiteralPath $target).Path
    $folderName = Split-Path -Leaf $folder

    $gridMode = Get-LauncherGridMode -Prefix $EnvPrefix

    $built = & $BuildCommand $folder $ToolArgs

    $keepAwakePath = Join-Path $PSScriptRoot 'Keep-Awake.ps1'
    if ($built) {
        $parts = @([string]$built.Exe) + @($built.Args)
        $quoted = $parts | ForEach-Object { "'{0}'" -f (ConvertTo-LauncherLiteral ([string]$_)) }
        $paneCommand = "& '{0}' {1}" -f (ConvertTo-LauncherLiteral $keepAwakePath), ($quoted -join ' ')
    }
    else {
        $paneCommand = "Write-Host '$Name`: the CLI was not found on PATH.'"
    }

    $sid = "{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID

    $geometry = Get-LauncherGeometry
    $layout = Select-LauncherLayout -Geometry $geometry -Prefix $EnvPrefix

    $xHalf = $geometry.X + [int]($geometry.Width / 2)
    $xColMid = $geometry.X + [int](3 * $geometry.Width / 4)
    $xRight = $geometry.X + $geometry.Width
    $yTop = $geometry.Y
    $yMid = $geometry.Y + [int]($geometry.Height / 2)
    $yBottom = $geometry.Y + $geometry.Height

    $vsBox = [PSCustomObject]@{ X = $geometry.X; Y = $yTop; Width = [int]($geometry.Width / 2); Height = $geometry.Height }
    $rightHalfBox = [PSCustomObject]@{ X = $xHalf; Y = $yTop; Width = ($xRight - $xHalf); Height = ($yBottom - $yTop) }
    $quarterBoxes = @(
        [PSCustomObject]@{ X = $xHalf; Y = $yTop; Width = ($xColMid - $xHalf); Height = ($yMid - $yTop) }
        [PSCustomObject]@{ X = $xColMid; Y = $yTop; Width = ($xRight - $xColMid); Height = ($yMid - $yTop) }
        [PSCustomObject]@{ X = $xHalf; Y = $yMid; Width = ($xColMid - $xHalf); Height = ($yBottom - $yMid) }
        [PSCustomObject]@{ X = $xColMid; Y = $yMid; Width = ($xRight - $xColMid); Height = ($yBottom - $yMid) }
    )

    $vscodeConsole = Start-LauncherVSCode -Folder $folder -Box $vsBox

    $consoles = Start-LauncherTerminal -SessionId $sid -Layout $layout -GridMode $gridMode `
        -Folder $folder -PaneCommand $paneCommand -RightHalfBox $rightHalfBox -QuarterBoxes $quarterBoxes

    $consoleCount = @($consoles).Count
    $layoutDesc = if ($layout -eq 'grid') { "grid layout, $gridMode mode" } else { 'stacked layout' }

    if ($Record) {
        Save-LauncherSession -Name $Name -SessionId $sid -Folder $folder -Layout $layout `
            -GridMode $gridMode -Consoles $consoles -VSCodeConsole $vscodeConsole | Out-Null
        Write-Host "$Name`: launched in $folder (session $sid, $consoleCount console(s), $layoutDesc)"
        Write-Host "  close it later with:  $Name-close.ps1"
    }
    else {
        Write-Host "$Name`: launched in $folder ($consoleCount console(s), $layoutDesc)"
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-LauncherLiteral'
    'Get-LauncherGeometry'
    'Select-LauncherLayout'
    'Get-LauncherGridMode'
    'Get-LauncherWindows'
    'Get-TopLevelWindows'
    'Wait-ForNewWindow'
    'Get-LauncherWindowBorderMargins'
    'Set-WindowRect'
    'Resolve-LauncherWindowOwnership'
    'Test-LauncherWindowOwnership'
    'Close-LauncherWindow'
    'New-LauncherPaneScript'
    'Resolve-VSCodeCommand'
    'Start-LauncherVSCode'
    'Start-LauncherTerminal'
    'Get-LauncherStateDir'
    'Get-LauncherSessionsDir'
    'Save-LauncherSession'
    'Get-LauncherSessionRecords'
    'Get-LauncherLastSessionId'
    'Clear-LauncherLastSessionId'
    'Invoke-LauncherMain'
)
