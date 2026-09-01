# Windows Port Plan — claude-launcher / copilot-launcher

Port the macOS bash + AppleScript launcher toolkit to Windows as PowerShell 7 scripts under
`windows/`, preserving the original architecture: one shared engine, thin per-CLI wrappers
supplying a single command-building hook, and a teardown that proves ownership before closing
anything.

**Status:** planned, not implemented.

---

## 1. Why a rewrite, not a port

Nothing in the existing repo runs on Windows. The blockers are structural, not cosmetic:

| macOS dependency | Where | Windows availability |
| --- | --- | --- |
| `osascript` (AppleScript/JXA) | entire window layer | none |
| `NSScreen.visibleFrame` via ObjC bridge | `launcher-common.sh` geometry read | none |
| `tell application "Terminal"` / `do script` | console creation + sizing | none |
| System Events / `AXDocument` | VS Code positioning + closing | none |
| `caffeinate -i` | wraps every CLI session | none |
| `pkill -t <tty>` / `SIGHUP` | teardown | no ttys, no SIGHUP |
| `/Applications/...`, `open -a` | VS Code launch | different paths |
| bash 3.2 idioms, heredocs, `< <(...)` | throughout | PowerShell can't run them |

Under Git Bash the scripts start, fail the first `osascript`, and exit cleanly at the
"could not read the screen's visible frame" guard — so they fail safe, but do nothing.

Only the *design* carries over: the wrapper/hook seam, the layout math, and the
record-then-verify teardown.

---

## 2. Confirmed decisions

| Question | Decision |
| --- | --- |
| Runtime | PowerShell 7 (`.ps1` / `.psm1`), pure. No bash, Git Bash, or WSL. |
| Grid layout | Configurable via `${PREFIX}_GRID_MODE`. Default `panes` (one `wt` window, 2x2 split); `windows` mode gives four tiled windows for mac parity. |
| Virtual desktops | Ignored. VS Code and Windows Terminal already open on the active desktop, so "current Space" behavior falls out free. No `VirtualDesktopAccessor.dll`. |
| Monitor selection | The monitor under the cursor (`Screen.FromPoint`). |
| `confirmCloseAllTabs` prompt | Documented only. No detection, no custom Windows Terminal profile. |
| Scope | claude launcher, copilot launcher, close command with recording + verified teardown, keep-awake. |
| Excluded | iTerm2 / tmux / mirror-overview legacy record formats; auto-discard of unsaved VS Code edits. |
| Location | `windows/` subfolder in this repo. |
| macOS scripts | Gain a `uname -s` guard so they fail clearly off-Darwin. |

---

## 3. Grounded Windows facts

Verified against Microsoft's Windows Terminal command-line documentation; several design
choices follow directly from these:

- `wt.exe --pos x,y` takes **pixels**, but `--size c,r` takes **columns,rows** (character
  cells). Exact pixel geometry therefore requires a `SetWindowPos` pass after launch;
  `--size` is skipped entirely.
- `wt -w <name>` names and targets a window. Reserved values: `new`/`-1`, `last`/`0`.
- `wt` splits its own command line on unescaped `;`. Any PowerShell command containing a
  semicolon corrupts the parse.
- 2x2 pane sequence: `new-tab` -> `split-pane -V` -> `move-focus left` -> `split-pane -H` ->
  `move-focus right` -> `split-pane -H`.
- `wt.exe` is an app-execution-alias **stub**: it hands off to `WindowsTerminal.exe` and
  exits immediately, so a `Start-Process -PassThru` PID is worthless.
- Copilot CLI installs via `npm install -g @github/copilot`; `--allow-all --autopilot`
  are unchanged on Windows.

---

## 4. Design mapping

| macOS | Windows |
| --- | --- |
| `NSScreen.visibleFrame` | `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` then `Screen.FromPoint(cursor).WorkingArea` |
| Terminal.app `do script` + `bounds` | `wt.exe --pos` + `SetWindowPos` |
| Pre-launch window-title snapshot | Pre-launch HWND snapshot + diff (same trick, generalized) |
| System Events / `AXDocument` | `EnumWindows` + `GetWindowThreadProcessId` + `SetWindowPos` — **no permission required** |
| Ownership pair `(window id, tty)` | Ownership triple `(HWND, PID, PID StartTime)` |
| `pkill -HUP -t <tty>` | `CloseMainWindow()` (WM_CLOSE); never force-kill |
| `caffeinate -i <cmd>` | `Keep-Awake.ps1`: `SetThreadExecutionState(ES_CONTINUOUS + ES_SYSTEM_REQUIRED)`, run, clear in `finally` |
| `launcher_build_command` hook | `-BuildCommand` scriptblock parameter |
| `$XDG_STATE_HOME/claude-launcher` | `$env:LOCALAPPDATA\claude-launcher` |
| `key=value` `.session` record | JSON `.session.json`, `engine = "windows-terminal"` |
| AppleScript `quoted form of` | Per-pane temp `.ps1` run via `pwsh -NoExit -File` |

### Two subtleties that must not be missed

**DPI.** `MIN_COL=640` is macOS *points*, which are DPI-independent. On Windows the
threshold must be compared against **effective width** (`physicalWidth / scaleFactor`), not
raw pixels. Otherwise a 2560px panel at 150% scaling wrongly selects the grid when its
effective width is only 1706pt — exactly the "too narrow to read" case the rule exists to
prevent.

**Ownership.** Windows recycles PIDs, but never PID *plus* process start time. The triple
`(HWND, PID, StartTime)` is therefore strictly stronger proof than the macOS
`(window id, tty)` pair, which guards two independently-recyclable values against agreeing.

---

## 5. Files

### New

| Path | Role |
| --- | --- |
| `windows/LauncherCommon.psm1` | Shared engine: Win32 interop, geometry, layout selection, terminal launch, VS Code launch/positioning, launch recording. |
| `windows/Keep-Awake.ps1` | `caffeinate -i` equivalent. |
| `windows/claude-launcher.ps1` | Hook: `claude --dangerously-skip-permissions [--plugin-dir <dir>]`. Records launches. |
| `windows/copilot-launcher.ps1` | Hook: `copilot --allow-all --autopilot`. No recording. |
| `windows/claude-launcher-close.ps1` | Verified teardown of a recorded launch. |
| `windows/Install.ps1` | Generates `.cmd` shims onto PATH. |

### Modified

| Path | Change |
| --- | --- |
| `launcher-common.sh` | Add `uname -s` Darwin guard at the top of `launcher_main`. |
| `claude-launcher-close` | Add its own guard (standalone script, does not source the library). |
| `README.md` | Add a Windows section; extend the env-var table with `*_GRID_MODE`. |

---

## 6. Implementation phases

### Phase 0 — Guard the macOS scripts

*No dependencies. Can run in parallel with Phase 1.*

1. Add `[[ "$(uname -s)" != "Darwin" ]]` -> stderr message + `exit 1` at the top of
   `launcher_main` in `launcher-common.sh`, before the geometry read. This covers both
   launchers, since both source the library.
2. Add the same guard near the top of `claude-launcher-close`, which is standalone.
3. Message: `requires macOS; see windows/ for the PowerShell port`.

### Phase 1 — Win32 interop foundation

*Blocks Phases 2-5.*

4. Create `windows/LauncherCommon.psm1` with an `Add-Type` P/Invoke block:
   `SetProcessDpiAwarenessContext`, `EnumWindows`, `GetClassName`,
   `GetWindowThreadProcessId`, `IsWindow`, `IsWindowVisible`, `SetWindowPos`, `ShowWindow`,
   `PostMessage`.
5. Call `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` at module load — before any
   geometry read, or every measurement returns DPI-virtualized and every window lands wrong.
6. `Get-LauncherGeometry` — read `Screen.FromPoint(cursor).WorkingArea` (taskbar-aware,
   the analog of `visibleFrame`). Return both physical pixels and effective/DIP width.
7. `Select-LauncherLayout` — apply the original `width / 4 >= MinCol` test against
   **effective** width. Honour `${PREFIX}_LAYOUT` (`auto`/`grid`/`stacked`) and
   `${PREFIX}_MIN_COL`.
8. `Get-TopLevelWindows -ClassName` and `Wait-ForNewWindow` — snapshot HWNDs before a
   launch, poll and diff after.
9. `Set-WindowRect` — `ShowWindow(SW_RESTORE)` first (a maximized window silently ignores
   `SetWindowPos`), then position.

### Phase 2 — Terminal launch and keep-awake

*Depends on Phase 1. Parallel with Phase 3.*

10. `windows/Keep-Awake.ps1` — set the execution state, run the CLI, clear the flag in a
    `finally` so the assertion releases the moment the command exits.
11. `New-PaneScript` — write each console's command to a temp `.ps1`, run it as
    `pwsh -NoExit -File <path>`. **Not optional:** this sidesteps both `wt`'s `;` parsing
    and PowerShell quoting in one move.
12. `Start-LauncherTerminal`, three modes:
    - **panes** (default grid): one `wt -w cl-<sid> --pos X,Y` invocation chaining the
      2x2 sequence from section 3.
    - **windows** (grid parity): four `wt -w cl-<sid>-N --pos` invocations, one per quarter.
    - **stacked**: one window over the whole right half.
13. Omit `--size`; place with `--pos`, then correct to exact pixels with `Set-WindowRect`.
14. Resolve the real window by diffing HWNDs of class `CASCADIA_HOSTING_WINDOW_CLASS`,
    because the `wt.exe` PID is a dead stub.

### Phase 3 — VS Code launch and positioning

*Depends on Phase 1. Parallel with Phase 2.*

15. `Start-LauncherVSCode` — resolve `code.cmd` via `Get-Command`, falling back to
    `$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd`, then
    `$env:ProgramFiles\Microsoft VS Code\bin\code.cmd`. Launch with `-n`.
16. Snapshot `Code.exe` HWNDs before launch, diff after, position the new window into the
    left half. Replaces the entire System Events path and needs **no Accessibility
    permission** — the macOS one-time setup step disappears.

### Phase 4 — Recording and verified teardown

*Depends on Phases 1-3.*

17. Record each launch as JSON at
    `$env:LOCALAPPDATA\claude-launcher\sessions\<sid>.session.json`, tagged
    `engine = "windows-terminal"`. Store per console: HWND, PID, PID StartTime. Maintain
    a `last.session` pointer.
18. `windows/claude-launcher-close.ps1` — same interface as the original: no args
    (most recent), `-All`, `-List`, `<session-id>`.
19. Teardown per console: verify `IsWindow(hwnd)` **and**
    `GetWindowThreadProcessId(hwnd) == pid` **and** the start time matches -> then
    `CloseMainWindow()`. On failed verification, print `no longer ours — left alone` and
    touch nothing. **Never force-kill** — that is the loaded gun the original deliberately
    refuses.
20. Close VS Code with `PostMessage(hwnd, WM_CLOSE)`. Do not auto-click **Don't Save**;
    expose it as an opt-in `-DiscardUnsaved` switch.
21. Drop the record after a successful close, and clear `last.session` if it pointed there.

### Phase 5 — Launcher wrappers

*Depends on Phase 2.*

22. `windows/claude-launcher.ps1` — name, env prefix, usage, `Record = $true`, and a
    `-BuildCommand` scriptblock producing
    `claude --dangerously-skip-permissions [--plugin-dir <dir>]` under the keep-awake
    wrapper. PATH fallback targets `$env:APPDATA\npm\claude.cmd` (npm global on Windows),
    not `~/.local/bin`.
23. `windows/copilot-launcher.ps1` — `Record = $false`, hook produces
    `copilot --allow-all --autopilot`; if `copilot` is missing, print the
    `npm install -g @github/copilot` hint and drop into `pwsh` rather than exiting.

### Phase 6 — Install and docs

*Last.*

24. `windows/Install.ps1` — generate `.cmd` shims into a PATH directory. Symlinks require
    Developer Mode or admin on Windows, so shims are the reliable route.
25. Extend `README.md`: Windows usage, the `*_GRID_MODE` env var, a note that **no
    Accessibility-style permission is required**, and a note that Windows Terminal prompts
    on teardown of a panes-mode window unless the user sets `"confirmCloseAllTabs": false`
    in settings.json.

---

## 7. Verification

1. `Invoke-ScriptAnalyzer -Path windows/ -Recurse` returns clean.
2. Running the bash launcher on Windows exits 1 with the macOS-only message, not an
   empty-geometry error.
3. `pwsh -NoProfile -c 'Import-Module ./windows/LauncherCommon.psm1; Get-LauncherGeometry'`
   matches Display Settings minus the taskbar at 100%, 150%, and 200% scaling.
4. Multi-monitor: move the cursor to a secondary display, launch, confirm the layout lands
   there and not on primary.
5. Force every path: `CLAUDE_LAUNCHER_LAYOUT=stacked`; `=grid` with `_GRID_MODE=panes`;
   `=grid` with `_GRID_MODE=windows`. Tiles land flush to the taskbar with no gap or overlap.
6. Launch into a folder path containing spaces and an ampersand — proves the temp-`.ps1`
   approach beats `wt`'s `;` parsing.
7. `claude-launcher-close.ps1 -List`, then a plain close: exactly the launch's windows die,
   pre-existing ones survive.
8. **Ownership regression:** record a launch, kill Windows Terminal, open an unrelated
   terminal, run close. Must report `no longer ours — left alone` and close nothing.
9. Launch twice into the same folder; the second launch positions its own VS Code window
   and never grabs the first.

---

## 8. Deliberate behavior differences from macOS

- **VS Code close does not auto-discard.** The macOS version force-clicks **Don't Save**
  and can lose unsaved edits. Windows shows the dialog; discarding is opt-in.
- **No Accessibility permission.** The whole one-time macOS permission setup vanishes.
- **Teardown never force-kills.** If WM_CLOSE is refused, the window is left standing.
- **Panes instead of windows by default.** macOS uses four windows solely because
  Terminal.app cannot split; that constraint does not exist on Windows Terminal.
