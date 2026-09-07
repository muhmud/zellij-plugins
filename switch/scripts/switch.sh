#!/usr/bin/env bash
# Resolve the next tab in MRU order and print its id.
#   switch.sh <session> <client_id> [--reverse]
#
# The plugin does the focusing itself from this output: a `zellij action` call
# to change tab costs ~75ms, and this script is on the keypress path.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
SWITCH_SESSION_ID="$1"
CLIENT_ID="${2:-}"
shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

require_live_client "$CLIENT_ID" || exit 0
claim_switch tab || exit 0

switch --request switch --socket-file "$SWITCH_SOCKET_FILE" --app "$SWITCH_APP" "$@" || true
