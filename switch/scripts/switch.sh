#!/usr/bin/env bash
# Move to the next tab in MRU order.
#   switch.sh <session> [--reverse]
# Run by the plugin when a keybinding pipes it a "tab" request.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="$1"
CLIENT_ID="${2:-}"
shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0

claim_switch tab || exit 0

TAB_ID="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP" "$@" || true)"
if [[ -n "$TAB_ID" ]]; then
  zj go-to-tab-by-id "$TAB_ID"
fi
