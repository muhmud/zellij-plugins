# switch-zellij

Zellij integration for [`switch`](https://github.com/muhmud/switch): MRU
"alt-tab" across tabs and panes, mirroring the tmux integration in
`~/.switch/tmux`.

## Why a plugin

tmux drives `switch` from hooks — `pane-focus-in` fires `set.sh`, which pushes
the focused window/pane into the daemon. Zellij has **no hooks** (its only one,
`post_command_discovery_hook`, is unrelated), so a plugin stands in for them:
it subscribes to the focus events and shells out to the same kind of script.

Structure maps as: a zellij **tab** plays the part of a tmux **window**, so the
per-session app holds tab ids and a per-tab app holds pane ids.

| tmux | zellij |
|---|---|
| `pane-focus-in` hook | plugin, `TabUpdate` + `PaneUpdate` |
| `window-unlinked` / `session-closed` hooks | reconciliation inside `set.sh` |
| `tmux select-window -t <id>` | `zellij action go-to-tab-by-id <id>` |
| `tmux select-pane -t <id>` | `zellij action focus-pane-id terminal_<n>` |

Ids: `TabInfo.tab_id` is stable, unlike `position`, which shifts when tabs are
moved or closed — so the MRU records `tab_id`. Pane ids are per-kind, hence the
`terminal_<n>` form.

## Build

```sh
cargo build --release --target wasm32-wasip1
```

Output: `target/wasm32-wasip1/release/switch-zellij.wasm`.

`zellij-tile` is pinned to the 0.44 line to match zellij 0.44.3 — a plugin
built against a different API than the host will not load.

> `.cargo/config.toml` routes host links through `build/host-cc`, working
> around a broken rustup toolchain on this machine (its bundled `ld.lld` is a
> nix wrapper pointing at a garbage-collected store path). Reinstalling the
> stable toolchain, or building in a nix devshell, makes that unnecessary.

## Install

```kdl
// config.kdl
plugins {
    switch-zellij location="file:~/.config/zellij/plugins/switch-zellij.wasm" {
        set_script "~/.switch/zellij/set.sh"
    }
}
load_plugins {
    switch-zellij      // background: no pane of its own
}
```

It needs `ReadApplicationState` (focus events) and `RunCommands` (to invoke
the script). Pre-seed them in `~/.cache/zellij/permissions.kdl` to avoid the
permission prompt, which renders awkwardly in a bar-sized pane:

```
"/home/<you>/.config/zellij/plugins/switch-zellij.wasm" {
    ReadApplicationState
    RunCommands
}
```

## Status

Verified working:

- plugin loads in ~8ms against zellij 0.44.3
- `SessionUpdate` yields the session name; `TabUpdate`/`PaneUpdate` yield the
  active tab and its focused pane
- `run_command` reaches the configured script with
  `<session> <tab_id> terminal_<n>`
- shell helpers read live state correctly (`get_tab_list`, `get_pane_list`,
  `get_session_list`)

Not yet solved — **the trigger**. Zellij keybindings can only `Run` a command,
and every `Run` creates a visible pane, so binding `switch.sh` to a key
reintroduces a brief flash (~18ms even when the script re-execs detached and
exits immediately). Options:

1. Accept the flash.
2. Teach `switch`'s server to execute a command itself when the modifier
   chord fires. It already reads the keyboard via libinput, so it needs no
   help from the multiplexer — and this would let tmux drop its own
   `run-shell` bindings too. This is the clean fix, and `switch` is ours to
   change.

## Layout

- `src/main.rs` — the plugin: focus events → script invocation
- `scripts/switch-zellij.sh` — shared helpers (counterpart of `switch-tmux.sh`)
- `scripts/set.sh` — record focus; daemon startup, app registration, cleanup
- `scripts/switch.sh` — next/previous tab in MRU order
- `scripts/pane-switch.sh` — next/previous pane within the active tab
