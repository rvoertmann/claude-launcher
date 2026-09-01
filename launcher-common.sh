# shellcheck shell=bash
#
# launcher-common.sh — shared engine behind `claude-launcher` and
# `copilot-launcher`. It tiles windows on the current Space (virtual desktop):
#
#   Left half   -> Visual Studio Code, opened on the target folder.
#   Right half  -> Terminal.app windows, each running an AI coding CLI in that
#                  folder (which CLI, and with which flags, is the ONLY part
#                  that differs between launchers — see the
#                  `launcher_build_command` hook below).
#
# Two layouts, chosen from the display's width:
#
#   grid     (wide display)   FOUR equal Terminal.app windows tiled 2x2 over the
#                             right half — each a quarter of the screen wide and
#                             half its height.
#   stacked  (narrow display) ONE Terminal.app window over the whole right half.
#
# Quartering the right half of a 16" MacBook Pro leaves each console ~430pt
# wide, which these CLIs' output does not fit into — hence `stacked` on a laptop
# panel. The four grid consoles are separate WINDOWS, not panes or tabs:
# Terminal.app cannot split a window, and its scripting dictionary has no `make
# new tab` either, so tiled windows are the only way to get four consoles.
#
# There is no tmux layer and no mirror/overview desktop any more: both were
# built on iTerm2, which was slow enough to be worth dropping outright.
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
#   LAUNCHER_ENV_PREFIX  env-var namespace, e.g. "CLAUDE_LAUNCHER"
#   LAUNCHER_USAGE       one-line usage string shown on argument errors
#
# and MUST define a shell function:
#
#   launcher_build_command <folder> [tool-args...]
#       Echo the shell command the session should run *after* it cd's into
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
#   ${PREFIX}_MIN_COL    minimum console width in points that `auto` requires
#                        before it chooses the grid (default 640)
#
# ${PREFIX}_OVERVIEW is gone along with the mirror desktop; it is ignored if
# still set.

# ---------------------------------------------------------------------------
# launcher_main <folder> [tool-args...]
#   Runs the whole flow: resolve folder, measure the screen, launch VS Code and
#   the Terminal.app session, tile both, and (optionally) record the launch.
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

  # The command the session runs after cd'ing into the folder. Everything
  # tool-specific lives behind this one hook.
  local cmd
  cmd="$(launcher_build_command "$folder" "$@")"

  # The launch id: `date` to the second plus the pid is unique per launch.
  local sid
  sid="$(date +%Y%m%d-%H%M%S)-$$"

  local STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$name"

  # -------------------------------------------------------------------------
  # 2. Read the Dock-aware *visible frame* and compute the two window boxes.
  #    NSScreen.visibleFrame excludes the menu bar and the Dock, so windows
  #    tile flush to those instead of hiding underneath them. JXA returns it as
  #    "VX VY VW VH" already converted to AppleScript's top-left coordinates —
  #    which is also exactly what Terminal.app's `bounds` wants (a QuickDraw
  #    rect, {left, top, right, bottom}, top-left origin).
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
  xHalf=$(( VX + VW / 2 ))          # boundary between VS Code (left) and consoles
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

  # Pick the layout. In the grid each console is a quarter of the screen wide;
  # if that falls below $minCol points, use one full-half-width console instead.
  # A 16" MacBook Pro (1728pt) yields 432pt columns and so stacks; a 5K display
  # (2560pt) yields 640pt columns and so grids.
  if [[ "$layout" == "auto" ]]; then
    if (( VW / 4 >= minCol )); then layout="grid"; else layout="stacked"; fi
  fi

  # Window boxes over the right half, in creation order: a flat run of
  # {left top right bottom} integers, four per window, passed straight to
  # osascript. One console per window in both layouts.
  local -a boxes
  if [[ "$layout" == "grid" ]]; then
    #   TL              TR      four equal windows
    #   BL              BR
    boxes=(
      "$xHalf"    "$yTop"  "$xColMid"  "$yMid"
      "$xColMid"  "$yTop"  "$xRight"   "$yMid"
      "$xHalf"    "$yMid"  "$xColMid"  "$yBottom"
      "$xColMid"  "$yMid"  "$xRight"   "$yBottom"
    )
  else
    #   one window over the whole right half
    boxes=(
      "$xHalf"  "$yTop"  "$xRight"  "$yBottom"
    )
  fi
  local sessionCount=$(( ${#boxes[@]} / 4 ))

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
  #    tile the window we just opened and never a pre-existing one.
  # -------------------------------------------------------------------------
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
  # 4. Open the Terminal.app window(s), size each into its box, and start the
  #    CLI in each.
  #
  #    THE QUOTING, in two levels that never nest:
  #      1. bash -> osascript: every piece is a separate `argv` element, quoted
  #         with plain "$var". No escaping, no interpolation — which is why this
  #         heredoc is quoted ('APPLESCRIPT') and contains no substitutions.
  #      2. AppleScript -> shell: `quoted form of` wraps the folder in POSIX
  #         single quotes. That is the only escaping done anywhere, and
  #         AppleScript does it rather than us.
  #
  #    WHY THE WINDOW IS CREATED EMPTY FIRST: a CLI sizes its UI from the
  #    terminal it starts in. `do script ""` opens the window with nothing but a
  #    prompt, the bounds are applied, and only then is the real command sent
  #    into that same tab — so the session is born at its final geometry instead
  #    of reflowing after the resize.
  #
  #    A TAB HAS NO ID in Terminal.app either, but it does expose `tty`, which
  #    is what the launch record uses to find this session again. The window's
  #    integer `id` is stable for the window's life. Both are recorded PER
  #    CONSOLE and in the same order, so a teardown can pair them back up.
  #
  #    No `activate`: `do script` opens the window on the *current* Space
  #    without pulling Terminal's other windows over.
  #
  #    Arguments: folder, command, window count, then that many boxes of 4
  #    integers.
  # -------------------------------------------------------------------------
  local termData
  termData="$(osascript - "$folder" "$cmd" "$sessionCount" "${boxes[@]}" <<'APPLESCRIPT'
on run argv
    set theFolder to item 1 of argv
    set theCmd to item 2 of argv
    set winCount to (item 3 of argv) as integer
    set boxBase to 4

    set innerCmd to "cd " & quoted form of theFolder & " && " & theCmd

    -- One "windowID|tty" record per console, comma separated. The shell splits
    -- on those two characters, neither of which can appear in a Terminal window
    -- id (an integer) or a tty path.
    set recs to {}

    tell application "Terminal"
        repeat with wi from 0 to (winCount - 1)
            set L to (item (boxBase + wi * 4) of argv) as integer
            set T to (item (boxBase + wi * 4 + 1) of argv) as integer
            set R to (item (boxBase + wi * 4 + 2) of argv) as integer
            set Bo to (item (boxBase + wi * 4 + 3) of argv) as integer

            set winID to ""
            set theTTY to ""

            -- Empty script: opens a new window holding just a shell prompt.
            set newTab to do script ""

            -- The tab knows nothing about its window, so find the window that
            -- contains it. `front window` is the fallback, and is what this
            -- would have been anyway on a machine where the search fails.
            set theWindow to missing value
            repeat with w in windows
                try
                    if (tabs of w) contains newTab then
                        set theWindow to w
                        exit repeat
                    end if
                end try
            end repeat
            if theWindow is missing value then
                try
                    set theWindow to front window
                end try
            end if

            if theWindow is not missing value then
                -- Wrapped: Terminal snaps to whole character cells and can
                -- refuse an exact rect. A mis-sized console is not worth losing
                -- the session over.
                try
                    set bounds of theWindow to {L, T, R, Bo}
                end try
                try
                    set winID to (id of theWindow) as text
                end try
            end if

            -- Now the real command, into the window we just sized.
            do script innerCmd in newTab

            try
                set theTTY to tty of newTab
            end try

            set end of recs to winID & "|" & theTTY
        end repeat
    end tell

    set AppleScript's text item delimiters to ","
    set out to recs as text
    set AppleScript's text item delimiters to ""
    return out
end run
APPLESCRIPT
)"

  # Split the records into two parallel, index-aligned lists.
  local term_ids="" term_ttys="" rec
  local -a _recs
  # Guarded: `for x in "${arr[@]}"` on an empty array is an unbound-variable
  # error under `set -u` in bash 3.2, which is still what /bin/bash is on macOS.
  if [[ -n "${termData:-}" ]]; then
    IFS=',' read -ra _recs <<< "$termData"
    for rec in "${_recs[@]}"; do
      [[ -z "$rec" ]] && continue
      # A console whose id or tty could not be read gets a "-" placeholder
      # rather than being dropped, so the two lists stay index-aligned and the
      # teardown simply finds nothing to close for that slot.
      local _id="${rec%%|*}" _tty="${rec#*|}"
      term_ids+="${_id:--} "
      term_ttys+="${_tty:--} "
    done
  fi

  # -------------------------------------------------------------------------
  # 5. Position the VS Code window into the left half.
  #    This drives another process via System Events, which needs Accessibility
  #    permission for the app running this script. The AppleScript's own `try`
  #    only guards the window lookup/move, so a missing permission never aborts
  #    the (already tiled) console; we still capture stderr here so we can tell
  #    the user *why* VS Code wasn't moved instead of leaving it looking
  #    silently broken.
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
  # lacks Accessibility permission, so the whole `tell process "Code"` block
  # above never ran — VS Code opened but was never moved/resized.
  if [[ "$vscodePositionErr" == *"not allowed assistive access"* ]]; then
    echo "$name: could not position the VS Code window — Accessibility permission is missing." >&2
    echo "  Grant it in System Settings > Privacy & Security > Accessibility (enable Terminal," >&2
    echo "  or whichever app runs this script), then re-run $name." >&2
  elif [[ -n "$vscodePositionErr" ]]; then
    echo "$name: could not position the VS Code window: $vscodePositionErr" >&2
  fi

  # -------------------------------------------------------------------------
  # 6. Optionally record what this launch created, so a companion `-close`
  #    command can later tear down exactly that window and only that one.
  #
  #    Format is one `key=value` per line, parsed WITHOUT sourcing (values such
  #    as the folder path contain spaces).
  #
  #      engine         "terminal-windows" — the marker `-close` keys on to tell
  #                     this record apart from the older iTerm2 and
  #                     pre-iTerm2 formats, which it cannot replay.
  #      terminal_ids   one Terminal.app window id per console, in creation
  #                     order (one window per console in both layouts).
  #      terminal_ttys  each console's tty, in the SAME order. The pairing is
  #                     the ownership proof at close time: a recorded window is
  #                     only closed if it still holds a tab on its paired tty.
  #                     A slot whose id or tty could not be read holds "-".
  # -------------------------------------------------------------------------
  if [[ "$record" == "1" ]]; then
    mkdir -p "$STATE_DIR/sessions"
    local sfile="$STATE_DIR/sessions/$sid.session"
    {
      echo "session=$sid"
      echo "engine=terminal-windows"
      echo "created_at=$(date +%s)"
      echo "folder=$folder"
      echo "layout=$layout"
      echo "vscode_title=$folderName"
      echo "terminal_ids=$(echo "$term_ids" | xargs)"
      echo "terminal_ttys=$(echo "$term_ttys" | xargs)"
      echo "session_count=$sessionCount"
    } > "$sfile"
    ln -sf "$sfile" "$STATE_DIR/last.session"

    echo "$name: launched in $folder (session $sid, $sessionCount consoles, $layout layout)"
    echo "  close it later with:  $name-close"
  else
    echo "$name: launched in $folder ($sessionCount consoles, $layout layout)"
  fi
}
