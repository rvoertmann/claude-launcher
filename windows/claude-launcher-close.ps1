#Requires -Version 7.0
#
# claude-launcher-close.ps1 — close the windows a `claude-launcher.ps1` run
# created, and only those. Reads the per-launch JSON record written under
# $env:LOCALAPPDATA\claude-launcher\sessions and tears down exactly the
# Windows Terminal console(s) and the VS Code window from that launch.
#
# ---------------------------------------------------------------------------
# Ownership proof
# ---------------------------------------------------------------------------
# Each recorded console/VS Code window carries the triple (HWND, PID, PID
# StartTime). A window is only closed once ALL THREE still agree — Windows
# recycles HWNDs and PIDs individually, but never PID+StartTime together, so
# this is strictly stronger proof than the macOS engine's (window id, tty)
# pair. A window that fails the check is left alone and reported as
# "no longer ours — left alone".
#
# ---------------------------------------------------------------------------
# Teardown mechanism
# ---------------------------------------------------------------------------
# Every close is PostMessage(hwnd, WM_CLOSE) — never a force-kill. If the
# window (or the process behind it) refuses/ignores the message, it is left
# standing rather than killed out from under the user.
#
# Usage:
#   claude-launcher-close.ps1                 # close the most recent session
#   claude-launcher-close.ps1 -All            # close every recorded session
#   claude-launcher-close.ps1 -List           # list recorded sessions, close nothing
#   claude-launcher-close.ps1 <session-id>    # close a specific session
[CmdletBinding(DefaultParameterSetName = 'Last')]
param(
    [Parameter(ParameterSetName = 'All')][switch]$All,
    [Parameter(ParameterSetName = 'List')][switch]$List,
    [Parameter(ParameterSetName = 'One', Position = 0)][string]$SessionId
)

if (-not $IsWindows) {
    Write-Error 'claude-launcher-close.ps1 requires Windows.'
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'LauncherCommon.psm1') -Force

$LauncherName = 'claude-launcher'

function Close-LauncherConsoleRecord {
    param($ConsoleRecord, [string]$Label)

    if (-not $ConsoleRecord) { return }
    if (-not $ConsoleRecord.pid -or $ConsoleRecord.pid -eq 0) { return }

    $hwnd = [IntPtr]$ConsoleRecord.hwnd
    $procId = [int]$ConsoleRecord.pid
    $startTime = $null
    if ($ConsoleRecord.start_time) {
        try { $startTime = [datetime]::Parse($ConsoleRecord.start_time, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    }

    if (-not (Test-LauncherWindowOwnership -Hwnd $hwnd -ProcessId $procId -StartTime $startTime)) {
        Write-Host "  $Label is gone (or no longer ours) — left alone"
        return
    }

    Close-LauncherWindow -Hwnd $hwnd
    Write-Host "  closed $Label"
}

function Close-LauncherSessionRecord {
    param($Record)

    $data = $Record.Data
    if ($data.engine -ne 'windows-terminal') {
        Write-Host "claude-launcher-close: session $($data.session) ($($data.folder)) has an unrecognized engine ('$($data.engine)') — skipping, leaving the record."
        return
    }

    Write-Host "closing session $($data.session) ($($data.folder))"

    $consoles = @($data.consoles)
    for ($i = 0; $i -lt $consoles.Count; $i++) {
        Close-LauncherConsoleRecord -ConsoleRecord $consoles[$i] -Label "terminal console $($i + 1)"
    }
    Close-LauncherConsoleRecord -ConsoleRecord $data.vscode -Label 'VS Code window'

    Remove-Item -LiteralPath $Record.Path -Force -ErrorAction SilentlyContinue
    Clear-LauncherLastSessionId -Name $LauncherName -SessionId $data.session
}

$records = Get-LauncherSessionRecords -Name $LauncherName

if ($records.Count -eq 0) {
    Write-Host "claude-launcher-close: no recorded sessions"
    exit 0
}

if ($List) {
    foreach ($r in $records) {
        Write-Host "$($r.Data.session)`t$($r.Data.folder)"
    }
    exit 0
}

$toClose = @()
switch ($PSCmdlet.ParameterSetName) {
    'All' { $toClose = @($records) }
    'One' {
        $match = $records | Where-Object { $_.Data.session -eq $SessionId }
        if (-not $match) {
            Write-Error "claude-launcher-close: no such session '$SessionId'"
            exit 1
        }
        $toClose = @($match)
    }
    default {
        # Last: prefer last.session, fall back to the newest record on disk.
        $lastId = Get-LauncherLastSessionId -Name $LauncherName
        $match = $null
        if ($lastId) { $match = $records | Where-Object { $_.Data.session -eq $lastId } | Select-Object -First 1 }
        if (-not $match) { $match = $records | Select-Object -First 1 }
        if ($match) { $toClose = @($match) }
    }
}

if ($toClose.Count -eq 0) {
    Write-Host "claude-launcher-close: no session to close"
    exit 0
}

foreach ($r in $toClose) {
    Close-LauncherSessionRecord -Record $r
}
