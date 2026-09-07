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
//!   set_script "/path/to/set.sh"   default: ~/.switch/zellij/set.sh
//!
//! The script is invoked as: set.sh <session> <tab_id> <pane_id>

use std::collections::BTreeMap;
use zellij_tile::prelude::*;

const DEFAULT_SCRIPTS_DIR: &str = "~/.switch/zellij";

/// Pipe name a keybinding must use to reach this plugin. `MessagePlugin`
/// delivers without creating a pane, and only fires while zellij has focus —
/// which is what keeps the chord from also switching tabs while you are in
/// another application.
const PIPE_NAME: &str = "switch";

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
        let Some(session) = self.session.clone() else {
            return; // wait until we know which session we are in
        };
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
        ]);
        subscribe(&[
            EventType::SessionUpdate,
            EventType::TabUpdate,
            EventType::PaneUpdate,
        ]);
        let ids = get_plugin_ids();
        self.client_id = ids.client_id;
        self.tag = format!("p{}c{}", ids.plugin_id, ids.client_id);
        eprintln!(
            "switch-zellij: loaded, scripts_dir={} tag={}",
            self.scripts_dir, self.tag
        );
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::SessionUpdate(sessions, _) => {
                if let Some(current) = sessions.iter().find(|s| s.is_current_session) {
                    if self.session.as_deref() != Some(current.name.as_str()) {
                        eprintln!("switch-zellij: session={}", current.name);
                        self.session = Some(current.name.clone());
                    }
                }
            }
            Event::TabUpdate(tabs) => {
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
        let Some(session) = self.session.clone() else {
            eprintln!("switch-zellij: pipe before the session is known, ignoring");
            return false;
        };
        let source = format!("{:?}", message.source);
        let payload = message.payload.unwrap_or_default();
        let (script, reverse) = match payload.trim() {
            "tab" => ("switch.sh", false),
            "tab-reverse" => ("switch.sh", true),
            "pane" => ("pane-switch.sh", false),
            "pane-reverse" => ("pane-switch.sh", true),
            other => {
                eprintln!("switch-zellij: unknown pipe payload {other:?}");
                return false;
            }
        };
        let path = format!("{}/{}", self.scripts_dir, script);
        let client = self.client_id.to_string();
        let mut args: Vec<&str> = vec![&path, &session, &client];
        if reverse {
            args.push("--reverse");
        }
        eprintln!(
            "switch-zellij: switching {payload} for {session} tag={} source={source}",
            self.tag
        );
        run_command(&args, BTreeMap::new());
        false
    }

    fn render(&mut self, _rows: usize, _cols: usize) {}
}
