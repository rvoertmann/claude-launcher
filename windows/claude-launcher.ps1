#Requires -Version 7.0
#
# claude-launcher.ps1 — tile VS Code + Windows Terminal console(s) on the
# current desktop, with each console running a Claude Code session in the
# target folder. Windows port of `claude-launcher`.
#
# All the tiling/VS Code/recording work lives in LauncherCommon.psm1; this
# file only pins the Claude Code command each console runs. See that module
# and the README for the full picture.
#
# Usage:
#   claude-launcher.ps1 [folder] [plugin-dir]
#     folder      defaults to the current directory
#     plugin-dir  optional; passed to each session as `claude --plugin-dir <dir>`
#
# Environment:
#   CLAUDE_LAUNCHER_LAYOUT     auto (default) | grid | stacked
#   CLAUDE_LAUNCHER_MIN_COL    minimum console width, in DIPs, that `auto`
#                              requires before it chooses the grid (default 640)
#   CLAUDE_LAUNCHER_GRID_MODE  panes (default) | windows
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Folder,
    [Parameter(Position = 1)][string]$PluginDir
)

if (-not $IsWindows) {
    Write-Error 'claude-launcher.ps1 requires Windows.'
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'LauncherCommon.psm1') -Force

$usage = 'Usage: claude-launcher.ps1 [folder] [plugin-dir]   (folder defaults to the current directory)'

# BuildCommand hook: prefer `claude` on PATH, fall back to the npm global
# install location. An optional plugin dir is passed via --plugin-dir.
$buildCommand = {
    param($ResolvedFolder, $Args)

    $pluginDir = $Args[0]
    if ($pluginDir) {
        if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) {
            Write-Error "claude-launcher: plugin directory '$pluginDir' is not a directory`n$usage"
            exit 1
        }
        $pluginDir = (Resolve-Path -LiteralPath $pluginDir).Path
    }

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    $exe = if ($claudeCmd) { $claudeCmd.Source } else { Join-Path $env:APPDATA 'npm\claude.cmd' }

    $cliArgs = @('--dangerously-skip-permissions')
    if ($pluginDir) { $cliArgs += @('--plugin-dir', $pluginDir) }

    [PSCustomObject]@{ Exe = $exe; Args = $cliArgs }
}.GetNewClosure()

Invoke-LauncherMain -Name 'claude-launcher' -EnvPrefix 'CLAUDE_LAUNCHER' -Usage $usage `
    -Record $true -BuildCommand $buildCommand -Folder $Folder -ToolArgs @($PluginDir)
