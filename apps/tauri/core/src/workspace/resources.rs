//! What a working session costs this computer right now (`ResourceUsage`, `ResourceMeter` on the Mac): the CPU and
//! memory of the agent's process and everything it started (a build, a test run, a dev server). Read while the session
//! works and is on screen; nothing is kept.

use std::collections::{HashMap, HashSet};

use serde::Serialize;
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceUsage {
    /// Percent of one core, so a build on four cores reads 400 %.
    pub cpu_percent: f64,
    /// Physical memory, in bytes.
    pub memory_bytes: u64,
    pub processes: usize,
}

/// `root` and every process below it, from `(pid, parent)` pairs.
pub fn tree(root: u32, parents: &[(u32, Option<u32>)]) -> Vec<u32> {
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for &(pid, parent) in parents {
        if let Some(p) = parent {
            children.entry(p).or_default().push(pid);
        }
    }
    let mut out = vec![];
    let mut seen = HashSet::new();
    let mut stack = vec![root];
    while let Some(pid) = stack.pop() {
        if !seen.insert(pid) {
            continue;
        }
        out.push(pid);
        if let Some(c) = children.get(&pid) {
            stack.extend(c);
        }
    }
    out
}

/// Keeps the process table between readings: CPU use is the time between two of them.
pub struct Meter {
    system: Option<System>,
    measured: bool,
}

impl Default for Meter {
    fn default() -> Self {
        Self { system: System::new().ok(), measured: false }
    }
}

impl Meter {
    /// The tree under `roots` now; `None` on the first reading (no CPU time to compare yet) or when none of them runs.
    pub fn measure(&mut self, roots: &[u32]) -> Option<ResourceUsage> {
        let system = self.system.as_mut()?;
        system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_cpu().with_memory());
        let first = !self.measured;
        self.measured = true;
        let parents: Vec<(u32, Option<u32>)> =
            system.processes().iter().map(|(pid, p)| (pid.as_u32(), p.parent().map(|p| p.as_u32()))).collect();
        let mut pids: Vec<u32> = roots.iter().flat_map(|r| tree(*r, &parents)).collect();
        pids.sort_unstable();
        pids.dedup();
        let live: Vec<_> = pids.iter().filter_map(|p| system.process(Pid::from_u32(*p))).collect();
        if live.is_empty() || first {
            return None;
        }
        Some(ResourceUsage {
            cpu_percent: live.iter().map(|p| p.cpu_usage() as f64).sum(),
            memory_bytes: live.iter().map(|p| p.memory()).sum(),
            processes: live.len(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn takes_the_whole_tree_once() {
        let table = [(1, None), (10, Some(1)), (11, Some(10)), (12, Some(10)), (20, Some(1)), (13, Some(11))];
        let mut t = tree(10, &table);
        t.sort();
        assert_eq!(t, vec![10, 11, 12, 13]);
        assert_eq!(tree(99, &table), vec![99]);
    }
}
