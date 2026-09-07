# Shared helpers, mirroring ~/.switch/tmux/switch-tmux.sh.
#
# The session name is passed in by the plugin (which learns it from
# SessionUpdate); when a trigger script runs inside a zellij pane, the
# environment supplies it instead.

SWITCH_SESSION_ID="${SWITCH_SESSION_ID:-${1:-$ZELLIJ_SESSION_NAME}}"
SWITCH_APP="zellij-$SWITCH_SESSION_ID"

export SWITCH_SESSION_LIST_FILE="/tmp/switch.zellij.sessions"
export SWITCH_TAB_LIST_FILE="/tmp/switch.$SWITCH_APP.tabs"
export SWITCH_TAB_HISTORY_FILE="/tmp/switch.$SWITCH_APP.history"
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

  # The whole read-compare-write has to be atomic: duplicate deliveries arrive
  # within the same millisecond, and a plain check-then-act lets both through
  # because neither has written yet when the other reads.
  exec 9>"$guard.lock"
  flock 9

  now=$(now_ms)
  if [[ -f "$guard" ]]; then
    line=$(<"$guard")
    last_ts=${line%% *}
    last_value=${line#* }
    if [[ "$last_value" == "$value" ]] && [[ -n "$last_ts" ]] && (( now - last_ts < window_ms )); then
      exec 9>&-
      return 1
    fi
  fi
  printf '%s %s\n' "$now" "$value" > "$guard"
  exec 9>&-
  return 0
}

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
  if grep -qx "$client" <<< "$clients"; then
    return 0
  fi
  return 1
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

# Shut down daemons whose zellij session is gone.
#
# zellij has no session-closed hook (the tmux client uses one), so a daemon
# would otherwise outlive its session — leaking a process per session, and
# worse, keeping that session name's old MRU so a new session of the same name
# inherits a stale stack.
function reap_orphan_daemons() {
  local live sock name
  live=$(zellij list-sessions -n 2>/dev/null | grep -v '(EXITED' | awk '{print $1}') || return 0
  [[ -n "$live" ]] || return 0          # cannot tell; leave everything alone
  for sock in /tmp/switch.zellij-*; do
    [[ -S "$sock" ]] || continue        # only the sockets, not the state files
    name=${sock#/tmp/switch.zellij-}
    if ! grep -qx "$name" <<< "$live"; then
      switch --request shutdown --socket-file "$sock" >/dev/null 2>&1 || true
      rm -f "$sock" "$sock".* 2>/dev/null || true
    fi
  done
}

# Is a daemon actually listening on this session's socket?
#
# The session-list file only records that we have seen the session before; it is
# not evidence the daemon still lives. One can be killed, or die with a crash,
# and without this check set.sh would never bring it back — leaving switching
# silently dead for the rest of the session.
function daemon_alive() {
  local p cmd
  for p in $(pgrep -x switch 2>/dev/null); do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$cmd" in *"--socket-file $SWITCH_SOCKET_FILE "*) return 0 ;; esac
  done
  return 1
}

# Our own record of which tabs were focused, most recent last.
#
# `switch --request add` puts an id on *top* of the stack, so registering a
# burst of new tabs leaves the last one added looking most-recently-used.
# Seeding is asynchronous, so it can land after focus has already moved on,
# burying the tab the user just came from — a switch would then jump to the last
# tab created rather than the previous one. The daemon's stack cannot be read
# back, so keeping the order here is what lets seeding restore it.
readonly SWITCH_HISTORY_DEPTH=20

function record_history() {
  local -r id=$1
  # Same reason as the list files: several plugin instances report the same
  # change, so appending has to be atomic.
  exec 9>"$SWITCH_TAB_HISTORY_FILE.lock"
  flock 9
  echo "$id" >> "$SWITCH_TAB_HISTORY_FILE"
  if [[ "$(wc -l < "$SWITCH_TAB_HISTORY_FILE")" -gt $((SWITCH_HISTORY_DEPTH * 2)) ]]; then
    tail -n "$SWITCH_HISTORY_DEPTH" "$SWITCH_TAB_HISTORY_FILE" > "$SWITCH_TAB_HISTORY_FILE.trim" &&
      mv "$SWITCH_TAB_HISTORY_FILE.trim" "$SWITCH_TAB_HISTORY_FILE"
  fi
  exec 9>&-
}

function reset_history() {
  : > "$SWITCH_TAB_HISTORY_FILE" 2>/dev/null || true
}

# The distinct tabs from the history, oldest first, each at the position of its
# most recent focus.
function history_order() {
  [[ -s "$SWITCH_TAB_HISTORY_FILE" ]] || return 0
  tac "$SWITCH_TAB_HISTORY_FILE" | awk 'NF && !seen[$0]++' | tac
}

function list_file_contains() {
  grep -c "^$1\$" "$2"
}

function add_to_list_file() {
  local -r id=$1 list_file=$2
  # Several plugin instances report the same change, so the check-and-append has
  # to be atomic or the id lands twice (seen as a doubled entry in the list).
  exec 8>"$list_file.lock"
  flock 8
  if [[ ! -f "$list_file" ]] || [[ "$(list_file_contains "$id" "$list_file")" == "0" ]]; then
    echo "$id" >> "$list_file"
  fi
  exec 8>&-
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
  # An empty live list means the query failed, not that everything closed: a
  # session always has at least one tab, and a tab at least one pane. Treating
  # a failed query as "all gone" deletes the whole stack.
  if [[ -z "${new_list//[[:space:]]/}" ]]; then
    return 0
  fi
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
