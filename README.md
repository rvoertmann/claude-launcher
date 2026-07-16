# claude-launcher / copilot-launcher

Instantly set up a coding layout on macOS: **VS Code on the left half** and **Terminal.app windows
on the right**, each running an AI coding CLI in a target folder. Everything is scaffolded on the
**current Space** (virtual desktop), and `claude-launcher-close` tears the whole layout back down
again.

There are two launchers, sharing one engine:

- **`claude-launcher`** — each terminal runs a **Claude Code** session
  (`claude --dangerously-skip-permissions`). Records each launch so
  `claude-launcher-close` can tear it down later.
- **`copilot-launcher`** — each terminal runs a **GitHub Copilot CLI** session
  (`copilot --allow-all --autopilot`). No close command — close the windows yourself when done.

Both do the exact same tiling; they differ only in which CLI the terminals run. That single
difference is all that lives in each launcher — see [Architecture](#architecture) below.

On a wide display the right half is a 2×2 grid of four terminals:

```
┌───────────────────────┬───────────┬───────────┐
│                       │  claude   │  claude   │
│                       │  (term 1) │  (term 2) │
│        VS Code        ├───────────┼───────────┤
│                       │  claude   │  claude   │
│                       │  (term 3) │  (term 4) │
└───────────────────────┴───────────┴───────────┘
```

On a laptop screen it drops to two full-width terminals, stacked:

```
┌───────────────────────┬───────────────────────┐
│                       │        claude         │
│                       │       (term 1)        │
│        VS Code        ├───────────────────────┤
│                       │        claude         │
│                       │       (term 2)        │
└───────────────────────┴───────────────────────┘
```

### Choosing the layout

The launcher measures the screen and picks: the grid needs each terminal to be at least **640
points** wide, and a terminal in the grid is a quarter of the screen. So displays 2560pt and wider
(a 5K Studio Display, most 4K panels) get the grid, while a 16" MacBook Pro (1728pt → 432pt columns,
too narrow for Claude Code's output) and a 14" (1512pt) get the stacked pair.

Override it with environment variables:

| Variable | Values | Default | Meaning |
| --- | --- | --- | --- |
| `CLAUDE_LAUNCHER_LAYOUT` | `auto`, `grid`, `stacked` | `auto` | Force a layout instead of measuring |
| `CLAUDE_LAUNCHER_MIN_COL` | points | `640` | Minimum terminal width `auto` requires to pick the grid |

```sh
CLAUDE_LAUNCHER_LAYOUT=stacked claude-launcher ~/code/project   # two terminals, even on a big screen
CLAUDE_LAUNCHER_LAYOUT=grid    claude-launcher ~/code/project   # four terminals, even on a laptop
```

Each launcher reads its own env namespace, so `copilot-launcher` uses `COPILOT_LAUNCHER_LAYOUT` and
`COPILOT_LAUNCHER_MIN_COL` with the same meanings.

### No browser pane

Earlier versions tried to tile a browser window on the far left. It was removed because macOS makes
it impossible to place reliably: a **running** browser pins each new window to the Space it last
used — not the desktop you're viewing — and there is no scriptable way to place or move a window
onto the current Space. For the record, every route was tried on macOS 26 and failed:

- AppleScript `make new document` → opens on Safari's old Space, even with Safari frontmost on the
  current desktop and the auto-swoosh suppressed.
- A real **Cmd+N** synthesized while Safari is frontmost here → same.
- Minimizing every other Safari window first, then Cmd+N → same; a minimized window keeps its
  Space assignment, and so does the app. (Bonus trap: `activate` *un-minimizes* the last minimized
  window — Dock "reopen" behavior.)
- A dedicated second Safari instance (`open -na Safari`), which has no Space memory of its own →
  opened on the current Space in isolated tests, but still landed on the wrong desktop in the real
  launch flow.

(Window managers like yabai can move windows across Spaces only via private APIs and with SIP
disabled; VS Code and Terminal escape all this because they open new windows on the *active*
Space.) So rather than tile a browser onto the wrong desktop, the launcher leaves it out — open one
yourself in the space beside VS Code. A browser you keep *closed*, with no windows on any other
Space, will open on the current desktop if you want to add one by hand.

## Usage

```sh
claude-launcher  [folder] [plugin-dir]      # open the layout, terminals run Claude Code
claude-launcher-close                       # close the most recent Claude layout

copilot-launcher [folder]                   # open the layout, terminals run the Copilot CLI
```

- `folder` — the directory to open VS Code and the terminals in. Defaults to the current
  directory if omitted.
- `plugin-dir` *(claude-launcher only)* — optional Claude Code plugin directory. When given, each
  session is started with `claude --plugin-dir <plugin-dir>` so the plugin is loaded.

Each terminal runs, in that folder:

- `claude-launcher`  → `claude --dangerously-skip-permissions [--plugin-dir <plugin-dir>]`
- `copilot-launcher` → `copilot --allow-all --autopilot`

`--allow-all` is the Copilot analog of Claude Code's `--dangerously-skip-permissions`: it
auto-approves tools, paths, and URLs for the session. `--autopilot` starts the session in
autopilot mode. `copilot-launcher` needs the [GitHub Copilot
CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli) on your `PATH`
(`npm install -g @github/copilot`); if it isn't found, the terminal prints an install hint and
drops into a normal shell.

## Architecture

The tiling engine — screen measurement, VS Code launch/positioning, Terminal.app creation and
placement, and (optionally) session recording — lives once in **`launcher-common.sh`**. Each
launcher is a thin wrapper that sources it and supplies only the CLI-specific bits:

| File | Role |
| --- | --- |
| `launcher-common.sh` | Shared engine. Sourced, never run directly. |
| `claude-launcher` | Sets name/env-prefix + a `launcher_build_command` hook that runs Claude Code; records launches (`LAUNCHER_RECORD=1`). |
| `copilot-launcher` | Same, but its hook runs the Copilot CLI; no recording (`LAUNCHER_RECORD=0`), no close command. |
| `claude-launcher-close` | Tears down a recorded Claude launch (see below). |

To add another CLI, copy a wrapper, change `LAUNCHER_NAME`, `LAUNCHER_ENV_PREFIX`, and the one
`launcher_build_command` function — nothing else.

## Closing a layout

Each launch records the windows it created under `~/.local/state/claude-launcher/`, so the close
command tears down **exactly those windows and only those** — pre-existing Terminal and VS Code
windows are never touched.

```sh
claude-launcher-close                 # close the most recent launch
claude-launcher-close --all           # close every recorded launch
claude-launcher-close --list          # list recorded launches, close nothing
claude-launcher-close <session-id>    # close a specific launch
```

What it does per window:

- **Terminals** — force-quits each session (`kill -9` every process on its recorded tty, so there
  is no "terminate the running process?" prompt), then closes the window by its recorded id.
  Terminal takes a second or two to remove a "[Process completed]" window; that lag is cosmetic.
- **VS Code** — VS Code windows have no scriptable id, so ours is identified by its **full folder
  path**: the window whose open document lives inside the launched folder. Only if no file is open
  does it fall back to matching the folder's basename in the title. If a "save changes?" prompt
  appears it force-discards via **Don't Save** — so it can lose unsaved edits in the matched
  window. Because matching is Space-dependent, it may occasionally not find the window (then just
  close it yourself).

### On the "current desktop only" limitation

macOS does not expose a window's Space to unprivileged scripts, so the close command cannot *filter*
by the desktop you are currently viewing. Instead it targets the exact window ids/paths each launch
recorded — which were all created on one desktop — so it closes precisely that launch's windows. If
you drag some of them to another Space afterward, they will still be closed (they belong to the
launch).

## Install

Make the launchers executable and symlink them onto your `PATH`:

```sh
chmod +x claude-launcher copilot-launcher claude-launcher-close
ln -sf "$PWD/claude-launcher"       ~/.local/bin/claude-launcher
ln -sf "$PWD/copilot-launcher"      ~/.local/bin/copilot-launcher
ln -sf "$PWD/claude-launcher-close" ~/.local/bin/claude-launcher-close
```

(`~/.local/bin` is already on your `PATH`.) You do **not** symlink `launcher-common.sh` — each
launcher resolves its own symlink and sources the library from wherever the real script lives, so
keep `launcher-common.sh` sitting next to `claude-launcher` and `copilot-launcher` in this repo.

## One-time permission: Accessibility

Tiling the terminals uses Terminal's own scripting and needs no special permission.
Positioning/closing the **VS Code** window goes through macOS *System Events*, which requires the
app that runs the scripts (normally **Terminal**) to be granted Accessibility access:

**System Settings → Privacy & Security → Accessibility → enable Terminal.**

Until that's granted, everything else still tiles correctly, but VS Code may open without snapping
into place. Grant the permission once and re-run.

## Notes

- **Opening a VS Code window (`code -n`) unavoidably *activates* VS Code.** If its only other
  windows live on another Space, macOS may "auto-swoosh" you there (Mission Control's *"When
  switching to an application, switch to a Space with open windows for the application"*, on by
  default) — dragging the whole layout onto the wrong desktop and resizing a pre-existing window.
  The launcher no longer toggles that setting for you (it previously did, with a `killall Dock`
  flicker at the start and end of each launch). If this bothers you, either turn that Mission
  Control setting off yourself permanently, or make sure no other VS Code window is open on another
  Space before launching.
- Geometry is read from the display's Dock-aware **visible frame**, so windows tile flush to the
  menu bar and the Dock, and it adapts if your resolution changes.
- Terminal.app snaps window sizes to its character grid, so the tiles land within a few pixels of
  exact — close enough to read as clean halves or quarters.
- Requires macOS with Terminal.app and Visual Studio Code installed at `/Applications`.
```
