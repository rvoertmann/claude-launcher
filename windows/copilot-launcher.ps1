#Requires -Version 7.0
#
# copilot-launcher.ps1 — tile VS Code + Windows Terminal console(s) on the
# current desktop, with each console running a GitHub Copilot CLI session in
# the target folder. The Copilot counterpart to `claude-launcher.ps1`.
#
# All the tiling/VS Code work lives in LauncherCommon.psm1; this file only
# pins the Copilot command each console runs. There is deliberately no
# companion `copilot-launcher-close`: launches are not recorded, so close the
# windows yourself when you're done.
#
# Usage:
#   copilot-launcher.ps1 [folder]
#     folder  defaults to the current directory
#
# Environment:
#   COPILOT_LAUNCHER_LAYOUT     auto (default) | grid | stacked
#   COPILOT_LAUNCHER_MIN_COL    minimum console width, in DIPs, that `auto`
#                               requires before it chooses the grid (default 640)
#   COPILOT_LAUNCHER_GRID_MODE  panes (default) | windows
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Folder
)

if (-not $IsWindows) {
    Write-Error 'copilot-launcher.ps1 requires Windows.'
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'LauncherCommon.psm1') -Force

# BuildCommand hook: `copilot --allow-all --autopilot`. If `copilot` isn't on
# PATH, return $null so the engine drops each console into a plain
# interactive shell with an install hint, rather than exiting.
$buildCommand = {
    param($ResolvedFolder, $Args)

    $copilotCmd = Get-Command copilot -ErrorAction SilentlyContinue
    if (-not $copilotCmd) {
        Write-Host 'copilot-launcher: the Copilot CLI (copilot) was not found on PATH — install it with: npm install -g @github/copilot'
        return $null
    }
    [PSCustomObject]@{ Exe = $copilotCmd.Source; Args = @('--allow-all', '--autopilot') }
}

Invoke-LauncherMain -Name 'copilot-launcher' -EnvPrefix 'COPILOT_LAUNCHER' `
    -Usage 'Usage: copilot-launcher.ps1 [folder]   (folder defaults to the current directory)' `
    -Record $false -BuildCommand $buildCommand -Folder $Folder
