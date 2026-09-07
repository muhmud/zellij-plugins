#!/usr/bin/env bash
# Resolve the next tab in MRU order and print its id.
#   switch.sh <session> <client_id> [--reverse]
#
# The plugin does the focusing itself from this output: a `zellij action` call
# to change tab costs ~75ms, and this script is on the keypress path.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# An empty first argument means the plugin did not know the session yet;
# the zellij server's own environment carries it.
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
CLIENT_ID="${2:-}"
shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0
claim_switch tab || exit 0

id="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP" "$@" || true)"
trace "switch tab -> '${id:-<none>}' (mru: $(tr '\n' ',' < "$SWITCH_TAB_LIST_FILE" 2>/dev/null))"
printf '%s\n' "$id"
