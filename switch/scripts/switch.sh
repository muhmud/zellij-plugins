#!/usr/bin/env bash
# Move to the next tab in MRU order.
#   switch.sh <session> [--reverse]
# Run by the plugin when a keybinding pipes it a "tab" request.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="$1"
shift
source "$SCRIPT_DIR/switch-zellij.sh"

TAB_ID="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP" "$@" || true)"
if [[ -n "$TAB_ID" ]]; then
  zj go-to-tab-by-id "$TAB_ID"
fi
