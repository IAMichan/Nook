//! Stopping a dev server (`DevServerOwnership` on the Mac, AG-134): a server Nook started itself, from one of its
//! terminals or through an agent it runs, stops with one tap; one you started in another terminal app stops after the app
//! asks first. Ownership is matched by process ancestry only, never by name, and right before the stop the same pid must
//! still listen on the port in the folder, so a pid the system gave to another program meanwhile is never hit. The Mac also follows the agents' process groups; Windows has none, so a server
//! whose parent shell already ended cannot be traced back and is left alone (the safe side).

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use serde::Serialize;

use super::terminal::DevServer;

/// A process: its parent and when it started (seconds since the epoch).
pub type Entry = (u32, u64);

/// The processes Nook started: its own, the shells of its terminals, and the agents' (with when each started, so a pid
/// reused later is not taken for them).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Roots {
    pub processes: HashMap<u32, u64>,
}

impl Roots {
    pub fn add(&mut self, pid: u32, since: u64) {
        if pid > 1 {
            self.processes.entry(pid).or_insert(since);
        }
    }
}

static AGENTS: Mutex<Vec<(u32, u64)>> = Mutex::new(Vec::new());

/// Remembers an agent process Nook started, so what it left running can still be traced to it after it ended.
pub fn note_agent(pid: u32) {
    let since = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let mut l = AGENTS.lock().unwrap_or_else(|e| e.into_inner());
    l.push((pid, since.saturating_sub(1)));
    if l.len() > 256 {
        l.remove(0);
    }
}

pub fn noted_agents() -> Vec<(u32, u64)> {
    AGENTS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// `pid` runs below one of the roots. `table` gives a process's parent and start time; a root only counts when the
/// process below it started after it did.
pub fn started_by_nook(pid: u32, roots: &Roots, table: &dyn Fn(u32) -> Option<Entry>) -> bool {
    if pid <= 1 {
        return false;
    }
    let mut current = pid;
    let mut seen = HashSet::new();
    while seen.insert(current) && seen.len() < 64 {
        let Some((parent, start)) = table(current) else { return false };
        if parent <= 1 {
            return false;
        }
        if let Some(since) = roots.processes.get(&parent) {
            if start >= *since {
                return true;
            }
        }
        current = parent;
    }
    false
}

/// `root` and everything below it, deepest first, from `(pid, parent)` pairs.
pub fn stop_order(root: u32, parents: &[(u32, u32)]) -> Vec<u32> {
    let mut order = super::resources::tree(root, &parents.iter().map(|&(p, pp)| (p, Some(pp))).collect::<Vec<_>>());
    order.reverse();
    order
}

/// A dev server as the Terminals page shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DevServerView {
    #[serde(flatten)]
    pub server: DevServer,
    /// Started by Nook: such a server stops at once, any other after a confirmation.
    pub started_by_nook: bool,
}

fn table_of(system: &sysinfo::System) -> impl Fn(u32) -> Option<Entry> + '_ {
    move |pid| {
        let p = system.process(sysinfo::Pid::from_u32(pid))?;
        Some((p.parent()?.as_u32(), p.start_time()))
    }
}

fn snapshot() -> Option<sysinfo::System> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate};
    let mut system = sysinfo::System::new().ok()?;
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
    Some(system)
}

fn full_roots(shells: &[u32], agents: &[u32]) -> Roots {
    let mut roots = Roots::default();
    roots.add(std::process::id(), 0);
    for &s in shells {
        roots.add(s, 0);
    }
    for &a in agents {
        roots.add(a, 0);
    }
    for (pid, since) in noted_agents() {
        roots.add(pid, since);
    }
    roots
}

/// Marks each server Nook started.
pub fn mark(servers: Vec<DevServer>, shells: &[u32], agents: &[u32]) -> Vec<DevServerView> {
    let system = snapshot();
    let roots = full_roots(shells, agents);
    servers
        .into_iter()
        .map(|server| {
            let ours = system.as_ref().is_some_and(|s| started_by_nook(server.pid, &roots, &table_of(s)));
            DevServerView { server, started_by_nook: ours }
        })
        .collect()
}

/// Stops a server with the processes it started, whether Nook started it or not (the page asks first for one it did not).
/// False when it no longer listens on `port` in `folder`, or is a process Nook itself needs (Nook, a terminal shell, an
/// agent).
pub fn stop(folder: &str, pid: u32, port: u16, shells: &[u32], agents: &[u32]) -> bool {
    // Checked again right now: the same process still listens on that port in this folder.
    if pid <= 1 || !super::terminal::scan_dev_servers(folder).iter().any(|s| s.pid == pid && s.port == port) {
        return false;
    }
    let Some(system) = snapshot() else { return false };
    let roots = full_roots(shells, agents);
    if roots.processes.contains_key(&pid) {
        return false;
    }
    let parents: Vec<(u32, u32)> =
        system.processes().iter().filter_map(|(p, proc_)| Some((p.as_u32(), proc_.parent()?.as_u32()))).collect();
    for target in stop_order(pid, &parents) {
        if roots.processes.contains_key(&target) {
            continue;
        }
        if let Some(p) = system.process(sysinfo::Pid::from_u32(target)) {
            if p.kill_with(sysinfo::Signal::Term).is_none() {
                p.kill();
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(rows: &'static [(u32, u32, u64)]) -> impl Fn(u32) -> Option<Entry> {
        move |pid| rows.iter().find(|r| r.0 == pid).map(|r| (r.1, r.2))
    }

    #[test]
    fn a_server_below_a_root_is_ours() {
        // 50 (shell) -> 60 (npm) -> 70 (node)
        let t = table(&[(70, 60, 110), (60, 50, 105), (50, 10, 100)]);
        let mut roots = Roots::default();
        roots.add(50, 0);
        assert!(started_by_nook(70, &roots, &t));
        assert!(!started_by_nook(70, &Roots::default(), &t));
        assert!(!started_by_nook(1, &roots, &t));
    }

    #[test]
    fn a_reused_pid_is_not_a_root() {
        let t = table(&[(70, 50, 90), (50, 10, 80)]);
        let mut roots = Roots::default();
        // The agent that had pid 50 started at 100; this process started before it, so 50 is another program now.
        roots.add(50, 100);
        assert!(!started_by_nook(70, &roots, &t));
    }

    #[test]
    fn a_broken_chain_or_a_loop_is_not_ours() {
        let t = table(&[(70, 60, 110)]);
        let mut roots = Roots::default();
        roots.add(50, 0);
        assert!(!started_by_nook(70, &roots, &t));
        let looped = table(&[(2, 3, 1), (3, 2, 1)]);
        assert!(!started_by_nook(2, &roots, &looped));
    }

    #[test]
    fn stops_the_deepest_first() {
        let order = stop_order(1000, &[(1001, 1000), (1002, 1001), (5, 1)]);
        assert_eq!(order.last(), Some(&1000));
        assert!(order.iter().position(|p| *p == 1002) < order.iter().position(|p| *p == 1001));
        assert!(!order.contains(&5));
    }

    #[test]
    fn noted_agents_are_kept() {
        note_agent(4242);
        assert!(noted_agents().iter().any(|a| a.0 == 4242));
    }
}
