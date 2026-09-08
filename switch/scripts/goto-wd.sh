#!/usr/bin/env bash
# Locate the unfiltered wd work screen — the one listing all features — wherever
# it is, and print where to go:
#
#   goto-wd.sh <session> <client_id>   ->  "<session> <tab_position> terminal_<pane>"
#
# The plugin does the focusing, so this only has to look. The tmux binding finds
# the screen by its @wd_screen "main" tag; zellij exposes no per-tab metadata, so
# it is identified by what runs in the pane instead.
#
# The command comes from terminal_command, falling back to the pane title: a pane
# launched by a wd session layout has the former, while a screen started by hand
# in a shell is a plain shell pane, where zellij tracks the running command as
# the title.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
CLIENT_ID="${2:-}"
source "$SCRIPT_DIR/switch-zellij.sh"

# A stale plugin instance from a past client must not hijack the keypress.
require_live_client "$CLIENT_ID" || exit 0

function screen_in() {  # session -> "<0-based tab position> terminal_<pane id>"
  timeout 5 env ZELLIJ=0 ZELLIJ_SESSION_NAME="$1" zellij action list-panes --all --json 2>/dev/null | jq -r '
    [ .[]
      | select(.is_plugin == false and .exited == false)
      | ((.terminal_command // .title) // "") as $cmd
      | select($cmd != "")
      | ($cmd | split(" ")) as $argv
      | select(($argv[0] | split("/") | last) == "wd")
      | select($argv | index("screen"))
      # The unfiltered screen: neither feature- nor CI-scoped.
      | select(($argv | index("--feature")) == null and ($argv | index("--ci")) == null)
    ]
    | first
    | if . == null then empty else "\(.tab_position) terminal_\(.id)" end'
}

# This session first: the screen being right here costs no session switch.
sessions=("$SWITCH_SESSION_ID")
while IFS= read -r s; do
  [[ -n "$s" && "$s" != "$SWITCH_SESSION_ID" ]] && sessions+=("$s")
done < <(zellij list-sessions -n 2>/dev/null | grep -v '(EXITED' | awk '{print $1}')

for session in "${sessions[@]}"; do
  target="$(screen_in "$session" || true)"
  if [[ -n "$target" ]]; then
    echo "$session $target"
    exit 0
  fi
done
