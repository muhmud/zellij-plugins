#!/usr/bin/env bash
# Locate the unfiltered wd work screen — the one listing all features — wherever
# it is, and print where to go:
#
#   goto-wd.sh <session> <client_id>   ->  "<session> <tab_position> terminal_<pane>"
#
# The plugin does the focusing, so this only has to look. It is also only a
# fallback: the plugin resolves this itself from the session state it already
# holds, and reaches for this script when that state does not cover the session
# the screen is in.
#
# The tmux binding finds the screen by its @wd_screen "main" option; zellij
# exposes no per-tab metadata, so it is identified by what runs in the pane. The
# command comes from terminal_command, falling back to the pane title: a pane
# launched by a wd session layout has the former, while a screen started by hand
# in a shell is a plain shell pane, where zellij tracks the running command as
# the title.
#
# Sessions are read from zellij's own session_info cache, which it rewrites about
# once a second. Asking the CLI instead costs a round trip per session — ~270ms
# each here, so a jump could take over a second with a handful of sessions open.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
CLIENT_ID="${2:-}"
source "$SCRIPT_DIR/switch-zellij.sh"

# A stale plugin instance from a past client must not hijack the keypress. The
# check is cached, so it usually costs nothing.
require_live_client "$CLIENT_ID" || exit 0

# Live sessions, from the one socket per session zellij keeps in its runtime
# directory. The session_info cache alone will not do: it keeps directories for
# sessions that have exited.
function live_sessions() {
  local base="${ZELLIJ_SOCKET_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/zellij}"
  local found=0 dir sock
  for dir in "$base"/*/; do   # one directory per protocol version
    [[ -d "$dir" ]] || continue
    for sock in "$dir"*; do
      [[ -e "$sock" ]] || continue
      echo "${sock##*/}"
      found=1
    done
  done
  if (( ! found )); then
    zellij list-sessions -n 2>/dev/null | grep -v '(EXITED' | awk '{print $1}'
  fi
}

# The wd screen in one session's cached metadata -> "<tab position> <pane id>"
function screen_in_metadata() {
  local -r file=$1
  awk '
    /^panes \{/ { inpanes = 1; next }
    !inpanes { next }
    /^    pane \{/ { split("", f); inpane = 1; next }
    inpane && /^    \}/ {
      inpane = 0
      if (f["is_plugin"] == "true" || f["exited"] == "true" || f["is_suppressed"] == "true") next
      cmd = (f["terminal_command"] != "") ? f["terminal_command"] : f["title"]
      n = split(cmd, argv, " ")
      if (n == 0) next
      bin = argv[1]; sub(/.*\//, "", bin)
      if (bin != "wd") next
      screen = 0; scoped = 0
      for (i = 2; i <= n; i++) {
        if (argv[i] == "screen") screen = 1
        # Neither feature- nor CI-scoped: those are the per-scope screens.
        if (argv[i] == "--feature" || argv[i] == "--ci") scoped = 1
      }
      if (screen && !scoped) { print f["tab_position"], f["id"]; exit }
      next
    }
    inpane {
      key = $1
      val = $0
      sub(/^[[:space:]]*[a-z_]+[[:space:]]*/, "", val)
      gsub(/^"|"$/, "", val)
      f[key] = val
    }
  ' "$file"
}

# Last resort, if the cache is not there: ask the session itself.
function screen_in_session() {
  timeout 5 env ZELLIJ=0 ZELLIJ_SESSION_NAME="$1" zellij action list-panes --all --json 2>/dev/null | jq -r '
    [ .[]
      | select(.is_plugin == false and .exited == false)
      | ((.terminal_command // .title) // "") as $cmd
      | select($cmd != "")
      | ($cmd | split(" ")) as $argv
      | select(($argv[0] | split("/") | last) == "wd")
      | select($argv | index("screen"))
      | select(($argv | index("--feature")) == null and ($argv | index("--ci")) == null)
    ]
    | first
    | if . == null then empty else "\(.tab_position) \(.id)" end'
}

function screen_in() {
  local -r session=$1
  local file
  for file in "$HOME"/.cache/zellij/*/session_info/"$session"/session-metadata.kdl; do
    if [[ -f "$file" ]]; then
      screen_in_metadata "$file"
      return 0
    fi
  done
  screen_in_session "$session"
}

# This session first: the screen being right here costs no session switch.
sessions=("$SWITCH_SESSION_ID")
while IFS= read -r s; do
  [[ -n "$s" && "$s" != "$SWITCH_SESSION_ID" ]] && sessions+=("$s")
done < <(live_sessions)

for session in "${sessions[@]}"; do
  target="$(screen_in "$session" || true)"
  if [[ -n "$target" ]]; then
    read -r position pane <<< "$target"
    echo "$session $position terminal_$pane"
    exit 0
  fi
done
