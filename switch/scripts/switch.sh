#!/usr/bin/env bash
# Move to the next tab in MRU order. Bind to the tab modifier's key.
# Pass --reverse to walk back.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "$SCRIPT_DIR/switch-zellij.sh"

TAB_ID="$(switch --request switch --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP" "$@" || true)"
if [[ -n "$TAB_ID" ]]; then
  zj go-to-tab-by-id "$TAB_ID"
fi
