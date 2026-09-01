#Requires -Version 7.0
#
# Install.ps1 — generate .cmd shims onto PATH for the Windows launchers.
#
# Symlinks require Developer Mode or admin on Windows, so shims are the
# reliable route: each shim is a one-line .cmd that forwards to
# `pwsh -File <repo>\windows\<script>.ps1 %*`, resolved from wherever this
# repo actually lives (no hard-coded install path).
#
# Usage: windows/Install.ps1 [-BinDir <dir>]
#   -BinDir defaults to $env:LOCALAPPDATA\claude-launcher\bin, which this
#   script adds to the current user's PATH if it isn't already there.
[CmdletBinding()]
param(
    [string]$BinDir = (Join-Path $env:LOCALAPPDATA 'claude-launcher\bin')
)

if (-not $IsWindows) {
    Write-Error 'Install.ps1 requires Windows.'
    exit 1
}

$repoWindowsDir = $PSScriptRoot

$shims = @{
    'claude-launcher.cmd'       = 'claude-launcher.ps1'
    'copilot-launcher.cmd'      = 'copilot-launcher.ps1'
    'claude-launcher-close.cmd' = 'claude-launcher-close.ps1'
}

New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

foreach ($shimName in $shims.Keys) {
    $targetScript = Join-Path $repoWindowsDir $shims[$shimName]
    $shimPath = Join-Path $BinDir $shimName
    $content = "@echo off`r`npwsh -NoProfile -File `"$targetScript`" %*`r`n"
    Set-Content -LiteralPath $shimPath -Value $content -Encoding ascii -NoNewline
    Write-Host "wrote $shimPath"
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = @()
if ($userPath) { $pathEntries = $userPath.Split(';') }
if ($pathEntries -notcontains $BinDir) {
    $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Host "added $BinDir to your user PATH — open a new terminal for it to take effect"
}
else {
    Write-Host "$BinDir is already on your user PATH"
}

Write-Host ''
Write-Host 'Install complete. From a new terminal:'
Write-Host '  claude-launcher [folder] [plugin-dir]'
Write-Host '  copilot-launcher [folder]'
Write-Host '  claude-launcher-close'
