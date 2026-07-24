# shellcheck shell=bash
#
# launcher-common.sh — shared engine behind `claude-launcher` and
# `copilot-launcher`. It tiles Visual Studio Code + iTerm2 windows on the
# current Space (virtual desktop):
#
#   Left half   -> VS Code, opened on the target folder.
#   Right half  -> iTerm2 sessions, each running an AI coding CLI in that folder
#                  (which CLI, and with which flags, is the ONLY part that
#                  differs between launchers — see the `launcher_build_command`
#                  hook below).
#
# Two layouts, chosen from the display's width:
#
#   grid     (wide display)   four iTerm2 WINDOWS tiled 2x2 over the right half,
#                             one session each.
#   stacked  (narrow display) one iTerm2 window over the whole right half with
#                             TWO TABS, one session each.
#
# Both layouts also get the mirror desktop described below (unless it is turned
# off with ${PREFIX}_OVERVIEW=0).
#
# Quartering the right half of a 16" MacBook Pro leaves each pane ~430pt wide,
# which these CLIs' output does not fit into — hence `stacked`, where each tab
# gets the full half-width and full height and the two sessions live behind one
# another rather than beside one another.
#
# (This engine drove Terminal.app until the iTerm2 migration. Terminal.app could
# not create a tab from its own scripting dictionary at all — `tab` is a
# read-only element with no `make new tab` — so `stacked` was limited to a single
# session. iTerm2 has a real `create tab` command, which is what makes two
# stacked sessions possible.)
#
# ---------------------------------------------------------------------------
# Every session runs under tmux, invisibly
# ---------------------------------------------------------------------------
# No session runs its CLI directly. Each one runs
#
#     claude-launcher-session <tmux-session-name> <shell command>
#
# which hosts the command inside a tmux session on a private socket. The tab
# still looks and behaves like a plain terminal (see
# tmux/claude-launcher.tmux.conf for how tmux is made invisible), but the
# session's screen is now shareable — which is what the mirror desktop needs.
# `claude-launcher-session` owns the teardown: when the window or tab closes it
# gets SIGHUP and kills both the session and its mirror, so nothing survives in
# the background.
#
# ---------------------------------------------------------------------------
# The mirror desktop (both layouts, on by default)
# ---------------------------------------------------------------------------
# A SINGLETON iTerm2 window created from the `ClaudeLauncher Mirror` profile,
# which is born in native macOS fullscreen and therefore gets its own Space.
# Inside it is a SINGLE SHARED TAB — one tab for the window's whole life, holding
# every console from every launch on every desktop, so they can all be watched
# at once. Each launch adds one pane PER PRIMARY SESSION, running
# `claude-launcher-mirror <tmux-session-name>` (a read-only, size-ignoring second
# tmux client on that session). The FIRST launch into a fresh window lays its
# sessions out cleanly (a 4-session `grid` launch fans into a balanced 2x2); a
# later launch APPENDS its panes by splitting existing ones. A shared tab has no
# per-launch title, so each pane is instead NAMED after its folder, keeping
# projects distinguishable. Set ${PREFIX}_OVERVIEW=0 to skip the mirror.
#
# The mirror is an ENHANCEMENT, never a dependency: every part of it is wrapped
# so that a failure is reported and then ignored, and the launch still succeeds.
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
#       Echo the shell command each session should run *after* it cd's into
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
#   ${PREFIX}_MIN_COL    minimum session width in points that `auto` requires
#                        before it chooses the grid (default 640)
#   ${PREFIX}_OVERVIEW   1 (default) build the mirror/overview desktop | 0 skip
#                        it. The escape hatch when the fullscreen mirror window
#                        is unwanted or misbehaving; the launch is identical
#                        otherwise.

# ---------------------------------------------------------------------------
# Engine-wide constants
# ---------------------------------------------------------------------------

# The two dynamic profiles from iterm/claude-launcher.json. They are looked up
# BY NAME, so renaming a profile there means renaming it here.
LAUNCHER_ITERM_PROFILE="${LAUNCHER_ITERM_PROFILE:-ClaudeLauncher}"
LAUNCHER_ITERM_MIRROR_PROFILE="${LAUNCHER_ITERM_MIRROR_PROFILE:-ClaudeLauncher Mirror}"

# HOW THE MIRROR WINDOW GETS ITS OWN SPACE — build-then-fullscreen.
#
# The mirror window is created as an ORDINARY window (its profile sets
# "Window Type": 0) and only AFTER all its structural work is done — splits,
# sentinel tagging, pane labels — is it toggled into native macOS fullscreen,
# which is what makes macOS give it its own Space.
#
# It used to be born fullscreen ("Window Type": 12, LION_FULL_SCREEN). That was
# abandoned: a born-fullscreen window animates onto its own Space AT CREATION,
# and iTerm2's window/session references are unstable during that animation —
# splitting and, fatally, the sentinel `set variable` silently threw, so the
# singleton could never be found again and every launch spawned a fresh overview
# window on a Space the user wasn't looking at. Building on a stable normal
# window and fullscreening last sidesteps both that ref-instability AND the
# window-id reassignment the transition causes.
#
# iTerm2 has NO scriptable fullscreen (verified against its dictionary — `zoomed`
# is the green-button *maximize*, which does NOT create a Space). So the toggle
# is driven through the View > "Toggle Full Screen" menu item via System Events,
# which needs Accessibility permission — already required for VS Code
# positioning, so no new permission. It is fully guarded and non-fatal: if the
# toggle fails, the mirror is still a usable normal window and the overview still
# works, just not on a separate Space. There is no scriptable way to ask which
# Space a window is on, so a non-fullscreen outcome cannot be detected here — it
# is surfaced only by the user seeing a normal window.

# Which physical axis iTerm2's `split vertically` produces is UNVERIFIED (the
# name follows the menu item, and iTerm2's menu wording has historically not
# matched the intuitive reading). This is the PRIMARY split axis of a mirror
# tab:
#   * 2 panes (stacked launch)  -> a single split along this axis.
#   * 4 panes (grid launch)     -> the tab is first split along this axis into
#     two columns, then each column is split along the PERPENDICULAR axis, for a
#     balanced 2x2. The perpendicular is derived from this word, so this one
#     setting still controls the whole arrangement.
# If the panes come out on the wrong axis, flip this one word to "horizontally"
# — it is the only place the axis is named.
LAUNCHER_MIRROR_SPLIT_AXIS="${LAUNCHER_MIRROR_SPLIT_AXIS:-vertically}"

# The tmux socket the session and mirror wrappers share. MUST match `SOCKET` in
# `claude-launcher-session` and `claude-launcher-mirror`; the engine only ever
# uses it to *poll* for a session, never to create one.
LAUNCHER_TMUX_SOCKET="claudelauncher"

# Resolve the helper scripts that live next to this file, following any symlinks
# (the launchers are normally symlinked onto PATH from ~/.local/bin, and this
# library is sourced through that resolved path). Absolute paths matter: these
# are typed into a shell that may have any PATH, and the directory holding them
# can contain spaces.
_launcher_src="${BASH_SOURCE[0]}"
while [[ -h "$_launcher_src" ]]; do
  _launcher_dir="$(cd -P "$(dirname "$_launcher_src")" && pwd)"
  _launcher_src="$(readlink "$_launcher_src")"
  [[ "$_launcher_src" != /* ]] && _launcher_src="$_launcher_dir/$_launcher_src"
done
LAUNCHER_LIB_DIR="$(cd -P "$(dirname "$_launcher_src")" && pwd)"
unset _launcher_src _launcher_dir

# Both wrappers are named `claude-launcher-*` for historical reasons but are
# tool-agnostic: `copilot-launcher` uses exactly the same two.
LAUNCHER_SESSION_BIN="$LAUNCHER_LIB_DIR/claude-launcher-session"
LAUNCHER_MIRROR_BIN="$LAUNCHER_LIB_DIR/claude-launcher-mirror"

# ---------------------------------------------------------------------------
# _launcher_tmux_bin
#   Path to tmux, preferring PATH and falling back to Homebrew's location — the
#   same fallback `claude-launcher-session` makes, and for the same reason: a
#   GUI-launched process does not always inherit a PATH with /opt/homebrew/bin.
# ---------------------------------------------------------------------------
_launcher_tmux_bin() {
  local bin
  bin="$(command -v tmux || true)"
  [[ -n "$bin" ]] || bin="/opt/homebrew/bin/tmux"
  printf '%s' "$bin"
}

# ---------------------------------------------------------------------------
# _launcher_wait_for_tmux <session-name>...
#   Block until every named tmux session exists on the launcher's socket, or
#   give up after ~10s and return non-zero.
#
#   This is load-bearing for the mirror. The engine only *types* the session
#   command into a fresh iTerm2 tab; by the time `osascript` returns, iTerm2 has
#   accepted the text but the shell may not even have started, let alone tmux.
#   `claude-launcher-mirror` deliberately refuses to create a server (it prints
#   "No session ... to mirror." and exits 0 rather than hanging), so firing the
#   mirror panes too early produces a desktop full of that message. Polling here
#   is the only synchronisation point available — nothing in the AppleScript
#   layer can observe a tmux session.
#
#   `=name` forces an exact match; a bare `-t foo` would also match `foo__mirror`.
# ---------------------------------------------------------------------------
_launcher_wait_for_tmux() {
  local tmuxBin name waited=0 ok
  tmuxBin="$(_launcher_tmux_bin)"
  [[ -x "$tmuxBin" ]] || return 1
  while (( waited < 100 )); do
    ok=1
    for name in "$@"; do
      "$tmuxBin" -L "$LAUNCHER_TMUX_SOCKET" has-session -t "=$name" 2>/dev/null || { ok=0; break; }
    done
    (( ok == 1 )) && return 0
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  return 1
}

# ---------------------------------------------------------------------------
# launcher_main <folder> [tool-args...]
#   Runs the whole flow: resolve folder, measure the screen, launch VS Code and
#   the iTerm2 sessions, tile everything, build the mirror desktop, and
#   (optionally) record the session.
# ---------------------------------------------------------------------------
launcher_main() {
  set -euo pipefail

  local prefix="${LAUNCHER_ENV_PREFIX:?LAUNCHER_ENV_PREFIX must be set}"
  local name="${LAUNCHER_NAME:?LAUNCHER_NAME must be set}"
  local usage="${LAUNCHER_USAGE:-Usage: $name [folder]}"
  local record="${LAUNCHER_RECORD:-0}"

  # Layout controls, read from the launcher's own env namespace.
  local layout minCol overview
  eval "layout=\"\${${prefix}_LAYOUT:-auto}\""
  eval "minCol=\"\${${prefix}_MIN_COL:-640}\""
  # The overview/mirror desktop is on unless explicitly set to 0. Any other
  # value (including the default) means "build it".
  eval "overview=\"\${${prefix}_OVERVIEW:-1}\""
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

  # The command each session runs after cd'ing into the folder. Everything
  # tool-specific lives behind this one hook.
  local cmd
  cmd="$(launcher_build_command "$folder" "$@")"

  # The launch id. Computed here rather than in the recording step at the end,
  # because the tmux session names are derived from it and they are needed long
  # before that — and because `copilot-launcher` does not record at all but
  # still needs unique names. `date +%Y%m%d-%H%M%S` plus the pid is unique per
  # launch, and contains neither `.` nor `:`, both of which tmux treats as
  # target separators (`session:window.pane`) and would mangle.
  local sid
  sid="$(date +%Y%m%d-%H%M%S)-$$"

  # The state dir is needed whether or not this launcher records launches: the
  # mirror window's id is persisted there so the window can be reused as a
  # singleton across launches.
  local STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$name"

  # -------------------------------------------------------------------------
  # 2. Read the Dock-aware *visible frame* and compute the window boxes.
  #    NSScreen.visibleFrame excludes the menu bar and the Dock, so windows
  #    tile flush to those instead of hiding underneath them. JXA returns it as
  #    "VX VY VW VH" already converted to AppleScript's top-left coordinates —
  #    which is also exactly what iTerm2's `bounds` wants (a QuickDraw rect,
  #    {left, top, right, bottom}, top-left origin), so none of the coordinate
  #    maths below changed in the move off Terminal.app.
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
  xHalf=$(( VX + VW / 2 ))          # boundary between VS Code (left) and sessions (right)
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

  # Pick the layout. In the grid each session is a quarter of the screen wide;
  # if that falls below $minCol points, stack two full-half-width sessions in
  # one window instead. A 16" MacBook Pro (1728pt) yields 432pt columns and so
  # stacks; a 5K display (2560pt) yields 640pt columns and so grids.
  if [[ "$layout" == "auto" ]]; then
    if (( VW / 4 >= minCol )); then layout="grid"; else layout="stacked"; fi
  fi

  # Window boxes over the right half, in creation order: a flat run of
  # {left top right bottom} integers, four per WINDOW, passed straight to
  # osascript. `perWindow` is how many tabs (and therefore sessions) each of
  # those windows holds.
  local -a boxes
  local perWindow
  if [[ "$layout" == "grid" ]]; then
    #   TL              TR      four windows, one session each
    #   BL              BR
    boxes=(
      "$xHalf"    "$yTop"  "$xColMid"  "$yMid"
      "$xColMid"  "$yTop"  "$xRight"   "$yMid"
      "$xHalf"    "$yMid"  "$xColMid"  "$yBottom"
      "$xColMid"  "$yMid"  "$xRight"   "$yBottom"
    )
    perWindow=1
  else
    #   one window over the whole right half, holding two tabs
    boxes=(
      "$xHalf"  "$yTop"  "$xRight"  "$yBottom"
    )
    perWindow=2
  fi
  local winCount=$(( ${#boxes[@]} / 4 ))
  local sessionCount=$(( winCount * perWindow ))

  # One tmux session name per terminal session, in creation order (window-major:
  # window 0's tabs first, then window 1's, ...). The AppleScript below consumes
  # them in exactly that order.
  local -a tmuxNames
  local i
  for (( i = 0; i < sessionCount; i++ )); do
    tmuxNames+=( "cl-${sid}-${i}" )
  done

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
  #    "diff to touch only what we created" guarantee the iTerm2 step gets for
  #    free from `create window with profile` returning the window it made).
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
  # 4. Open the iTerm2 windows/tabs, tile them into the right half, and start a
  #    tmux-hosted session in each.
  #
  #    THE THREE LEVELS OF QUOTING. What ends up running is
  #
  #        <session-wrapper> <tmux-name> <shell command>
  #
  #    typed into a shell. Each level is handled by a different mechanism, and
  #    they never nest:
  #
  #      1. bash -> osascript: every piece is a separate `argv` element, quoted
  #         with plain "$var". No escaping, no interpolation.
  #      2. osascript -> AppleScript source: NONE. The values arrive as `argv`
  #         at runtime, so they are never part of the script text — which is why
  #         this heredoc is quoted ('APPLESCRIPT') and contains no substitutions.
  #      3. AppleScript -> shell: `quoted form of` wraps each of the three
  #         arguments in POSIX single quotes, escaping any embedded quote as
  #         '\''. This is the only escaping that happens anywhere, and it is
  #         done by AppleScript itself rather than by hand.
  #
  #    WHY `write text` AND NOT the `command` parameter of `create window with
  #    profile`: iTerm2 does not hand a profile command to a shell — it splits
  #    the string into argv with its own tokenizer and execs it. That tokenizer
  #    is undocumented, and the wrapper's absolute path routinely contains
  #    spaces (this repo lives under "AI Projects"), so relying on it would put
  #    the whole launcher at the mercy of an unspecified quoting dialect.
  #    `write text` means "send text as though it was typed", so the session's
  #    login shell parses it with ordinary, specified POSIX rules — and, as a
  #    bonus, the command stays visible in the scrollback and a wrapper that
  #    fails leaves its error on screen instead of vanishing with the window.
  #    (Terminal.app's `do script` behaved the same way, so the tab's
  #    "command echoed at the top" look is unchanged.)
  #
  #    TRAP, why bounds are set BEFORE the command is written: tmux sizes its
  #    session from the terminal it is started in. Writing first would start
  #    Claude Code at the window's default geometry and then force a full
  #    reflow on the resize; setting bounds first means the session is born at
  #    its final size.
  #
  #    TRAP, tabs have NO IDENTIFIER: iTerm2's `tab` class has only a mutable
  #    `index` and a read/write `title` — no id of any kind. So a tab can never
  #    be recorded or looked up later. Everything durable here is keyed on the
  #    window's `id` (integer, stable for the window's life) or the session's
  #    `id` (a text guid, likewise stable). The `tab k of theWindow` indexing
  #    below is safe only because the tabs were created moments earlier, in
  #    order, in a window nothing else has touched.
  #
  #    No `activate`: creating a window without activating iTerm2 is what keeps
  #    it on the *current* Space, exactly as with Terminal.app's `do script`.
  #    Activating could jump to a Space where iTerm2 already has windows.
  #
  #    Arguments: profile, wrapper path, folder, command, window count, tabs per
  #    window, then winCount boxes of 4 integers, then sessionCount tmux names.
  # -------------------------------------------------------------------------
  local termData
  termData="$(osascript - \
      "$LAUNCHER_ITERM_PROFILE" "$LAUNCHER_SESSION_BIN" "$folder" "$cmd" \
      "$winCount" "$perWindow" "${boxes[@]}" "${tmuxNames[@]}" <<'APPLESCRIPT'
on run argv
    set profileName to item 1 of argv
    set sessionBin to item 2 of argv
    set theFolder to item 3 of argv
    set theCmd to item 4 of argv
    set winCount to (item 5 of argv) as integer
    set perWindow to (item 6 of argv) as integer

    -- Boxes start at item 7, four integers each; the tmux session names follow
    -- them, one per session, in window-major creation order.
    set boxBase to 7
    set nameBase to boxBase + (winCount * 4)

    -- Level 3 of the quoting, part one: the command each session runs *after*
    -- cd'ing into the folder. `quoted form of` is AppleScript's POSIX-shell
    -- quoter, so a folder with spaces, quotes or `$` in its name is safe.
    set innerCmd to "cd " & quoted form of theFolder & " && " & theCmd

    -- One "windowID|sessionGUID|tty" record per session, comma separated. The
    -- shell splits on those two characters, neither of which can appear in an
    -- iTerm2 window id (an integer), a session guid, or a tty path.
    set recs to {}

    tell application "iTerm2"
        repeat with wi from 0 to (winCount - 1)
            set L to (item (boxBase + wi * 4) of argv) as integer
            set T to (item (boxBase + wi * 4 + 1) of argv) as integer
            set R to (item (boxBase + wi * 4 + 2) of argv) as integer
            set Bo to (item (boxBase + wi * 4 + 3) of argv) as integer

            -- `create window with profile` takes the profile NAME as its direct
            -- parameter and returns the window it made, so there is no need for
            -- the id-diffing dance Terminal.app required to tell our new window
            -- apart from a pre-existing one.
            set theWindow to (create window with profile profileName)

            -- Extra tabs, if this layout wants more than one session per window.
            -- `create tab` takes the WINDOW as its direct parameter (not a tab),
            -- and `with profile` is a parameter.
            repeat with k from 2 to perWindow
                tell theWindow
                    create tab with profile profileName
                end tell
            end repeat

            -- Geometry before commands (see the block comment above). `bounds`
            -- is {left, top, right, bottom} with a top-left origin. Wrapped in
            -- `try`: iTerm2 snaps a window to whole character cells, and a
            -- profile with window resizing disabled would refuse outright —
            -- neither is worth losing the session over.
            try
                set bounds of theWindow to {L, T, R, Bo}
            end try

            set winID to (id of theWindow) as text

            repeat with k from 1 to perWindow
                set theSession to current session of (tab k of theWindow)
                set tmuxName to item (nameBase + (wi * perWindow) + (k - 1)) of argv

                -- Level 3 of the quoting, part two. Three shell words, each
                -- independently quoted by AppleScript.
                --
                -- TRAP: this line is typed into a tty in canonical mode, where
                -- Darwin's MAX_CANON caps a single line at 1024 bytes. A very
                -- long `launcher_build_command` output (or a deeply nested
                -- folder path, which gets quoted twice over) could silently
                -- lose its tail. Nothing here can detect that; keep the built
                -- command short.
                set fullCmd to quoted form of sessionBin & " " & quoted form of tmuxName & " " & quoted form of innerCmd

                -- The shell may not have finished starting when the text
                -- arrives. The tty buffers it, so this is normally harmless,
                -- but a small delay keeps the echoed line from being chewed up
                -- by a shell that is still printing its first prompt.
                delay 0.3
                tell theSession to write text fullCmd

                set sTTY to ""
                try
                    set sTTY to tty of theSession
                end try
                set end of recs to winID & "|" & ((id of theSession) as text) & "|" & sTTY
            end repeat
        end repeat
    end tell

    set AppleScript's text item delimiters to ","
    set out to recs as text
    set AppleScript's text item delimiters to ""
    return out
end run
APPLESCRIPT
)"

  # Split the records into parallel lists. `terminal_ids` deliberately keeps its
  # old name and old shape (a space-separated list of window ids) so that the
  # existing session-file parser and the `-close` command keep working; it now
  # carries iTerm2 window ids rather than Terminal.app ones. A window id repeats
  # once per tab in the stacked layout, so it is de-duplicated.
  local term_ids="" term_ttys="" sess_ids="" rec winid guid tty seen
  local -a _recs
  # Guarded: `for x in "${arr[@]}"` on an empty array is an unbound-variable
  # error under `set -u` in bash 3.2, which is still what /bin/bash is on macOS.
  if [[ -n "${termData:-}" ]]; then
    IFS=',' read -ra _recs <<< "$termData"
    for rec in "${_recs[@]}"; do
      [[ -z "$rec" ]] && continue
      winid="${rec%%|*}"
      guid="${rec#*|}"; tty="${guid#*|}"; guid="${guid%%|*}"
      seen=" $term_ids "
      [[ "$seen" != *" $winid "* ]] && term_ids+="$winid "
      [[ -n "$guid" ]] && sess_ids+="$guid "
      [[ -n "$tty" ]] && term_ttys+="$tty "
    done
  fi

  # -------------------------------------------------------------------------
  # 5. Position the VS Code window into the left half.
  #    This drives another process via System Events, which needs Accessibility
  #    permission for the app running this script. Wrapped in `try` so a missing
  #    permission never aborts the (already tiled) sessions.
  # -------------------------------------------------------------------------
  osascript - "$vsX" "$vsY" "$vsW" "$vsH" "$folderName" "${vscodeBefore:-}" <<'APPLESCRIPT' 2>/dev/null || true
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

  # -------------------------------------------------------------------------
  # 6. The mirror desktop (BOTH layouts; disabled with ${PREFIX}_OVERVIEW=0).
  #
  #    One pane per PRIMARY SESSION this launch created — 2 for stacked, 4 for
  #    grid — all passed as `tmuxNames`, so the pane count follows the layout
  #    without being hard-coded. There is ONE shared tab in the mirror window for
  #    all launches: the first launch into a fresh window lays its panes out (2x2
  #    for four, else a chain); every later launch APPENDS its panes by splitting
  #    into that same tab. See the AppleScript for the single-shared-tab invariant.
  #
  #    Deliberately LAST. Creating a native-fullscreen window makes macOS switch
  #    to the new Space, which would otherwise happen in the middle of tiling
  #    and leave the rest of the launch running against a desktop the user is no
  #    longer looking at.
  #
  #    Every failure path here is non-fatal: the launch has already succeeded by
  #    this point, and the mirror is an enhancement. The 4-pane grid case must
  #    never become a new way for the launch to fail.
  # -------------------------------------------------------------------------
  local mirror_win="" mirror_sess=""
  if [[ "$overview" != "0" ]]; then
    mkdir -p "$STATE_DIR"
    local overviewFile="$STATE_DIR/overview"

    # NOTE: the mirror window is NO LONGER found by a recorded id. A window
    # created with `Window Type: 12` (native fullscreen) animates into its own
    # Space, and iTerm2 REASSIGNS its window id during that transition — so the
    # id `create window` returns (and that we used to persist here) is stale
    # moments later, which made a 2nd launch fail its singleton check and open a
    # SECOND mirror window. The AppleScript below instead finds the shared window
    # by a content SENTINEL: a session user variable set on every mirror pane.
    # `$overviewFile` is still written from the returned id purely for
    # logging/back-compat (and for claude-launcher-close's best-effort pointer
    # prune); nothing functional depends on it anymore.

    # A mirror pane that starts before its tmux session exists just prints
    # "No session ... to mirror." and exits, so wait for the real sessions
    # first. If they never appear, skip the mirror entirely rather than paper
    # a desktop with that message.
    if _launcher_wait_for_tmux "${tmuxNames[@]}"; then
      # Success is marked with an "OK|" prefix so that an AppleScript error —
      # which osascript prints on stderr, folded in here — can be told apart
      # from a result and reported verbatim.
      local mirrorOut
      mirrorOut="$(osascript - \
          "$LAUNCHER_ITERM_MIRROR_PROFILE" "$LAUNCHER_MIRROR_BIN" "$folderName" \
          "$LAUNCHER_MIRROR_SPLIT_AXIS" "${tmuxNames[@]}" 2>&1 <<'APPLESCRIPT' || true
on run argv
    set mirrorProfile to item 1 of argv
    set mirrorBin to item 2 of argv
    set paneLabel to item 3 of argv
    set splitAxis to item 4 of argv
    set nameBase to 5
    set paneCount to (count of argv) - (nameBase - 1)

    -- The sentinel: an iTerm2 SESSION USER VARIABLE (must be `user.`-prefixed)
    -- set on every mirror pane. It is how the singleton window is found again on
    -- a later launch — chosen over the window id (which the fullscreen Space
    -- transition reassigns) and over the session `name` (which tmux's
    -- `set-titles on` can overwrite via OSC). A session guid, and any user var
    -- keyed to it, is stable for the session's life.
    set sentinel to "user.claudeLauncherOverview"

    set guids to {}
    set winID to ""

    -- Find the existing shared mirror window by sentinel, BEFORE creating
    -- anything. `missing value` means none exists yet (first launch, or the user
    -- closed it) and we make a fresh one.
    set foundID to my findOverviewID(sentinel)

    set isNewWindow to false
    tell application "iTerm2"
        if foundID is missing value then
            -- Create the mirror window as an ORDINARY window (its profile now
            -- sets "Window Type": 0). It is NOT fullscreen yet, so its refs are
            -- stable and every split/tag/label below is reliable. Native
            -- fullscreen — and therefore its own Space — is toggled LAST, once
            -- all that work is done. See the build-then-fullscreen comment at the
            -- top of launcher-common.sh.
            set theWindow to (create window with profile mirrorProfile)
            set isNewWindow to true
            -- Small settle before touching it. A tag SET too soon after `create
            -- window` was observed to not land — the window isn't ready yet.
            -- setSentinelVerified below retries too, but this keeps the common
            -- path to a single confirmed set instead of several wasted retries.
            delay 0.3
        else
            -- Reuse the shared window found by sentinel. foundID was read from a
            -- SETTLED window (a prior launch's fullscreen finished long ago), so
            -- `window id foundID` resolves reliably.
            set theWindow to window id foundID
        end if

        -- Capture the id WHILE THE WINDOW IS STABLE. Fresh: it is still a normal
        -- window (the fullscreen toggle, which can reassign the id, happens after
        -- this). Reuse: it is long settled. Either way this id is correct — the
        -- stale-id bug came from reading it mid-transition, which no longer
        -- happens. It is still only used for logging/back-compat; reuse keys on
        -- the sentinel, not this.
        set winID to (id of theWindow) as text

        -- THE SINGLE-SHARED-TAB INVARIANT. The mirror window holds exactly ONE
        -- tab for its whole life — never a second one. Every launch, on every
        -- desktop, feeds its panes into that one tab, so all consoles sit
        -- together in a single overview. Because there is only ever one tab,
        -- `tab 1` is a stable handle despite tabs having no id (recon). We
        -- therefore NEVER `create tab` here: a fresh window is used via the tab
        -- it is born with, an existing one via its `tab 1`. This is the hard
        -- requirement of this step; do not reintroduce `create tab`.
        set theTab to tab 1 of theWindow

        -- CHEAP INSURANCE (timing). The singleton must be guaranteed findable
        -- BEFORE any structural work (a split could throw) and BEFORE fullscreen,
        -- so confirm the tag on the tab's current session right now: set it, read
        -- it back, bounded retry. On a fresh window this is the anchor a later
        -- launch's sentinel search will match; on a reuse it re-confirms the tag
        -- a prior launch set (idempotent). If it never confirms we do NOT abort —
        -- we carry on and surface it as `tagfail` in the return string, because
        -- an untagged-but-working overview beats no overview.
        set tagOK to my setSentinelVerified(current session of theTab, sentinel)

        if isNewWindow then
            -- FRESH shared tab: lay THIS launch out cleanly, exactly as the
            -- confirmed-working first-launch path did — the tab's own session is
            -- pane 1, and a 4-session launch fans into a balanced 2x2.
            set firstSession to current session of theTab
            set paneSessions to {firstSession}

            if paneCount is 4 then
                -- Balanced 2x2. Split the tab into two columns along the primary
                -- axis, then split EACH column along the perpendicular axis —
                -- four roughly equal panes rather than one wide pane + three
                -- slivers. Order is TL, TR, BL, BR: firstSession is the left
                -- column and colB the right, each perpendicular split dropping
                -- its new pane below the one it split.
                set perpAxis to my perpOf(splitAxis)
                set colB to my doSplit(firstSession, splitAxis, mirrorProfile)
                set blSession to my doSplit(firstSession, perpAxis, mirrorProfile)
                set brSession to my doSplit(colB, perpAxis, mirrorProfile)
                set paneSessions to {firstSession, colB, blSession, brSession}
            else
                -- One-axis chain for any other count (2 = the stacked layout).
                set chainSession to firstSession
                repeat with k from 2 to paneCount
                    set chainSession to my doSplit(chainSession, splitAxis, mirrorProfile)
                    set end of paneSessions to chainSession
                end repeat
            end if
        else
            -- APPEND into the existing shared tab. EVERY session this launch
            -- adds is a NEW split of a pane already in the tab — never the tab's
            -- own first session, which belongs to an earlier launch and must
            -- keep running untouched. Perfect tiling is impossible through
            -- scripted splits (there is no "tile these N sessions" command), so
            -- appendPane only tries not to go maximally lopsided: it splits the
            -- LARGEST current pane along its longer dimension each time.
            set paneSessions to {}
            repeat paneCount times
                set end of paneSessions to my appendPane(theTab, mirrorProfile)
            end repeat
        end if

        -- For each pane THIS launch added: record its GUID (teardown is
        -- GUID-based, so closing exactly these leaves other launches' panes in
        -- the shared tab alone), label it by folder, and start the mirror.
        repeat with k from 1 to (count of paneSessions)
            set paneSession to item k of paneSessions
            set end of guids to ((id of paneSession) as text)

            -- Per-pane label replaces the per-launch tab title we used to set:
            -- with one shared tab there is no tab title to tell projects apart,
            -- so each pane is named after its folder instead.
            --
            -- TRAP: the tmux config sets `set-titles on`, so the mirrored
            -- session may push an OSC title that iTerm2 uses to OVERWRITE this
            -- name. Set it anyway, in a try; whether it sticks is a live
            -- verification item. If it does not, the fix is likely turning off
            -- set-titles / allow-rename for the mirror profile, to be decided
            -- after the user tests.
            try
                set name of paneSession to paneLabel
            end try

            -- Tag every pane, not just the first, so the singleton stays findable
            -- as long as ANY of this launch's panes survives.
            try
                tell paneSession to set variable named sentinel to "1"
            end try

            my writeMirror(paneSession, mirrorBin, item (nameBase + k - 1) of argv)
        end repeat
    end tell

    -- The sentinel was already confirmed on a stable window up front (see the
    -- readback-verify right after `tab 1` was acquired); `tagOK` carries that
    -- result. Doing it there — before the splits and before fullscreen — is what
    -- guarantees the singleton is findable even if a later step throws.

    -- LAST of all, and only for a freshly created window: toggle it into native
    -- fullscreen so macOS hands it its own Space. Everything structural is
    -- already done on the stable window, so a failure here only costs the
    -- separate Space, not the overview. A reused window is already fullscreen
    -- and must NOT be toggled. Non-fatal by construction (see the handler).
    set newFlag to "reuse"
    if isNewWindow then
        set newFlag to "new"
        my enterFullScreen(theWindow)
    end if

    set tagFlag to "tagfail"
    if tagOK then set tagFlag to "tagok"

    set AppleScript's text item delimiters to ","
    set out to guids as text
    set AppleScript's text item delimiters to ""
    -- Fields: OK | window-id | pane-guids(csv) | new|reuse | tagok|tagfail
    return "OK|" & winID & "|" & out & "|" & newFlag & "|" & tagFlag
end run

-- Find the shared mirror window by SENTINEL: the window holding a session whose
-- `sentinel` user variable is "1". Returns that window's id (an integer, read
-- fresh from a settled window so it is current), or `missing value` if none.
--
-- Why search instead of `window id N`: a native-fullscreen window's id is
-- reassigned by the Space transition, so a persisted id goes stale. A session
-- user variable rides on the session's stable guid and survives it, and also
-- survives an iTerm2 restart within the sessions' life. Every read is wrapped so
-- an odd session (or an unset variable, which returns empty) is simply skipped.
on findOverviewID(sentinel)
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    try
                        set v to ""
                        tell s to set v to (variable named sentinel)
                        if v is "1" then return (id of w)
                    end try
                end repeat
            end repeat
        end repeat
    end tell
    return missing value
end findOverviewID

-- Set the sentinel on a session and CONFIRM it by reading it back, retrying a
-- few times (~2s total) before giving up. Returns true once confirmed, false if
-- it never sticks. The set/read spelling here is the one verified working on a
-- live settled session; on a stable (non-fullscreen) window it should confirm on
-- the first pass, so the loop only earns its keep if a set is ever racing some
-- transient. `set variable` / `variable named` are the iTerm2 commands, driven
-- with `tell sess to` so the session is their direct parameter.
on setSentinelVerified(sess, sentinel)
    set v to ""
    repeat 10 times
        try
            tell application "iTerm2"
                tell sess to set variable named sentinel to "1"
            end tell
        end try
        try
            tell application "iTerm2"
                tell sess to set v to (variable named sentinel)
            end tell
            if v is "1" then return true
        end try
        delay 0.2
    end repeat
    return false
end setSentinelVerified

-- Put a window into native macOS fullscreen (its own Space). iTerm2 exposes no
-- scriptable fullscreen, so this goes through the View > "Toggle Full Screen"
-- menu item via System Events. The window is raised to the front first, because
-- a menu command acts on the app's key window. Everything is wrapped and
-- non-fatal: a missing Accessibility permission, a renamed menu item, or any
-- other failure just leaves a usable normal mirror window behind.
--
-- ASSUMPTION (verification item): the item is literally titled "Toggle Full
-- Screen" and, with iTerm2's "Native full screen windows" preference on (the
-- same regime under which the old Window Type 12 gave a Space), it produces
-- NATIVE fullscreen rather than iTerm2's own no-Space fullscreen. If it lands
-- without a separate Space, that preference (or the exact item title) is what to
-- check.
on enterFullScreen(theWindow)
    try
        tell application "iTerm2"
            activate
            select theWindow
        end tell
        -- Let the raise settle so System Events sees the right key window.
        delay 0.3
        tell application "System Events" to tell process "iTerm2"
            click menu item "Toggle Full Screen" of menu 1 of menu bar item "View" of menu bar 1
        end tell
    end try
end enterFullScreen

-- Split `sess` along the named axis with the mirror profile and return the new
-- session. Factored out so the 2x2 and the fallback chain share the ONE place
-- where the unverified axis-word -> physical-direction mapping lives.
on doSplit(sess, axisWord, prof)
    tell application "iTerm2"
        if axisWord is "horizontally" then
            tell sess to set newSession to (split horizontally with profile prof)
        else
            tell sess to set newSession to (split vertically with profile prof)
        end if
    end tell
    return newSession
end doSplit

-- The other axis, for the second level of the 2x2.
on perpOf(axisWord)
    if axisWord is "horizontally" then
        return "vertically"
    else
        return "horizontally"
    end if
end perpOf

-- Type the mirror command into a pane. The 0.3s delay guards the same race as
-- the primary sessions do: the pane's shell may not have finished starting when
-- the text arrives.
on writeMirror(sess, mirrorBin, tmuxName)
    tell application "iTerm2"
        delay 0.3
        tell sess to write text (quoted form of mirrorBin & " " & quoted form of tmuxName)
    end tell
end writeMirror

-- Add ONE pane to an already-populated shared tab and return the new session.
-- Heuristic: split the LARGEST current pane (by cell area) along its longer
-- dimension, so repeated appends across many launches stay roughly balanced
-- instead of carving one corner into ever-thinner slivers. Perfect tiling is
-- not achievable through scripted splits — iTerm2 offers no "tile these N"
-- command — so this is only a lopsidedness guard, not a real tiler.
--
-- The pane is picked BY INDEX, not by capturing the loop reference: `contents
-- of s` (the natural way to dereference a `repeat with s in ...` item) collides
-- with the session's own `contents` property (its visible text), so the largest
-- session is tracked as an index and re-fetched as `session i of theTab`.
--
-- Axis: terminal cells are ~twice as tall as wide, so a pane looks square at
-- about columns = 2*rows. A pane wider than that is halved left/right
-- ("vertically", which the live 2x2 confirmed is the side-by-side axis);
-- otherwise it is halved top/bottom. Both go through doSplit, the one place the
-- axis word maps to a command.
on appendPane(theTab, prof)
    set bestIndex to 1
    set bestArea to -1
    tell application "iTerm2"
        set n to (count of sessions of theTab)
        repeat with i from 1 to n
            set s to session i of theTab
            set a to ((columns of s) * (rows of s))
            if a > bestArea then
                set bestArea to a
                set bestIndex to i
            end if
        end repeat
        set best to session bestIndex of theTab
        set wideEnough to ((columns of best) > (2 * (rows of best)))
    end tell
    if wideEnough then
        return my doSplit(best, "vertically", prof)
    else
        return my doSplit(best, "horizontally", prof)
    end if
end appendPane
APPLESCRIPT
)"
      if [[ "$mirrorOut" == OK\|* ]]; then
        # Return shape: OK | window-id | pane-guids(csv) | new|reuse | tagok|tagfail
        # Split on '|' only; the guid field is comma-separated, never piped.
        local _rest mNew mTag
        _rest="${mirrorOut#OK|}"
        mirror_win="${_rest%%|*}"; _rest="${_rest#*|}"
        mirror_sess="${_rest%%|*}"; _rest="${_rest#*|}"
        mNew="${_rest%%|*}"; _rest="${_rest#*|}"
        mTag="${_rest%%|*}"
        mirror_sess="${mirror_sess//,/ }"
        [[ -n "$mirror_win" ]] && printf '%s\n' "$mirror_win" > "$overviewFile"
        # Make a fresh overview window OBSERVABLE: it opens on its OWN Space,
        # which may not be the desktop the user is viewing, so announce it rather
        # than let a new window read as "nothing happened".
        if [[ "$mNew" == "new" ]]; then
          echo "$name: created a NEW overview window on its own Space (not appended)" >&2
        fi
        # Surface a tag that did not stick: the next launch would then fail to
        # find this window by sentinel and open another overview instead of
        # appending. (Should not happen now that tagging runs on a stable window.)
        if [[ "$mTag" == "tagfail" ]]; then
          echo "$name: WARNING overview singleton tag did not verify — a later launch may open a second overview window instead of appending" >&2
        fi
      else
        echo "$name: mirror desktop unavailable (launch is fine): ${mirrorOut:-no output from iTerm2}" >&2
      fi
    else
      echo "$name: mirror desktop skipped — the tmux sessions did not come up in time (launch is fine)" >&2
    fi
  fi

  # -------------------------------------------------------------------------
  # 7. Optionally record what this launch created, so a companion `-close`
  #    command can later tear down exactly those windows, sessions and tmux
  #    sessions (and only those).
  #
  #    Format is one `key=value` per line, parsed WITHOUT sourcing (values such
  #    as the folder path contain spaces). Keys added for iTerm2 sit alongside
  #    the original ones rather than replacing them:
  #
  #      terminal_ids     iTerm2 WINDOW ids, de-duplicated (was Terminal.app
  #                       window ids — same meaning, same shape)
  #      terminal_ttys    one tty per session, as before
  #      iterm_session_ids  the primary sessions' guids, in creation order
  #      tmux_sessions      the tmux session name behind each of those, same order
  #      mirror_window_id   the singleton overview window, if one was built
  #      mirror_session_ids the guids of THIS launch's mirror panes. Closing
  #                       those sessions is how a teardown collapses the launch's
  #                       tab on the overview desktop — a tab has no id, so there
  #                       is nothing else to aim at.
  #      session_count      how many sessions the launch has (window count is
  #                       implied by the layout).
  # -------------------------------------------------------------------------
  if [[ "$record" == "1" ]]; then
    mkdir -p "$STATE_DIR/sessions"
    local sfile="$STATE_DIR/sessions/$sid.session"
    {
      echo "session=$sid"
      echo "created_at=$(date +%s)"
      echo "folder=$folder"
      echo "layout=$layout"
      echo "vscode_title=$folderName"
      echo "terminal_ids=$(echo "$term_ids" | xargs)"
      echo "terminal_ttys=$(echo "$term_ttys" | xargs)"
      echo "iterm_session_ids=$(echo "$sess_ids" | xargs)"
      echo "tmux_sessions=${tmuxNames[*]}"
      echo "session_count=$sessionCount"
      echo "mirror_window_id=$mirror_win"
      echo "mirror_session_ids=$(echo "$mirror_sess" | xargs)"
    } > "$sfile"
    ln -sf "$sfile" "$STATE_DIR/last.session"

    echo "$name: launched in $folder (session $sid, $sessionCount sessions, $layout layout)"
    echo "  close it later with:  $name-close"
  else
    echo "$name: launched in $folder ($sessionCount sessions, $layout layout)"
  fi
}
