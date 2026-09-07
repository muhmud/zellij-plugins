#!/usr/bin/env bash
# Focus a pane by id. Run by the switch daemon:
#   focus-pane.sh <session> <pane_id>
set -eu -o pipefail
ZELLIJ=0 ZELLIJ_SESSION_NAME="$1" zellij action focus-pane-id "$2"
