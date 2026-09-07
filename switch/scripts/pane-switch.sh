#!/usr/bin/env bash
# Move to the next pane of the current tab in MRU order.
# Pass --reverse to walk back.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/switch-zellij.sh"

TAB_ID="$(zj list-tabs --json 2>/dev/null | jq -r '.[] | select(.active) | .tab_id')"
[[ -n "$TAB_ID" ]] || exit 0

PANE_ID="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" \
  --app "$SWITCH_APP-$TAB_ID" "$@" || true)"
if [[ -n "$PANE_ID" ]]; then
  zj focus-pane-id "$PANE_ID"
fi
