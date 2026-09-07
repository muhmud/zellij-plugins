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
# Bounded: these run from the plugin on every focus change, so a blocked
# `zellij action` — a session that has gone away, say — would otherwise leave a
# stuck process behind each time.
function zj() {
  timeout 5 env ZELLIJ=0 ZELLIJ_SESSION_NAME="$SWITCH_SESSION_ID" zellij action "$@"
}

# Collapse a repeated *identical* event inside a short window.
#
# A background plugin is re-loaded on every client attach, so one focus change
# is reported once per instance, and one keypress can arrive as more than one
# pipe delivery. Only exact repeats are dropped: a genuinely different event is
# always let through, so fast movement is never lost.
#
# Returns non-zero when this call should be skipped.
function claim_focus_window() {
  local -r value=$1
  local -r window_ms=$2
  local -r guard="/tmp/switch.$SWITCH_APP.claim.${value//\//_}"
  local now line last_ts last_value
  now=$(now_ms)
  if [[ -f "$guard" ]]; then
    line=$(<"$guard")
    last_ts=${line%% *}
    last_value=${line#* }
    if [[ "$last_value" == "$value" ]] && [[ -n "$last_ts" ]] && (( now - last_ts < window_ms )); then
      return 1
    fi
  fi
  printf '%s %s\n' "$now" "$value" > "$guard"
  return 0
}

# A switch request carries no distinguishing value, so repeats are collapsed on
# scope alone.
# Switch requests get a much wider window than focus reports. One keypress has
# been observed arriving as two pipe deliveries up to ~90ms apart — the scripts
# take tens of milliseconds, so the duplicate queues behind the first — and each
# delivery advances the stack, so the switch overshoots. Deliberate repeats
# while holding the modifier are slower than this.
function claim_switch() {
  claim_focus_window "switch-$1" 200
}

function claim_focus() {
  claim_focus_window "$1" 40
}

# A `load_plugins` plugin is instantiated once per client, and the instances
# outlive their client: every past attach leaves one that still answers keybind
# pipes and still reports focus. Only the live client's instance should act.
#
# The client list is cached briefly — this runs on the switching path, and
# `zellij action` costs a couple of hundred milliseconds.
function require_live_client() {
  local -r client=$1
  local -r cache="/tmp/switch.$SWITCH_APP.clients"
  local -r ttl_ms=30000
  local now line ts clients
  [[ -n "$client" ]] || return 0        # older plugin builds pass nothing
  now=$(now_ms)
  clients=""
  if [[ -f "$cache" ]]; then
    line=$(head -1 "$cache")
    ts=${line%% *}
    # The timestamp lives in the file: asking `stat` for sub-second mtime is not
    # portable, and a malformed value here would break the arithmetic below.
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < ttl_ms )); then
      clients=$(tail -n +2 "$cache")
    fi
  fi
  if [[ -z "$clients" ]]; then
    clients=$(zj list-clients 2>/dev/null | awk 'NR>1{print $1}')
    # If zellij cannot be asked, do not block: better a stray duplicate than a
    # dead keybinding.
    [[ -n "$clients" ]] || return 0
    { echo "$now"; echo "$clients"; } > "$cache"
  fi
  if grep -qx "$client" <<< "$clients"; then
    return 0
  fi
  # Not in the cached list. That is either a stale instance or a client that
  # attached since the list was taken, so confirm against zellij before
  # refusing — otherwise a fresh attach would have a dead keybinding until the
  # cache expired.
  clients=$(zj list-clients 2>/dev/null | awk 'NR>1{print $1}')
  [[ -n "$clients" ]] || return 0
  { echo "$now"; echo "$clients"; } > "$cache"
  grep -qx "$client" <<< "$clients"
}

# True at most once per window_ms, for work that need not happen every time.
function claim_interval() {
  local -r name=$1 window_ms=$2
  local -r guard="/tmp/switch.$SWITCH_APP.$name.interval"
  local now last
  now=$(now_ms)
  if [[ -f "$guard" ]]; then
    last=$(<"$guard")
    if [[ -n "$last" ]] && (( now - last < window_ms )); then
      return 1
    fi
  fi
  echo "$now" > "$guard"
  return 0
}

# Milliseconds without spawning `date`: this is on the switching path and a
# process spawn here costs about as much as the work being timed. The separator
# may be a comma under some locales.
function now_ms() {
  local micros=${EPOCHREALTIME/[.,]/}
  if [[ -n "$micros" ]]; then
    echo $(( micros / 1000 ))
  else
    date +%s%3N
  fi
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
