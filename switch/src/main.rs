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

const DEFAULT_SET_SCRIPT: &str = "~/.switch/zellij/set.sh";

#[derive(Default)]
struct State {
    set_script: String,
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
        run_command(
            &[
                &self.set_script,
                &session,
                &tab_id.to_string(),
                &format!("terminal_{pane_id}"),
            ],
            BTreeMap::new(),
        );
        eprintln!("switch-zellij: set session={session} tab={tab_id} pane=terminal_{pane_id}");
    }
}

impl ZellijPlugin for State {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        self.set_script = configuration
            .get("set_script")
            .cloned()
            .unwrap_or_else(|| DEFAULT_SET_SCRIPT.to_string());
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::RunCommands,
        ]);
        subscribe(&[
            EventType::SessionUpdate,
            EventType::TabUpdate,
            EventType::PaneUpdate,
        ]);
        eprintln!("switch-zellij: loaded, set_script={}", self.set_script);
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

    fn render(&mut self, _rows: usize, _cols: usize) {}
}
