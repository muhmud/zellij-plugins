#!/usr/bin/env bash
# Record the focused tab and pane with the `switch` daemon.
#
# Invoked by the plugin on every focus change:  set.sh <session> <tab_id> <pane_id>
# This is the zellij counterpart of the tmux `pane-focus-in` hook.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="$1"
TAB_ID="$2"
PANE_ID="$3"
source "$SCRIPT_DIR/switch-zellij.sh"

[[ -f "$SWITCH_SESSION_LIST_FILE" ]] || touch "$SWITCH_SESSION_LIST_FILE"
[[ -f "$SWITCH_TAB_LIST_FILE" ]] || touch "$SWITCH_TAB_LIST_FILE"
SWITCH_TAB_PANE_LIST_FILE="$SWITCH_TAB_LIST_FILE.$TAB_ID.panes"

# First sighting of this session: bring up its daemon and register the tab app.
if [[ "$(list_file_contains "$SWITCH_SESSION_ID" "$SWITCH_SESSION_LIST_FILE")" == "0" ]]; then
  switch --server --daemonize --socket-file "$SWITCH_SOCKET_FILE" \
    --use-libinput --device "${NIXOS_MACHINE_KEYBOARD}"
  # `switch` exits non-zero for every request other than switch/get-top, even
  # when it succeeds, so these cannot be allowed to trip `set -e`.
  switch --request add-app --socket-file "$SWITCH_SOCKET_FILE" \
    --app "$SWITCH_APP" --mod "$SWITCH_MOD_KEY" || true
  add_to_list_file "$SWITCH_SESSION_ID" "$SWITCH_SESSION_LIST_FILE"
fi

switch --request set --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP" --id "$TAB_ID" || true
add_to_list_file "$TAB_ID" "$SWITCH_TAB_LIST_FILE"

# First sighting of this tab: register a per-tab app for its panes.
if [[ ! -f "$SWITCH_TAB_PANE_LIST_FILE" ]]; then
  switch --request add-app --socket-file "$SWITCH_SOCKET_FILE" \
    --app "$SWITCH_APP-$TAB_ID" --mod "$SWITCH_PANE_MOD_KEY" || true
  touch "$SWITCH_TAB_PANE_LIST_FILE"
fi

# Drop panes that have since closed.
align_list_file "$SWITCH_TAB_PANE_LIST_FILE" "$(get_pane_list "$TAB_ID")" |
  while IFS= read -r id; do
    switch --request delete --socket-file "$SWITCH_SOCKET_FILE" \
      --app "$SWITCH_APP-$TAB_ID" --id "$id" || true
  done

# ...and tabs that have closed, along with their per-tab app.
align_list_file "$SWITCH_TAB_LIST_FILE" "$(get_tab_list)" |
  while IFS= read -r id; do
    switch --request delete --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP" --id "$id" || true
    switch --request delete-app --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP-$id" || true
    rm -f "$SWITCH_TAB_LIST_FILE.$id.panes"
  done

switch --request set --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP-$TAB_ID" --id "$PANE_ID" || true
add_to_list_file "$PANE_ID" "$SWITCH_TAB_PANE_LIST_FILE"
