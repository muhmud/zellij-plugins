#!/usr/bin/env bash
# Resolve the next pane of a tab in MRU order and print its id.
#   pane-switch.sh <session> <client_id> <tab_id> [--reverse]
#
# The tab is supplied by the plugin, which already knows it — asking zellij
# would cost another round trip. The plugin focuses the pane from this output.
set -eu -o pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# An empty first argument means the plugin did not know the session yet;
# the zellij server's own environment carries it.
SWITCH_SESSION_ID="${1:-$ZELLIJ_SESSION_NAME}"
CLIENT_ID="${2:-}"
TAB_ID="${3:-}"
shift 3 2>/dev/null || shift 2 2>/dev/null || shift
source "$SCRIPT_DIR/switch-zellij.sh"

[[ -n "$TAB_ID" ]] || exit 0
require_live_client "$CLIENT_ID" || exit 0
claim_switch "pane-$TAB_ID" || exit 0

# Authoritative second opinion, used only when an id looks dead.
function verify_panes() { get_pane_list "$TAB_ID"; }

switch_to_live "$SWITCH_APP-$TAB_ID" "$(live_pane_ids "$TAB_ID")" verify_panes "$@"
