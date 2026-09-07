#!/usr/bin/env bash
# Record the focused tab and pane with the `switch` daemon.
#
# Invoked by the plugin on every focus change:  set.sh <session> <tab_id> <pane_id>
# This is the zellij counterpart of the tmux `pane-focus-in` hook.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# An empty first argument means the plugin did not know the session yet;
# the zellij server's own environment carries it.
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
TAB_ID="$2"
PANE_ID="$3"
CLIENT_ID="${4:-}"
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0

# Duplicate reports of the *same* focus are collapsed; a report of a different
# focus is always recorded, however fast it arrives. The plugin's values are
# taken at face value: they come from the focus event itself, so they are
# accurate at the moment they were produced — verifying them against a live
# query costs hundreds of milliseconds and records the wrong thing when focus
# has moved on in the meantime.
claim_focus "$TAB_ID/$PANE_ID" || exit 0


[[ -f "$SWITCH_SESSION_LIST_FILE" ]] || touch "$SWITCH_SESSION_LIST_FILE"
[[ -f "$SWITCH_TAB_LIST_FILE" ]] || touch "$SWITCH_TAB_LIST_FILE"
SWITCH_TAB_PANE_LIST_FILE="$SWITCH_TAB_LIST_FILE.$TAB_ID.panes"

# First sighting of this session: bring up its daemon and register the tab app.
if ! daemon_alive; then
  # Forget any previous registration: the daemon that held it is gone, and with
  # it the stack our history described.
  delete_from_list_file "$SWITCH_SESSION_ID" "$SWITCH_SESSION_LIST_FILE"
  reset_history
fi
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
record_history "$TAB_ID"

# First sighting of this tab: register a per-tab app for its panes.
if [[ ! -f "$SWITCH_TAB_PANE_LIST_FILE" ]]; then
  switch --request add-app --socket-file "$SWITCH_SOCKET_FILE" \
    --app "$SWITCH_APP-$TAB_ID" --mod "$SWITCH_PANE_MOD_KEY" || true
  touch "$SWITCH_TAB_PANE_LIST_FILE"
fi

# Reconciliation asks zellij what still exists, which costs a few hundred
# milliseconds — far too slow to run on every focus change, and the recording
# above is what has to be prompt. Closed tabs and panes are harmless to carry
# for a few seconds, so sweep at most every 5s.
if claim_interval reconcile 5000; then

reap_orphan_daemons

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

fi

switch --request set --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP-$TAB_ID" --id "$PANE_ID" || true
add_to_list_file "$PANE_ID" "$SWITCH_TAB_PANE_LIST_FILE"
