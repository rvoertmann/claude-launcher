#Requires -Version 7.0
#
# Keep-Awake.ps1 — Windows analog of `caffeinate -i <cmd>`. Sets
# ES_SYSTEM_REQUIRED for as long as the wrapped command runs, then clears it in
# a `finally` so the assertion is released the moment the command exits (even
# on error or Ctrl+C).
#
# Usage: Keep-Awake.ps1 <exe> [args...]
#   The command is run directly via the call operator — never re-parsed as a
#   shell string — so no argument can inject further PowerShell.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Exe,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExeArgs = @()
)

if (-not $IsWindows) {
    throw 'Keep-Awake.ps1 requires Windows.'
}

Import-Module (Join-Path $PSScriptRoot 'LauncherCommon.psm1') -Force

$ES_CONTINUOUS = 2147483648   # 0x80000000 — written in decimal: PowerShell parses that hex literal as a negative Int32, which [uint32] then rejects
$ES_SYSTEM_REQUIRED = 0x00000001

try {
    [void][LauncherWin32]::SetThreadExecutionState([uint32]($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED))
    & $Exe @ExeArgs
}
finally {
    [void][LauncherWin32]::SetThreadExecutionState([uint32]$ES_CONTINUOUS)
}
