#!/usr/bin/env bash
# Move to the next pane of the active tab in MRU order.
#   pane-switch.sh <session> [--reverse]
# Run by the plugin when a keybinding pipes it a "pane" request.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="$1"
CLIENT_ID="${2:-}"
shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0

claim_switch pane || exit 0

TAB_ID="$(zj list-tabs --json 2>/dev/null | jq -r '.[] | select(.active) | .tab_id')"
[[ -n "$TAB_ID" ]] || exit 0

PANE_ID="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP-$TAB_ID" "$@" || true)"
if [[ -n "$PANE_ID" ]]; then
  zj focus-pane-id "$PANE_ID"
fi
