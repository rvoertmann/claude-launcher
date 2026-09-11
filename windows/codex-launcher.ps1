#Requires -Version 7.0
#
# codex-launcher.ps1: tile VS Code + Windows Terminal console(s) on the
# current desktop, with each console running an OpenAI Codex CLI session in
# the target folder. The Codex counterpart to `claude-launcher.ps1`.
#
# All the tiling/VS Code work lives in LauncherCommon.psm1; this file only
# pins the Codex command each console runs. There is deliberately no
# companion `codex-launcher-close`: launches are not recorded, so close the
# windows yourself when you're done.
#
# Usage:
#   codex-launcher.ps1 [folder]
#     folder  defaults to the current directory
#
# Environment:
#   CODEX_LAUNCHER_LAYOUT     auto (default) | grid | stacked
#   CODEX_LAUNCHER_MIN_COL    minimum console width, in DIPs, that `auto`
#                             requires before it chooses the grid (default 640)
#   CODEX_LAUNCHER_GRID_MODE  panes (default) | windows
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Folder
)

if (-not $IsWindows) {
    Write-Error 'codex-launcher.ps1 requires Windows.'
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'LauncherCommon.psm1') -Force

# BuildCommand hook: `codex --dangerously-bypass-approvals-and-sandbox` (the
# Codex analog to Claude's --dangerously-skip-permissions). If `codex` isn't
# on PATH, return $null so the engine drops each console into a plain
# interactive shell with an install hint, rather than exiting.
$buildCommand = {
    param($ResolvedFolder, $Args)

    $codexCmd = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codexCmd) {
        Write-Host 'codex-launcher: the Codex CLI (codex) was not found on PATH, install it with: npm install -g @openai/codex'
        return $null
    }
    [PSCustomObject]@{ Exe = $codexCmd.Source; Args = @('--dangerously-bypass-approvals-and-sandbox') }
}

Invoke-LauncherMain -Name 'codex-launcher' -EnvPrefix 'CODEX_LAUNCHER' `
    -Usage 'Usage: codex-launcher.ps1 [folder]   (folder defaults to the current directory)' `
    -Record $false -BuildCommand $buildCommand -Folder $Folder
