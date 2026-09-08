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

With nix, from the repo root:

```sh
nix build .#switch          # -> result/bin/switch-zellij.wasm
nix develop                 # a shell with rust + the wasm32-wasip1 target
```

Or with cargo directly:

```sh
cargo build --release --target wasm32-wasip1
```

Output: `target/wasm32-wasip1/release/switch-zellij.wasm`.

`zellij-tile` is pinned to the 0.44 line to match zellij 0.44.3 — a plugin
built against a different API than the host will not load.

> A cargo build needs a toolchain with the `wasm32-wasip1` target; `nix develop`
> provides one. If a local rustup toolchain has a broken bundled linker (its
> `ld.lld` being a nix wrapper pointing at a garbage-collected store path), host
> links can be routed around it with an untracked `.cargo/config.toml` setting
> `[target.<host>] linker` to a wrapper that drops `-fuse-ld=lld` and the
> `-B .../gcc-ld` argument — see `build/host-cc`. Both are gitignored, being
> specific to one machine.

## Install

```kdl
// config.kdl
plugins {
    // Any of: a nix store path from `nix build .#switch`, a copy under
    // ~/.config/zellij/plugins, or an https URL to a release asset.
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

## Triggers

Bindings reach the plugin through `MessagePlugin`, which delivers to a
background plugin without creating a pane — a bound *command* can only run in a
new pane, which flashes on screen every time. The binding must name the plugin
by its **alias**, not its URL:

```kdl
bind "Alt a"       { MessagePlugin "switch-zellij" { name "switch"; payload "tab" } }
bind "Alt Shift a" { MessagePlugin "switch-zellij" { name "switch"; payload "tab-reverse" } }
bind "Ctrl tab"    { MessagePlugin "switch-zellij" { name "switch"; payload "pane" } }
bind "Alt y"       { MessagePlugin "switch-zellij" { name "switch"; payload "wd" } }
```

| payload | effect |
|---|---|
| `tab` / `tab-reverse` | next/previous tab in MRU order |
| `pane` / `pane-reverse` | next/previous pane within the active tab |
| `wd` | jump to the unfiltered `wd` work screen, in whichever session holds it |

`wd` is not an MRU switch. It exists here because the native `SwitchSession`
is a **no-op when you are already in the named session**, and tab focus by name
is not bindable — so neither native action can express "go to that window,
wherever it is". The plugin can: same session focuses the tab, another session
uses `switch_session_with_focus`.

Only the libinput backend watches trigger keys, so the daemon must be started
with `--use-libinput`.

## Layout

- `src/main.rs` — the plugin: focus events → script invocation
- `scripts/switch-zellij.sh` — shared helpers (counterpart of `switch-tmux.sh`)
- `scripts/set.sh` — record focus; daemon startup, app registration, cleanup
- `scripts/switch.sh` — next/previous tab in MRU order
- `scripts/pane-switch.sh` — next/previous pane within the active tab
- `scripts/add-tabs.sh` — register tabs created in a burst, and replay the
  focus history so seeding cannot leave the MRU out of order
- `scripts/goto-wd.sh` — locate the unfiltered `wd` work screen
