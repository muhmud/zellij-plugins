//! Zellij integration for `switch`: keeps the daemon's MRU lists up to date.
//!
//! The tmux integration does this with `pane-focus-in` hooks calling set.sh.
//! Zellij has no hooks, so this plugin stands in for them: it subscribes to the
//! focus events and shells out to the same kind of script, which owns all the
//! `switch` plumbing (daemon startup, app registration, list reconciliation).
//!
//! Mapping onto the tmux structure: a zellij *tab* plays the part of a tmux
//! window, so the per-session app holds tab ids and a per-tab app holds pane
//! ids.
//!
//! Configuration (KDL, in the plugin block):
//!   scripts_dir "/path/to/scripts"   default: ~/.switch/zellij
//!
//! Focus is reported as: set.sh <session> <tab_id> <pane_id> <client_id>
//!
//! Keybindings reach the plugin with `MessagePlugin`, piping name "switch" and
//! a payload: `tab`/`tab-reverse` and `pane`/`pane-reverse` for MRU switching,
//! `wd` to jump to the wd work screen wherever it lives.

use std::collections::{BTreeMap, BTreeSet};
use zellij_tile::prelude::*;

const DEFAULT_SCRIPTS_DIR: &str = "~/.switch/zellij";

/// Pipe name a keybinding must use to reach this plugin. `MessagePlugin`
/// delivers without creating a pane, and only fires while zellij has focus —
/// which is what keeps the chord from also switching tabs while you are in
/// another application.
const PIPE_NAME: &str = "switch";

/// Marks a command result as ours, and says which stack it came from.
const CONTEXT_KEY: &str = "switch_scope";
const SCOPE_TAB: &str = "tab";
const SCOPE_PANE: &str = "pane";
const SCOPE_GOTO: &str = "goto";

#[derive(Default)]
struct State {
    tag: String,
    /// The client this instance belongs to. A `load_plugins` plugin is
    /// instantiated once per client and the instances outlive their client, so
    /// every past attach leaves one behind that still answers keybind pipes.
    /// Passing the id lets the scripts ignore all but the live client's.
    client_id: u16,
    scripts_dir: String,
    /// Name of the session we are running in, from SessionUpdate.
    session: Option<String>,
    /// Position of the active tab, from TabUpdate.
    active_tab: Option<usize>,
    /// Tabs already registered with the daemon, so each is seeded once.
    known_tabs: BTreeSet<usize>,
    /// Work that arrived before the session name was known. Events do not come
    /// in a guaranteed order, and each instance has its own state, so anything
    /// needing the session is held until SessionUpdate rather than dropped.
    pending_seed: BTreeSet<usize>,
    pending_switch: Option<String>,
    /// tab_id -> current position. The MRU records stable ids, but focusing a
    /// tab takes a position, and positions shift as tabs move or close.
    tab_positions: BTreeMap<usize, u32>,
    /// Stable id of the active tab, which is what `switch` should record —
    /// positions shift when tabs are moved or closed.
    active_tab_id: Option<usize>,
    /// Last (tab, pane) we reported, so repeated events are not re-sent.
    last: Option<(usize, u32)>,
}

register_plugin!(State);

/// Expand a leading `~`. The script is run with `run_command`, which execs
/// directly rather than through a shell, so nothing else would expand it.
fn expand_home(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => match std::env::var("HOME") {
            Ok(home) => format!("{home}/{rest}"),
            Err(_) => path.to_string(),
        },
        None => path.to_string(),
    }
}

impl State {
    /// Tell the daemon about the currently focused tab and pane.
    fn record(&mut self, tab_id: usize, pane_id: u32) {
        if self.last == Some((tab_id, pane_id)) {
            return;
        }
        let session = self.session.clone().unwrap_or_default();
        self.last = Some((tab_id, pane_id));
        let set_script = format!("{}/set.sh", self.scripts_dir);
        run_command(
            &[
                &set_script,
                &session,
                &tab_id.to_string(),
                &format!("terminal_{pane_id}"),
                &self.client_id.to_string(),
            ],
            BTreeMap::new(),
        );
        eprintln!("switch-zellij: set session={session} tab={tab_id} pane=terminal_{pane_id}");
    }
}

impl State {
    /// Ask the daemon for the next id in the requested stack. The focusing
    /// happens later, when the command result comes back.
    fn dispatch_switch(&mut self, session: &str, payload: &str) {
        let (script, scope, reverse) = match payload {
            "tab" => ("switch.sh", SCOPE_TAB, false),
            "tab-reverse" => ("switch.sh", SCOPE_TAB, true),
            "pane" => ("pane-switch.sh", SCOPE_PANE, false),
            "pane-reverse" => ("pane-switch.sh", SCOPE_PANE, true),
            // Not an MRU switch: jump to a specific window wherever it lives.
            // `SwitchSession` cannot do this, being a no-op when already in the
            // named session, and tab focus by name is not bindable — so it goes
            // through here, where both cases can be handled.
            "wd" => ("goto-wd.sh", SCOPE_GOTO, false),
            other => {
                eprintln!("switch-zellij: unknown pipe payload {other:?}");
                return;
            }
        };
        let path = format!("{}/{}", self.scripts_dir, script);
        let client = self.client_id.to_string();
        // The pane script needs the tab whose stack to walk; the plugin already
        // knows it, which saves the script a `zellij action` round trip.
        let active_tab_id = self.active_tab_id.unwrap_or_default().to_string();
        let mut args: Vec<&str> = vec![&path, session, &client];
        if scope == SCOPE_PANE {
            args.push(&active_tab_id);
        }
        if reverse {
            args.push("--reverse");
        }
        // The script resolves an id and prints it; the focusing is done here,
        // from the result, so no `zellij action` process is needed for it.
        let mut context = BTreeMap::new();
        context.insert(CONTEXT_KEY.to_string(), scope.to_string());
        eprintln!(
            "switch-zellij: asking for {payload} in {session} tag={}",
            self.tag
        );
        run_command(&args, context);
    }

    /// Run whatever was waiting on the session name.
    fn flush_pending(&mut self) {
        let session = self.session.clone().unwrap_or_default();
        if !self.pending_seed.is_empty() {
            let fresh: Vec<String> = self.pending_seed.iter().map(usize::to_string).collect();
            for id in self.pending_seed.iter() {
                self.known_tabs.insert(*id);
            }
            self.pending_seed.clear();
            let script = format!("{}/add-tabs.sh", self.scripts_dir);
            let client = self.client_id.to_string();
            let mut args: Vec<&str> = vec![&script, &session, &client];
            args.extend(fresh.iter().map(String::as_str));
            eprintln!("switch-zellij: seeding tabs {fresh:?}");
            run_command(&args, BTreeMap::new());
        }
        if let Some(payload) = self.pending_switch.take() {
            eprintln!("switch-zellij: replaying queued {payload}");
            self.dispatch_switch(&session, &payload);
        }
    }
}

impl ZellijPlugin for State {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        self.scripts_dir = expand_home(
            configuration
                .get("scripts_dir")
                .map(String::as_str)
                .unwrap_or(DEFAULT_SCRIPTS_DIR),
        );
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::RunCommands,
            // Focusing a tab or pane is a state change; the plugin does that
            // itself now rather than shelling out to `zellij action`.
            PermissionType::ChangeApplicationState,
        ]);
        subscribe(&[
            EventType::SessionUpdate,
            EventType::TabUpdate,
            EventType::PaneUpdate,
            EventType::RunCommandResult,
        ]);
        let ids = get_plugin_ids();
        self.client_id = ids.client_id;
        self.tag = format!("p{}c{}", ids.plugin_id, ids.client_id);
        eprintln!(
            "switch-zellij: loaded, scripts_dir={} tag={} session={:?}",
            self.scripts_dir, self.tag, self.session
        );
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::SessionUpdate(sessions, _) => {
                if let Some(current) = sessions.iter().find(|s| s.is_current_session) {
                    if self.session.as_deref() != Some(current.name.as_str()) {
                        eprintln!("switch-zellij: session={}", current.name);
                        self.session = Some(current.name.clone());
                        self.flush_pending();
                    }
                }
            }
            Event::TabUpdate(tabs) => {
                self.tab_positions = tabs
                    .iter()
                    .map(|t| (t.tab_id, t.position as u32))
                    .collect();
                // Seed tabs the daemon has not seen. A tab created during a
                // layout burst may never be reported as focused, and would
                // otherwise be missing from the stack and unreachable.
                let fresh: Vec<usize> = tabs
                    .iter()
                    .filter(|t| !self.known_tabs.contains(&t.tab_id))
                    .map(|t| t.tab_id)
                    .collect();
                if !fresh.is_empty() {
                    self.pending_seed.extend(fresh);
                    self.flush_pending();
                }
                if let Some(active) = tabs.iter().find(|t| t.active) {
                    // position indexes into PaneManifest; tab_id is the stable
                    // handle that survives tabs being moved or closed, so that
                    // is what the MRU records and what go-to-tab-by-id takes.
                    self.active_tab = Some(active.position);
                    self.active_tab_id = Some(active.tab_id);
                }
            }
            Event::PaneUpdate(manifest) => {
                let (Some(tab), Some(tab_id)) = (self.active_tab, self.active_tab_id) else {
                    return false;
                };
                if let Some(panes) = manifest.panes.get(&tab) {
                    // The focused, ordinary pane of the active tab. Plugin and
                    // suppressed panes are not switch targets.
                    if let Some(p) = panes
                        .iter()
                        .find(|p| p.is_focused && !p.is_plugin && !p.is_suppressed)
                    {
                        self.record(tab_id, p.id);
                    }
                }
            }
            Event::RunCommandResult(exit, stdout, _stderr, context) => {
                let Some(scope) = context.get(CONTEXT_KEY) else {
                    return false; // not one of ours (set.sh reports nothing)
                };
                if exit.unwrap_or(-1) != 0 {
                    return false;
                }
                let id = String::from_utf8_lossy(&stdout).trim().to_string();
                if id.is_empty() {
                    return false; // nothing to switch to
                }
                match scope.as_str() {
                    SCOPE_TAB => match id.parse::<usize>().ok().and_then(|tab_id| {
                        self.tab_positions.get(&tab_id).copied()
                    }) {
                        // Positions are 0-based here; the CLI's go-to-tab is not.
                        Some(position) => {
                            eprintln!("switch-zellij: focusing tab id={id} position={position}");
                            switch_tab_to(position + 1);
                        }
                        None => eprintln!("switch-zellij: no position known for tab id={id}"),
                    },
                    // "<session> <tab position> terminal_<pane>": a place to go,
                    // possibly in another session.
                    SCOPE_GOTO => {
                        let mut parts = id.split_whitespace();
                        let target = parts.next().map(str::to_string);
                        let position: Option<usize> = parts.next().and_then(|p| p.parse().ok());
                        let pane: Option<u32> = parts
                            .next()
                            .and_then(|p| p.strip_prefix("terminal_"))
                            .and_then(|n| n.parse().ok());
                        match (target, position, pane) {
                            (Some(target), Some(position), Some(pane)) => {
                                if Some(target.as_str()) == self.session.as_deref() {
                                    eprintln!(
                                        "switch-zellij: goto here tab position={position} pane={pane}"
                                    );
                                    // Positions are 0-based here; switch_tab_to is not.
                                    switch_tab_to(position as u32 + 1);
                                    focus_pane_with_id(PaneId::Terminal(pane), false, false);
                                } else {
                                    eprintln!(
                                        "switch-zellij: goto session={target} tab position={position} pane={pane}"
                                    );
                                    switch_session_with_focus(
                                        &target,
                                        Some(position),
                                        Some((pane, false)),
                                    );
                                }
                            }
                            _ => eprintln!("switch-zellij: unparseable goto target {id:?}"),
                        }
                    }
                    SCOPE_PANE => match id.strip_prefix("terminal_").and_then(|n| n.parse().ok()) {
                        Some(pane) => {
                            eprintln!("switch-zellij: focusing pane {id}");
                            focus_pane_with_id(PaneId::Terminal(pane), false, false);
                        }
                        None => eprintln!("switch-zellij: unparseable pane id={id}"),
                    },
                    _ => {}
                }
            }
            _ => {}
        }
        false
    }

    /// A keybinding asking for a switch. Reached by `MessagePlugin`, which
    /// creates no pane — the reason this is not simply a `Run` binding.
    fn pipe(&mut self, message: PipeMessage) -> bool {
        if message.name != PIPE_NAME {
            return false;
        }
        // The session name may not be known yet: SessionUpdate is not
        // guaranteed to reach an instance that loads late, and an instance that
        // waits for it would drop every request forever. Passing an empty name
        // lets the script fall back to the server's own ZELLIJ_SESSION_NAME.
        let session = self.session.clone().unwrap_or_default();
        let payload = message.payload.unwrap_or_default();
        self.dispatch_switch(&session, payload.trim());
        false
    }

    fn render(&mut self, _rows: usize, _cols: usize) {}
}
