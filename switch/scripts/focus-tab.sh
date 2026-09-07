#!/usr/bin/env bash
# Focus a tab by its stable id. Run by the switch daemon:
#   focus-tab.sh <session> <tab_id>
set -eu -o pipefail
ZELLIJ=0 ZELLIJ_SESSION_NAME="$1" zellij action go-to-tab-by-id "$2"
