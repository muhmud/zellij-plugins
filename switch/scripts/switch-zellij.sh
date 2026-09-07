# Shared helpers, mirroring ~/.switch/tmux/switch-tmux.sh.
#
# The session name is passed in by the plugin (which learns it from
# SessionUpdate); when a trigger script runs inside a zellij pane, the
# environment supplies it instead.

SWITCH_SESSION_ID="${SWITCH_SESSION_ID:-${1:-$ZELLIJ_SESSION_NAME}}"
SWITCH_APP="zellij-$SWITCH_SESSION_ID"

export SWITCH_SESSION_LIST_FILE="/tmp/switch.zellij.sessions"
export SWITCH_TAB_LIST_FILE="/tmp/switch.$SWITCH_APP.tabs"
export SWITCH_SOCKET_FILE="/tmp/switch.$SWITCH_APP"
export SWITCH_MOD_KEY=${SWITCH_MOD_KEY:-alt}
export SWITCH_PANE_MOD_KEY=${SWITCH_PANE_MOD_KEY:-ctrl}
# The trigger keys live in zellij's own keybindings, which pipe to the plugin
# (see the README): that way the chord only acts while zellij has focus, and no
# pane is created.

# Always address a specific session: a script invoked by the plugin has no
# ZELLIJ_SESSION_NAME of its own, and one invoked from a pane may be asked
# about a different session.
function zj() {
  ZELLIJ=0 ZELLIJ_SESSION_NAME="$SWITCH_SESSION_ID" zellij action "$@"
}

function list_file_contains() {
  grep -c "^$1\$" "$2"
}

function add_to_list_file() {
  local -r id=$1 list_file=$2
  if [[ ! -f "$list_file" ]] || [[ "$(list_file_contains "$id" "$list_file")" == "0" ]]; then
    echo "$id" >> "$list_file"
  fi
}

function delete_from_list_file() {
  local -r id=$1 list_file=$2
  if [[ -f "$list_file" ]]; then
    sed -i "/^${id}\$/d" "$list_file"
  fi
}

# Emit ids present in the list file but gone from the live list, removing them
# as it goes — the caller deletes them from `switch` too.
function align_list_file() {
  local -r list_file=$1 new_list=$2
  [[ -f "$list_file" ]] || return 0
  local ids=()
  while IFS= read -r id; do
    if [[ "$(grep -c "^$id\$" <<< "$new_list")" == "0" ]]; then
      ids+=("$id")
    fi
  done < "$list_file"
  for id in "${ids[@]}"; do
    echo "$id"
    delete_from_list_file "$id" "$list_file"
  done
}

function get_session_list() {
  zellij list-sessions -n 2>/dev/null | grep -v '(EXITED' | awk '{print $1}'
}

# Stable tab ids, not positions: positions shift when tabs are moved or closed.
function get_tab_list() {
  zj list-tabs --json 2>/dev/null | jq -r '.[].tab_id'
}

# Pane ids in `terminal_<n>` form, matching what focus-pane-id expects.
function get_pane_list() {
  local -r tab_id=$1
  zj list-panes --all --tab --json 2>/dev/null \
    | jq -r --argjson t "$tab_id" '.[]
        | select(.tab_id == $t and .is_plugin == false and .is_suppressed == false)
        | "terminal_\(.id)"'
}
