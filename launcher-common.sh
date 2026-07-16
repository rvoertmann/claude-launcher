# shellcheck shell=bash
#
# launcher-common.sh — shared engine behind `claude-launcher` and
# `copilot-launcher`. It tiles Visual Studio Code + Terminal.app windows on the
# current Space (virtual desktop):
#
#   Left half   -> VS Code, opened on the target folder.
#   Right half  -> Terminal.app windows, each running an AI coding CLI in that
#                  folder (which CLI, and with which flags, is the ONLY part that
#                  differs between launchers — see the `launcher_build_command`
#                  hook below).
#
# The right half holds a 2x2 grid of four terminals on a wide display, but only
# two full-width terminals stacked vertically on a narrower one (a laptop's
# built-in screen). Quartering the right half of a 16" MacBook Pro leaves each
# terminal ~430pt wide, which these CLIs' output does not fit into; halving it
# horizontally keeps each one readable.
#
# (No browser pane: macOS pins a running browser's new windows to the Space the
# browser last used, with no scriptable way to place or move them onto the
# current desktop. Every route failed in practice — scripted windows, a
# synthesized Cmd+N, minimizing the other windows first, even a dedicated
# second browser instance — so the browser is left out rather than tiled onto
# the wrong desktop. Open one yourself in the space beside VS Code if needed.)
#
# ---------------------------------------------------------------------------
# Contract for a launcher that sources this file
# ---------------------------------------------------------------------------
# Before calling `launcher_main "$@"`, the sourcing script MUST set:
#
#   LAUNCHER_NAME        display name, e.g. "claude-launcher" (used in messages
#                        and, when recording, as the state-dir name)
#   LAUNCHER_ENV_PREFIX  env-var namespace, e.g. "CLAUDE_LAUNCHER" — the engine
#                        reads ${PREFIX}_LAYOUT and ${PREFIX}_MIN_COL from it
#   LAUNCHER_USAGE       one-line usage string shown on argument errors
#
# and MUST define a shell function:
#
#   launcher_build_command <folder> [tool-args...]
#       Echo the shell command each terminal should run *after* it cd's into
#       <folder> (the engine prepends the `cd`). This is where a launcher pins
#       its CLI binary, flags, PATH fallback and `caffeinate` wrapping. Any
#       arguments the user passed after the folder arrive as [tool-args...].
#
# It MAY set:
#
#   LAUNCHER_RECORD      "1" to record each launch's windows under the state dir
#                        (so a companion `-close` command can tear exactly those
#                        down later); anything else to skip recording. Default 0.
#
# Environment overrides the engine honors (namespaced by LAUNCHER_ENV_PREFIX):
#   ${PREFIX}_LAYOUT     auto (default) | grid | stacked
#   ${PREFIX}_MIN_COL    minimum terminal width in points that `auto` requires
#                        before it chooses the grid (default 640)

# ---------------------------------------------------------------------------
# launcher_main <folder> [tool-args...]
#   Runs the whole flow: resolve folder, measure the screen, launch VS Code and
#   the terminals, tile everything, and (optionally) record the session.
# ---------------------------------------------------------------------------
launcher_main() {
  set -euo pipefail

  local prefix="${LAUNCHER_ENV_PREFIX:?LAUNCHER_ENV_PREFIX must be set}"
  local name="${LAUNCHER_NAME:?LAUNCHER_NAME must be set}"
  local usage="${LAUNCHER_USAGE:-Usage: $name [folder]}"
  local record="${LAUNCHER_RECORD:-0}"

  # Layout controls, read from the launcher's own env namespace.
  local layout minCol
  eval "layout=\"\${${prefix}_LAYOUT:-auto}\""
  eval "minCol=\"\${${prefix}_MIN_COL:-640}\""
  case "$layout" in
    auto|grid|stacked) ;;
    *)
      echo "$name: ${prefix}_LAYOUT must be auto, grid, or stacked (got '$layout')" >&2
      exit 1
      ;;
  esac

  # -------------------------------------------------------------------------
  # 1. Resolve the target folder (arg 1, or $PWD) to an absolute path. The
  #    remaining args are the launcher's tool-specific args, forwarded to the
  #    `launcher_build_command` hook.
  # -------------------------------------------------------------------------
  local target="${1:-$PWD}"
  if [[ $# -gt 0 ]]; then shift; fi
  if [[ ! -d "$target" ]]; then
    echo "$name: '$target' is not a directory" >&2
    echo "$usage" >&2
    exit 1
  fi
  local folder folderName
  folder="$(cd "$target" && pwd)"
  folderName="$(basename "$folder")"

  # The command each terminal runs after cd'ing into the folder. Everything
  # tool-specific lives behind this one hook.
  local cmd
  cmd="$(launcher_build_command "$folder" "$@")"

  # -------------------------------------------------------------------------
  # 2. Read the Dock-aware *visible frame* and compute the window boxes.
  #    NSScreen.visibleFrame excludes the menu bar and the Dock, so windows
  #    tile flush to those instead of hiding underneath them. JXA returns it as
  #    "VX VY VW VH" already converted to AppleScript's top-left coordinates.
  # -------------------------------------------------------------------------
  local VX VY VW VH
  read -r VX VY VW VH < <(
    osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen; var f=s.frame; var v=s.visibleFrame; var top=f.size.height-(v.origin.y+v.size.height); [Math.round(v.origin.x),Math.round(top),Math.round(v.size.width),Math.round(v.size.height)].join(" ")'
  )
  if [[ -z "${VW:-}" || -z "${VH:-}" ]]; then
    echo "$name: could not read the screen's visible frame" >&2
    exit 1
  fi

  local xHalf xColMid xRight yTop yMid yBottom
  xHalf=$(( VX + VW / 2 ))          # boundary between VS Code (left) and terminals (right)
  xColMid=$(( VX + 3 * VW / 4 ))    # vertical split of the right half
  xRight=$(( VX + VW ))
  yTop=$VY
  yMid=$(( VY + VH / 2 ))           # horizontal split of the right half
  yBottom=$(( VY + VH ))

  # VS Code occupies the entire left half.
  local vsX vsY vsW vsH
  vsX=$VX
  vsY=$yTop
  vsW=$(( VW / 2 ))
  vsH=$VH

  # Pick the terminal layout. In the grid each terminal is a quarter of the
  # screen wide; if that falls below $minCol points, stack two full-half-width
  # terminals instead. A 16" MacBook Pro (1728pt) yields 432pt columns and so
  # stacks; a 5K display (2560pt) yields 640pt columns and so grids.
  if [[ "$layout" == "auto" ]]; then
    if (( VW / 4 >= minCol )); then layout="grid"; else layout="stacked"; fi
  fi

  # Terminal boxes over the right half, in creation order: a flat run of
  # {left top right bottom} integers, four per window, passed straight to osascript.
  local boxes
  if [[ "$layout" == "grid" ]]; then
    #   TL              TR
    #   BL              BR
    boxes=(
      "$xHalf"    "$yTop"  "$xColMid"  "$yMid"
      "$xColMid"  "$yTop"  "$xRight"   "$yMid"
      "$xHalf"    "$yMid"  "$xColMid"  "$yBottom"
      "$xColMid"  "$yMid"  "$xRight"   "$yBottom"
    )
  else
    #   TOP
    #   BOTTOM
    boxes=(
      "$xHalf"  "$yTop"  "$xRight"  "$yMid"
      "$xHalf"  "$yMid"  "$xRight"  "$yBottom"
    )
  fi
  local termCount=$(( ${#boxes[@]} / 4 ))

  # -------------------------------------------------------------------------
  # 3. Launch VS Code (new window) on the folder.
  #
  #    VS Code unavoidably *activates* itself when it opens a window — there is
  #    no background/no-activate path that also forces a new window. If VS Code's
  #    only existing windows live on another Space and macOS's "auto-swoosh"
  #    Mission Control setting is on, this can pull you to that other desktop.
  #    See the README for details; this engine no longer touches that setting.
  #
  #    First snapshot the titles of any existing VS Code windows, so step 5 can
  #    tile the window we just opened and never a pre-existing one (the same
  #    "diff to touch only what we created" guarantee the Terminal step gets from
  #    window ids).
  local vscodeBefore
  vscodeBefore="$(osascript -e 'tell application "System Events"
  if exists process "Code" then
    set AppleScript'"'"'s text item delimiters to linefeed
    return (name of every window of process "Code") as text
  end if
  return ""
end tell' 2>/dev/null || true)"

  local VSCODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  if [[ -x "$VSCODE_BIN" ]]; then
    "$VSCODE_BIN" -n "$folder" >/dev/null 2>&1 || open -a "Visual Studio Code" "$folder"
  else
    open -a "Visual Studio Code" "$folder"
  fi

  # -------------------------------------------------------------------------
  # 4. Open the Terminal windows and tile them into the right half.
  #    Uses Terminal's own scripting (no Accessibility permission needed).
  #    Arguments to the AppleScript: folder, the pre-built command, then N boxes
  #    of 4 numbers.
  # -------------------------------------------------------------------------
  local termData
  termData="$(osascript - "$folder" "$cmd" "${boxes[@]}" <<'APPLESCRIPT'
on run argv
    set theFolder to item 1 of argv
    set theCmd to item 2 of argv

    -- Everything after the folder and command args is a flat run of boxes,
    -- four integers each, so the window count follows from argv's length.
    set boxCount to ((count of argv) - 2) div 4

    -- Each terminal cd's into the folder, then runs the launcher's command.
    set cmd to "cd " & quoted form of theFolder & " && " & theCmd

    -- Boxes start at argv item 3, four numbers each.
    -- No `activate`: `do script` opens each new window on the *current* Space,
    -- while activating could jump to a Space where Terminal already has windows.
    -- Diff window IDs around each `do script` so we tile the window we just
    -- created, never a pre-existing Terminal window. Collect "id|tty" for each
    -- created window so the launcher can record them for a later clean close.
    set winRecs to {}
    tell application "Terminal"
        repeat with b from 0 to (boxCount - 1)
            set base to 3 + (b * 4)
            set L to (item base of argv) as integer
            set T to (item (base + 1) of argv) as integer
            set R to (item (base + 2) of argv) as integer
            set Bo to (item (base + 3) of argv) as integer
            set oldIDs to id of every window
            do script cmd
            delay 0.2
            set newWin to missing value
            repeat with w in windows
                if (id of w) is not in oldIDs then
                    set newWin to w
                    exit repeat
                end if
            end repeat
            if newWin is missing value then set newWin to front window
            set bounds of newWin to {L, T, R, Bo}
            set winTTY to ""
            try
                set winTTY to tty of selected tab of newWin
            end try
            set end of winRecs to ((id of newWin) as text) & "|" & winTTY
        end repeat
    end tell
    set AppleScript's text item delimiters to ","
    return winRecs as text
end run
APPLESCRIPT
)"

  # -------------------------------------------------------------------------
  # 5. Position the VS Code window into the left half.
  #    This drives another process via System Events, which needs Accessibility
  #    permission for the app running this script (usually Terminal). The
  #    AppleScript's own `try` only guards the window lookup/move so a missing
  #    permission never aborts the (already tiled) terminals; we still capture
  #    stderr here so we can tell the user *why* VS Code wasn't moved instead
  #    of leaving it looking silently broken.
  # -------------------------------------------------------------------------
  local vscodePositionErr
  vscodePositionErr="$(osascript - "$vsX" "$vsY" "$vsW" "$vsH" "$folderName" "${vscodeBefore:-}" <<'APPLESCRIPT' 2>&1 || true
on run argv
    set px to (item 1 of argv) as integer
    set py to (item 2 of argv) as integer
    set pw to (item 3 of argv) as integer
    set ph to (item 4 of argv) as integer
    set folderName to (item 5 of argv)

    -- Titles of the VS Code windows that existed *before* step 3 opened ours,
    -- one per line. Anything matching the folder that is NOT in this list is
    -- the window we just created; anything in it is pre-existing and untouched.
    set AppleScript's text item delimiters to linefeed
    set beforeList to text items of (item 6 of argv)
    set AppleScript's text item delimiters to ""

    try
        tell application "System Events" to tell process "Code"
            -- Wait up to ~6s for the window we opened to appear. Prefer a window
            -- whose title contains the folder name AND was not open before, so
            -- we never grab (and resize) a pre-existing same-folder window.
            set target to missing value
            set waited to 0
            repeat
                repeat with w in windows
                    set nm to name of w
                    if (nm contains folderName) and (beforeList does not contain nm) then
                        set target to w
                        exit repeat
                    end if
                end repeat
                if target is not missing value then exit repeat
                delay 0.2
                set waited to waited + 0.2
                if waited > 6 then exit repeat
            end repeat
            -- Fallbacks: any window matching the folder, then the front window.
            if target is missing value then
                repeat with w in windows
                    if (name of w) contains folderName then
                        set target to w
                        exit repeat
                    end if
                end repeat
            end if
            if target is missing value then
                if (exists window 1) then set target to window 1
            end if
            if target is not missing value then
                set position of target to {px, py}
                set size of target to {pw, ph}
            end if
        end tell
    end try
end run
APPLESCRIPT
)"

  # A bare "not allowed assistive access" means the app running this script
  # (usually Terminal.app) lacks Accessibility permission, so the whole `tell
  # process "Code"` block above never ran — VS Code opened but was never
  # moved/resized. Surface that clearly instead of leaving it looking broken
  # with no explanation.
  if [[ "$vscodePositionErr" == *"not allowed assistive access"* ]]; then
    echo "$name: could not position the VS Code window — Accessibility permission is missing." >&2
    echo "  Grant it in System Settings > Privacy & Security > Accessibility (enable Terminal," >&2
    echo "  or whichever app runs this script), then re-run $name." >&2
  elif [[ -n "$vscodePositionErr" ]]; then
    echo "$name: could not position the VS Code window: $vscodePositionErr" >&2
  fi

  # -------------------------------------------------------------------------
  # 6. Optionally record the windows this launch created, so a companion
  #    `-close` command can later close exactly those (and only those). Parse
  #    "id|tty,id|tty,..." from the Terminal step into parallel id / tty lists.
  # -------------------------------------------------------------------------
  if [[ "$record" == "1" ]]; then
    local STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$name"
    local term_ids="" term_ttys="" rec tty
    local _recs
    IFS=',' read -ra _recs <<< "${termData:-}"
    for rec in "${_recs[@]}"; do
      [[ -z "$rec" ]] && continue
      term_ids+="${rec%%|*} "
      tty="${rec#*|}"
      [[ -n "$tty" ]] && term_ttys+="$tty "
    done

    mkdir -p "$STATE_DIR/sessions"
    local sid sfile
    sid="$(date +%Y%m%d-%H%M%S)-$$"
    sfile="$STATE_DIR/sessions/$sid.session"
    {
      echo "session=$sid"
      echo "created_at=$(date +%s)"
      echo "folder=$folder"
      echo "layout=$layout"
      echo "vscode_title=$folderName"
      echo "terminal_ids=$(echo "$term_ids" | xargs)"
      echo "terminal_ttys=$(echo "$term_ttys" | xargs)"
    } > "$sfile"
    ln -sf "$sfile" "$STATE_DIR/last.session"

    echo "$name: launched in $folder (session $sid, $termCount terminals, $layout layout)"
    echo "  close it later with:  $name-close"
  else
    echo "$name: launched in $folder ($termCount terminals, $layout layout)"
  fi
}
