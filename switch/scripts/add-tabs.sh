#!/usr/bin/env bash
# Register tabs with the daemon so they are switchable before ever being
# visited.
#   add-tabs.sh <session> <client_id> <tab_id> [tab_id...]
#
# Focus reports alone are not enough: a tab created during a layout burst may
# never be reported, leaving it absent from the stack and unreachable.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# An empty first argument means the plugin did not know the session yet;
# the zellij server's own environment carries it.
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
CLIENT_ID="${2:-}"
shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0
[[ -f "$SWITCH_TAB_LIST_FILE" ]] || touch "$SWITCH_TAB_LIST_FILE"

for tab in "$@"; do
  [[ -n "$tab" ]] || continue
  # `add` is idempotent for an id already in the stack.
  switch --request add --socket-file "$SWITCH_SOCKET_FILE" \
    --app "$SWITCH_APP" --id "$tab" >/dev/null 2>&1 || true
  add_to_list_file "$tab" "$SWITCH_TAB_LIST_FILE"
done
trace "seeded tabs: $*"
