//! Keeps coding agents from overwhelming the computer (`AgentGovernorPolicy` + `AgentGovernor` on the Mac, AG-76).
//!
//! Agents themselves stay at normal priority so their stdio/RPC connections stay live. Under memory pressure or heat,
//! child commands they spawn (builds, test suites) are stepped down in priority (Windows Job Objects with
//! `JOB_OBJECT_LIMIT_PRIORITY_CLASS`, Linux `nice`, macOS `PRIO_DARWIN_BG`), and when memory is critical (or two heavy
//! builds compete under pressure), the youngest agent's child commands pause (`NtSuspendProcess` on Windows, `SIGSTOP`
//! to process groups on Unix) until room returns or `MAX_PAUSE_SECS` elapses. Paused processes are recorded to
//! `paused-groups.json` before pausing so a crash never leaves orphaned suspended processes behind.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};
use uuid::Uuid;

use super::manager::Manager;

/// How often the governor reads system pressure while agents are running.
pub const TICK_INTERVAL: Duration = Duration::from_secs(5);

/// Swap-in rate threshold (pages/sec) for tight memory, matching `EnergySignals.swapinsPerSecondTight`.
pub const SWAPINS_PER_SECOND_TIGHT: f64 = 256.0;
/// Swap-in rate threshold (pages/sec) for critical memory pressure.
pub const SWAPINS_PER_SECOND_CRITICAL: f64 = SWAPINS_PER_SECOND_TIGHT * 4.0;

/// Maximum time an agent's child commands may remain paused before forced resumption (seconds).
pub const MAX_PAUSE_SECS: i64 = 120;
/// Cooldown after a forced resume before the same agent may be paused again (seconds).
pub const PAUSE_COOLDOWN_SECS: i64 = 60;
/// How long the machine must stay out of `Critical` before paused work resumes, one agent per tick (seconds).
pub const RESUME_AFTER_CALM_SECS: i64 = 15;
/// Combined resident memory of an agent's child commands above which it counts as heavy work (1.5 GiB).
pub const HEAVY_WORK_BYTES: u64 = 1_536 * 1_024 * 1_024;

/// How hard the computer is pressed right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MachineStrain {
    Calm,
    Pressed,
    Critical,
}

/// What the governor does with one agent's child commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentThrottle {
    /// Normal priority.
    Normal,
    /// Lowered priority (Windows Job Object `BELOW_NORMAL_PRIORITY_CLASS`, Linux `nice`, macOS `PRIO_DARWIN_BG`).
    Background,
    /// Child commands paused until room returns (or `MAX_PAUSE_SECS` elapses, or the user clicks "Let them go on").
    Paused,
}

/// One running agent as the governor sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentLoad {
    pub pid: u32,
    pub started: DateTime<Utc>,
    /// True when the agent currently runs child commands of its own (a build, a test run).
    pub has_work: bool,
    /// True when its child commands hold at least `HEAVY_WORK_BYTES` resident memory.
    pub heavy: bool,
    /// True when the user told Nook to let this session go on.
    pub exempt: bool,
}

/// Current governor state for one agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentGovernorState {
    pub throttle: AgentThrottle,
    pub since: DateTime<Utc>,
    pub forced_resume_at: Option<DateTime<Utc>>,
}

impl AgentGovernorState {
    pub fn new(throttle: AgentThrottle, since: DateTime<Utc>) -> Self {
        Self { throttle, since, forced_resume_at: None }
    }
}

/// Pure decision functions mirroring `AgentGovernorPolicy.swift`.
pub struct Policy;

impl Policy {
    /// Memory-tight helper matching `EnergySignals.isMemoryTight`.
    pub fn is_memory_tight(pressure_level: i32, swapins_per_second: Option<f64>) -> bool {
        pressure_level >= 2 || swapins_per_second.unwrap_or(0.0) >= SWAPINS_PER_SECOND_TIGHT
    }

    /// How hard the machine is pressed from pressure level (1 normal, 2 warning, 4 critical), swap-ins/sec, and heat.
    pub fn strain(pressure_level: i32, swapins_per_second: Option<f64>, hot: bool) -> MachineStrain {
        if pressure_level >= 4 || swapins_per_second.unwrap_or(0.0) >= SWAPINS_PER_SECOND_CRITICAL {
            return MachineStrain::Critical;
        }
        if hot || Self::is_memory_tight(pressure_level, swapins_per_second) {
            return MachineStrain::Pressed;
        }
        MachineStrain::Calm
    }

    /// Cross-platform strain estimate from RAM & swap utilization (Windows / Linux via `sysinfo`).
    pub fn strain_from_memory(used_bytes: u64, total_bytes: u64, swap_used: u64, swap_total: u64, hot: bool) -> MachineStrain {
        if total_bytes == 0 {
            return if hot { MachineStrain::Pressed } else { MachineStrain::Calm };
        }
        let ram_ratio = used_bytes as f64 / total_bytes as f64;
        let swap_ratio = if swap_total > 0 { swap_used as f64 / swap_total as f64 } else { 0.0 };
        if ram_ratio >= 0.92 || (ram_ratio >= 0.85 && swap_ratio >= 0.25) {
            MachineStrain::Critical
        } else if hot || ram_ratio >= 0.82 || swap_ratio >= 0.40 {
            MachineStrain::Pressed
        } else {
            MachineStrain::Calm
        }
    }

    /// Computes the next throttle state for every running agent. At most one agent is paused and one resumed per tick.
    pub fn next(
        agents: &[AgentLoad],
        current: &HashMap<u32, AgentGovernorState>,
        strain: MachineStrain,
        calm_since: Option<DateTime<Utc>>,
        now: DateTime<Utc>,
    ) -> HashMap<u32, AgentGovernorState> {
        let mut result: HashMap<u32, AgentGovernorState> = HashMap::new();
        let band = if strain >= MachineStrain::Pressed { AgentThrottle::Background } else { AgentThrottle::Normal };
        let base = |agent: &AgentLoad| -> AgentThrottle {
            if agent.heavy && strain == MachineStrain::Pressed {
                AgentThrottle::Normal
            } else {
                band
            }
        };

        let mut by_age: Vec<&AgentLoad> = agents.iter().collect();
        by_age.sort_by_key(|a| (a.started, a.pid));

        let mut resumed_one = false;
        for &agent in &by_age {
            let Some(state) = current.get(&agent.pid) else { continue };
            if state.throttle != AgentThrottle::Paused {
                continue;
            }
            let too_long = (now - state.since).num_seconds() >= MAX_PAUSE_SECS;
            let others_heavy = by_age.iter().any(|other| {
                other.pid != agent.pid
                    && other.heavy
                    && other.has_work
                    && result.get(&other.pid).or_else(|| current.get(&other.pid)).map(|s| s.throttle) != Some(AgentThrottle::Paused)
            });
            let room_again = !others_heavy && calm_since.is_some_and(|c| (now - c).num_seconds() >= RESUME_AFTER_CALM_SECS);
            if agent.exempt || !agent.has_work || too_long || (room_again && !resumed_one) {
                if room_again && !too_long && !agent.exempt && agent.has_work {
                    resumed_one = true;
                }
                result.insert(
                    agent.pid,
                    AgentGovernorState {
                        throttle: base(agent),
                        since: now,
                        forced_resume_at: if too_long { Some(now) } else { state.forced_resume_at },
                    },
                );
            } else {
                result.insert(agent.pid, state.clone());
            }
        }

        for &agent in &by_age {
            if result.contains_key(&agent.pid) {
                continue;
            }
            let old = current.get(&agent.pid);
            let throttle = base(agent);
            let since = match old {
                Some(prev) if prev.throttle == throttle => prev.since,
                _ => now,
            };
            result.insert(agent.pid, AgentGovernorState { throttle, since, forced_resume_at: old.and_then(|o| o.forced_resume_at) });
        }

        let youngest_that_may_wait = |working: &[&AgentLoad], states: &HashMap<u32, AgentGovernorState>| -> Option<u32> {
            if working.len() < 2 {
                return None;
            }
            working[1..].iter().rev().find_map(|agent| {
                if agent.exempt {
                    return None;
                }
                if let Some(forced) = states.get(&agent.pid).and_then(|s| s.forced_resume_at) {
                    if (now - forced).num_seconds() < PAUSE_COOLDOWN_SECS {
                        return None;
                    }
                }
                Some(agent.pid)
            })
        };

        let working: Vec<&AgentLoad> = by_age
            .iter()
            .copied()
            .filter(|a| a.has_work && result.get(&a.pid).map(|s| s.throttle) != Some(AgentThrottle::Paused))
            .collect();

        let mut candidate: Option<u32> = None;
        if strain >= MachineStrain::Pressed {
            let heavy: Vec<&AgentLoad> = working.iter().copied().filter(|a| a.heavy).collect();
            candidate = youngest_that_may_wait(&heavy, &result);
        }
        if candidate.is_none() && strain == MachineStrain::Critical {
            candidate = youngest_that_may_wait(&working, &result);
        }
        if let Some(pid) = candidate {
            let forced_resume_at = result.get(&pid).and_then(|s| s.forced_resume_at);
            result.insert(pid, AgentGovernorState { throttle: AgentThrottle::Paused, since: now, forced_resume_at });
        }

        result
    }
}

/// One process entry from the OS process table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcessEntry {
    pub pid: u32,
    pub parent: u32,
    /// POSIX process group ID; on Windows where pgids do not exist, pass `pid` for children (and `agent` for the agent).
    pub group: u32,
}

/// Child commands an agent is running (excluding the agent's own process group so the agent stays live).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentWork {
    pub processes: Vec<u32>,
    pub groups: BTreeSet<u32>,
}

impl AgentWork {
    pub fn of(agent: u32, table: &[ProcessEntry]) -> Self {
        let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
        let mut group_of: HashMap<u32, u32> = HashMap::new();
        for entry in table {
            children.entry(entry.parent).or_default().push(entry.pid);
            group_of.insert(entry.pid, entry.group);
        }
        let own = group_of.get(&agent).copied().unwrap_or(agent);
        let mut found: Vec<u32> = Vec::new();
        let mut seen: HashSet<u32> = HashSet::from([agent]);
        let mut stack: Vec<u32> = children.remove(&agent).unwrap_or_default();
        while let Some(pid) = stack.pop() {
            if !seen.insert(pid) {
                continue;
            }
            found.push(pid);
            if let Some(next) = children.get(&pid) {
                stack.extend(next.iter().copied());
            }
        }
        let mut groups: BTreeSet<u32> = found.iter().filter_map(|p| group_of.get(p).copied()).collect();
        groups.remove(&own);
        let mut processes: Vec<u32> = found.into_iter().filter(|p| group_of.get(p).is_some_and(|g| groups.contains(g))).collect();
        processes.sort_unstable();
        Self { processes, groups }
    }
}

/// Crash-recovery record written to `paused-groups.json` before suspending any process or group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PausedRecord {
    pub pid: u32,
    pub group: u32,
    pub start_time: u64,
}

// MARK: Build slots (`scripts/build-slot.sh` equivalent for Rust / Windows)

/// Default number of concurrent heavy builds allowed on one machine.
pub const DEFAULT_BUILD_SLOTS: usize = 2;

/// Coordinates concurrent heavy builds across processes using atomic lock files so multiple agents do not thrash CPU/RAM.
#[derive(Debug, Clone)]
pub struct BuildSlots {
    dir: PathBuf,
    slots: usize,
}

/// RAII handle releasing a build slot on drop.
pub struct BuildSlotGuard {
    lock_file: PathBuf,
}

impl Drop for BuildSlotGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock_file);
    }
}

impl BuildSlots {
    pub fn new(dir: PathBuf, slots: usize) -> Self {
        Self { dir, slots: slots.max(1) }
    }

    pub fn from_env() -> Self {
        let slots =
            std::env::var("NOOK_BUILD_SLOTS").ok().and_then(|v| v.parse::<usize>().ok()).filter(|&n| n > 0).unwrap_or(DEFAULT_BUILD_SLOTS);
        Self::new(std::env::temp_dir().join("nook-build-slots"), slots)
    }

    /// Tries to acquire a free build slot without blocking. Cleans stale locks whose PID is no longer alive.
    pub fn try_acquire(&self) -> Option<BuildSlotGuard> {
        if std::env::var("NOOK_BUILD_SLOT").is_ok_and(|v| v.eq_ignore_ascii_case("off")) {
            return Some(BuildSlotGuard { lock_file: PathBuf::new() });
        }
        let _ = std::fs::create_dir_all(&self.dir);
        for slot in 1..=self.slots {
            let path = self.dir.join(format!("slot-{slot}.lock"));
            if self.try_claim(&path) {
                return Some(BuildSlotGuard { lock_file: path });
            }
            if Self::is_stale(&path) {
                let _ = std::fs::remove_file(&path);
                if self.try_claim(&path) {
                    return Some(BuildSlotGuard { lock_file: path });
                }
            }
        }
        None
    }

    fn try_claim(&self, path: &Path) -> bool {
        use std::io::Write;
        match std::fs::OpenOptions::new().write(true).create_new(true).open(path) {
            Ok(mut f) => {
                let _ = writeln!(f, "{}", std::process::id());
                true
            }
            Err(_) => false,
        }
    }

    fn is_stale(path: &Path) -> bool {
        let Ok(raw) = std::fs::read_to_string(path) else { return false };
        let Some(pid) = raw.lines().next().and_then(|l| l.trim().parse::<u32>().ok()) else { return true };
        !process_alive(pid)
    }
}

fn process_alive(pid: u32) -> bool {
    let Ok(mut sys) = System::new() else { return false };
    sys.refresh_processes_specifics(ProcessesToUpdate::Some(&[Pid::from_u32(pid)]), true, ProcessRefreshKind::nothing());
    sys.process(Pid::from_u32(pid)).is_some()
}

// MARK: Platform process priority & pause/resume

#[cfg(unix)]
mod platform {
    pub struct PriorityController;

    impl PriorityController {
        pub fn new() -> Self {
            Self
        }

        pub fn set_background(&mut self, _agent_pid: u32, pid: u32, on: bool) {
            unsafe {
                #[cfg(target_os = "macos")]
                {
                    const PRIO_DARWIN_PROCESS: libc::c_int = 4;
                    const PRIO_DARWIN_BG: libc::c_int = 0x1000;
                    let _ = libc::setpriority(PRIO_DARWIN_PROCESS, pid, if on { PRIO_DARWIN_BG } else { 0 });
                }
                #[cfg(not(target_os = "macos"))]
                {
                    let _ = libc::setpriority(libc::PRIO_PROCESS, pid, if on { 10 } else { 0 });
                }
            }
        }

        pub fn pause_group(&self, group: u32) {
            if group > 0 {
                unsafe {
                    let _ = libc::killpg(group as libc::pid_t, libc::SIGSTOP);
                }
            }
        }

        pub fn resume_group(&self, group: u32) {
            if group > 0 {
                unsafe {
                    let _ = libc::killpg(group as libc::pid_t, libc::SIGCONT);
                }
            }
        }

        pub fn release_agent(&mut self, _agent_pid: u32) {}
    }

    pub fn process_group(pid: u32) -> u32 {
        let g = unsafe { libc::getpgid(pid as libc::pid_t) };
        if g > 0 {
            g as u32
        } else {
            pid
        }
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use std::collections::HashMap;
    use std::ffi::c_void;
    use std::mem::{size_of, zeroed};
    use std::ptr::null_mut;

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicLimitInformation, SetInformationJobObject,
        JOBOBJECT_BASIC_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_PRIORITY_CLASS,
    };
    use windows_sys::Win32::System::LibraryLoader::{GetModuleHandleA, GetProcAddress};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, SetPriorityClass, BELOW_NORMAL_PRIORITY_CLASS, NORMAL_PRIORITY_CLASS, PROCESS_SET_INFORMATION, PROCESS_SET_QUOTA,
        PROCESS_SUSPEND_RESUME, PROCESS_TERMINATE,
    };

    struct JobHandle(HANDLE);
    // Win32 job handles are process-global kernel handles safe to transfer across threads.
    unsafe impl Send for JobHandle {}

    impl Drop for JobHandle {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe {
                    let _ = CloseHandle(self.0);
                }
            }
        }
    }

    /// Manages Windows Job Objects per agent so child builds inherit `BELOW_NORMAL_PRIORITY_CLASS` under pressure,
    /// and uses `ntdll!NtSuspendProcess` / `NtResumeProcess` for pausing and resuming child commands.
    pub struct PriorityController {
        jobs: HashMap<u32, JobHandle>,
    }

    impl PriorityController {
        pub fn new() -> Self {
            Self { jobs: HashMap::new() }
        }

        fn ensure_job(&mut self, agent_pid: u32, background: bool) -> Option<HANDLE> {
            let job = self.jobs.entry(agent_pid).or_insert_with(|| {
                let h = unsafe { CreateJobObjectW(null_mut(), null_mut()) };
                JobHandle(h)
            });
            if job.0.is_null() {
                return None;
            }
            let mut info: JOBOBJECT_BASIC_LIMIT_INFORMATION = unsafe { zeroed() };
            info.LimitFlags = JOB_OBJECT_LIMIT_PRIORITY_CLASS;
            info.PriorityClass = if background { BELOW_NORMAL_PRIORITY_CLASS } else { NORMAL_PRIORITY_CLASS };
            unsafe {
                let _ = SetInformationJobObject(
                    job.0,
                    JobObjectBasicLimitInformation,
                    (&info as *const JOBOBJECT_BASIC_LIMIT_INFORMATION).cast::<c_void>(),
                    size_of::<JOBOBJECT_BASIC_LIMIT_INFORMATION>() as u32,
                );
            }
            Some(job.0)
        }

        pub fn set_background(&mut self, agent_pid: u32, pid: u32, on: bool) {
            let priority = if on { BELOW_NORMAL_PRIORITY_CLASS } else { NORMAL_PRIORITY_CLASS };
            let job = self.ensure_job(agent_pid, on);
            unsafe {
                let proc_handle = OpenProcess(PROCESS_SET_INFORMATION | PROCESS_SET_QUOTA | PROCESS_TERMINATE, 0, pid);
                if proc_handle.is_null() {
                    return;
                }
                if let Some(j) = job {
                    let _ = AssignProcessToJobObject(j, proc_handle);
                }
                let _ = SetPriorityClass(proc_handle, priority);
                let _ = CloseHandle(proc_handle);
            }
        }

        pub fn pause_group(&self, pid: u32) {
            nt_suspend_or_resume(pid, true);
        }

        pub fn resume_group(&self, pid: u32) {
            nt_suspend_or_resume(pid, false);
        }

        pub fn release_agent(&mut self, agent_pid: u32) {
            self.jobs.remove(&agent_pid);
        }
    }

    fn nt_suspend_or_resume(pid: u32, suspend: bool) {
        if pid == 0 {
            return;
        }
        unsafe {
            let ntdll = GetModuleHandleA(b"ntdll.dll\0".as_ptr());
            if ntdll.is_null() {
                return;
            }
            let symbol = if suspend { b"NtSuspendProcess\0".as_ptr() } else { b"NtResumeProcess\0".as_ptr() };
            let Some(proc_fn) = GetProcAddress(ntdll, symbol) else { return };
            let call: unsafe extern "system" fn(HANDLE) -> i32 = std::mem::transmute(proc_fn);
            let h = OpenProcess(PROCESS_SUSPEND_RESUME, 0, pid);
            if !h.is_null() {
                let _ = call(h);
                let _ = CloseHandle(h);
            }
        }
    }

    pub fn process_group(pid: u32) -> u32 {
        pid
    }
}

#[cfg(not(any(unix, target_os = "windows")))]
mod platform {
    pub struct PriorityController;
    impl PriorityController {
        pub fn new() -> Self {
            Self
        }
        pub fn set_background(&mut self, _agent_pid: u32, _pid: u32, _on: bool) {}
        pub fn pause_group(&self, _group: u32) {}
        pub fn resume_group(&self, _group: u32) {}
        pub fn release_agent(&mut self, _agent_pid: u32) {}
    }
    pub fn process_group(pid: u32) -> u32 {
        pid
    }
}

// MARK: Live AgentGovernor

pub type HotCheckFn = Box<dyn Fn() -> bool + Send + Sync>;
pub type ThrottleChangeFn = Box<dyn Fn(HashMap<Uuid, AgentThrottle>) + Send + Sync>;

struct GovInner {
    system: Option<System>,
    controller: platform::PriorityController,
    states: HashMap<u32, AgentGovernorState>,
    backgrounded: HashMap<u32, HashSet<u32>>,
    paused: HashMap<u32, Vec<PausedRecord>>,
    exempt: HashSet<Uuid>,
    calm_since: Option<DateTime<Utc>>,
    last_strain: MachineStrain,
    last_published: HashMap<Uuid, AgentThrottle>,
    started: bool,
}

/// Live resource governor for workspace agents.
pub struct AgentGovernor {
    manager: Arc<Manager>,
    runtime: tokio::runtime::Handle,
    record_path: PathBuf,
    is_hot: HotCheckFn,
    on_change: ThrottleChangeFn,
    inner: Mutex<GovInner>,
}

impl AgentGovernor {
    pub fn new(
        manager: Arc<Manager>,
        runtime: tokio::runtime::Handle,
        record_path: PathBuf,
        is_hot: HotCheckFn,
        on_change: ThrottleChangeFn,
    ) -> Arc<Self> {
        Arc::new(Self {
            manager,
            runtime,
            record_path,
            is_hot,
            on_change,
            inner: Mutex::new(GovInner {
                system: System::new().ok(),
                controller: platform::PriorityController::new(),
                states: HashMap::new(),
                backgrounded: HashMap::new(),
                paused: HashMap::new(),
                exempt: HashSet::new(),
                calm_since: Some(Utc::now()),
                last_strain: MachineStrain::Calm,
                last_published: HashMap::new(),
                started: false,
            }),
        })
    }

    /// Resumes any processes left paused by a previous crashed instance, and starts the 5-second background ticker.
    pub fn start(self: &Arc<Self>) {
        {
            let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            if g.started {
                return;
            }
            g.started = true;
            self.resume_leftovers_locked(&mut g);
        }
        let this = self.clone();
        self.runtime.spawn(async move {
            loop {
                tokio::time::sleep(TICK_INTERVAL).await;
                let gov = this.clone();
                let _ = tokio::task::spawn_blocking(move || gov.tick(None)).await;
            }
        });
    }

    /// Current non-normal throttles per run ID for the UI (`ResourceWaitStrip`).
    pub fn throttles(&self) -> HashMap<Uuid, AgentThrottle> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).last_published.clone()
    }

    /// Exempts a session from being paused and immediately resumes its commands.
    pub fn let_go_on(self: &Arc<Self>, run_id: Uuid) {
        {
            let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            g.exempt.insert(run_id);
        }
        let this = self.clone();
        self.runtime.spawn_blocking(move || this.tick(None));
    }

    /// Resumes any paused commands of `agent_pid` right before Nook stops that agent.
    pub fn release_agent(&self, agent_pid: u32) {
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        self.resume_agent_locked(&mut g, agent_pid, true);
        if let Some(pids) = g.backgrounded.remove(&agent_pid) {
            for pid in pids {
                g.controller.set_background(agent_pid, pid, false);
            }
        }
        g.controller.release_agent(agent_pid);
    }

    /// Releases every paused and backgrounded command on shutdown.
    pub fn release_all(&self) {
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let paused_agents: Vec<u32> = g.paused.keys().copied().collect();
        for pid in paused_agents {
            self.resume_agent_locked(&mut g, pid, true);
        }
        let bg: Vec<(u32, HashSet<u32>)> = g.backgrounded.drain().collect();
        for (agent_pid, pids) in bg {
            for pid in pids {
                g.controller.set_background(agent_pid, pid, false);
            }
            g.controller.release_agent(agent_pid);
        }
        let changed = !g.last_published.is_empty();
        g.last_published.clear();
        drop(g);
        if changed {
            (self.on_change)(HashMap::new());
        }
    }

    /// Runs one evaluation tick. `forcing` overrides measured machine strain (used in tests).
    pub fn tick(&self, forcing: Option<MachineStrain>) {
        let running = self.manager.running_agents();
        let publish_update: Option<HashMap<Uuid, AgentThrottle>> = {
            let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());

            // Fast idle path: nothing running and nothing held back.
            if running.is_empty() && g.paused.is_empty() && g.backgrounded.is_empty() && g.last_published.is_empty() {
                return;
            }

            let now = Utc::now();
            let live_pids: HashSet<u32> = running.iter().map(|(_, pid, _)| *pid).collect();
            let dead_paused: Vec<u32> = g.paused.keys().copied().filter(|p| !live_pids.contains(p)).collect();
            for pid in dead_paused {
                self.resume_agent_locked(&mut g, pid, true);
            }
            let dead_bg: Vec<u32> = g.backgrounded.keys().copied().filter(|p| !live_pids.contains(p)).collect();
            for pid in dead_bg {
                g.backgrounded.remove(&pid);
                g.controller.release_agent(pid);
            }
            g.states.retain(|pid, _| live_pids.contains(pid));

            if running.is_empty() {
                g.exempt.clear();
                if g.last_published.is_empty() {
                    None
                } else {
                    g.last_published.clear();
                    Some(HashMap::new())
                }
            } else {
                let Some(sys) = g.system.as_mut() else {
                    return;
                };
                sys.refresh_memory();
                sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_memory());

                let (used_mem, total_mem, used_swap, total_swap) =
                    (sys.used_memory(), sys.total_memory(), sys.used_swap(), sys.total_swap());
                let table: Vec<ProcessEntry> = sys
                    .processes()
                    .iter()
                    .map(|(pid, proc_)| {
                        let p = pid.as_u32();
                        ProcessEntry {
                            pid: p,
                            parent: proc_.parent().map(|pp| pp.as_u32()).unwrap_or(0),
                            group: platform::process_group(p),
                        }
                    })
                    .collect();
                let mem_by_pid: HashMap<u32, u64> = sys.processes().iter().map(|(pid, p)| (pid.as_u32(), p.memory())).collect();

                let strain =
                    forcing.unwrap_or_else(|| Policy::strain_from_memory(used_mem, total_mem, used_swap, total_swap, (self.is_hot)()));
                if strain == MachineStrain::Critical {
                    g.calm_since = None;
                } else if g.calm_since.is_none() {
                    g.calm_since = Some(now);
                }
                if strain != g.last_strain {
                    log::info!("agent governor strain {:?} -> {:?} (agents={})", g.last_strain, strain, running.len());
                    g.last_strain = strain;
                }

                let mut work_map: HashMap<u32, AgentWork> = HashMap::new();
                let mut run_of: HashMap<u32, Uuid> = HashMap::new();
                let mut loads: Vec<AgentLoad> = Vec::with_capacity(running.len());
                for &(run_id, pid, started) in &running {
                    let found = AgentWork::of(pid, &table);
                    let resident: u64 = found.processes.iter().filter_map(|p| mem_by_pid.get(p).copied()).sum();
                    loads.push(AgentLoad {
                        pid,
                        started,
                        has_work: !found.groups.is_empty(),
                        heavy: resident >= HEAVY_WORK_BYTES,
                        exempt: g.exempt.contains(&run_id),
                    });
                    work_map.insert(pid, found);
                    run_of.insert(pid, run_id);
                }

                let next_states = Policy::next(&loads, &g.states, strain, g.calm_since, now);
                g.states = next_states;

                for load in &loads {
                    let Some(throttle) = g.states.get(&load.pid).map(|s| s.throttle) else { continue };
                    let Some(found) = work_map.get(&load.pid) else { continue };
                    self.apply_locked(&mut g, throttle, load.pid, found);
                }

                let mut published: HashMap<Uuid, AgentThrottle> = HashMap::new();
                for (&pid, state) in &g.states {
                    if state.throttle != AgentThrottle::Normal {
                        if let Some(&run_id) = run_of.get(&pid) {
                            published.insert(run_id, state.throttle);
                        }
                    }
                }
                let live_runs: HashSet<Uuid> = run_of.values().copied().collect();
                g.exempt.retain(|id| live_runs.contains(id));

                if published != g.last_published {
                    g.last_published = published.clone();
                    Some(published)
                } else {
                    None
                }
            }
        };

        if let Some(published) = publish_update {
            (self.on_change)(published);
        }
    }

    fn apply_locked(&self, g: &mut GovInner, throttle: AgentThrottle, agent_pid: u32, work: &AgentWork) {
        let wants_bg = throttle != AgentThrottle::Normal;
        let current = g.backgrounded.get(&agent_pid).cloned().unwrap_or_default();
        if wants_bg {
            let mut next = current.clone();
            for &pid in &work.processes {
                if !current.contains(&pid) {
                    g.controller.set_background(agent_pid, pid, true);
                }
                next.insert(pid);
            }
            g.backgrounded.insert(agent_pid, next);
        } else if !current.is_empty() {
            for pid in current.iter().copied().chain(work.processes.iter().copied()) {
                g.controller.set_background(agent_pid, pid, false);
            }
            g.backgrounded.remove(&agent_pid);
            g.controller.release_agent(agent_pid);
        }

        if throttle == AgentThrottle::Paused {
            let mut held = g.paused.get(&agent_pid).cloned().unwrap_or_default();
            let mut added = false;
            for &group in &work.groups {
                if held.iter().any(|r| r.group == group) {
                    continue;
                }
                // Pick a live member of this group to verify identity before resuming after a crash.
                let member = work.processes.iter().copied().find_map(|pid| {
                    if platform::process_group(pid) != group {
                        return None;
                    }
                    let start_time = g.system.as_ref()?.process(Pid::from_u32(pid))?.start_time();
                    Some(PausedRecord { pid, group, start_time })
                });
                if let Some(rec) = member {
                    held.push(rec);
                    added = true;
                }
            }
            if added {
                g.paused.insert(agent_pid, held.clone());
                self.save_record_locked(g);
                for rec in &held {
                    g.controller.pause_group(rec.group);
                }
            }
        } else if g.paused.contains_key(&agent_pid) {
            self.resume_agent_locked(g, agent_pid, true);
        }
    }

    fn resume_agent_locked(&self, g: &mut GovInner, agent_pid: u32, forget: bool) {
        let Some(held) = g.paused.get(&agent_pid).cloned() else { return };
        if let Some(sys) = g.system.as_mut() {
            sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
            for rec in &held {
                if sys.process(Pid::from_u32(rec.pid)).is_some_and(|p| p.start_time() == rec.start_time) {
                    g.controller.resume_group(rec.group);
                }
            }
        }
        if forget {
            g.paused.remove(&agent_pid);
            self.save_record_locked(g);
        }
    }

    fn save_record_locked(&self, g: &GovInner) {
        let all: Vec<PausedRecord> = g.paused.values().flat_map(|v| v.iter().cloned()).collect();
        if all.is_empty() {
            let _ = std::fs::remove_file(&self.record_path);
            return;
        }
        if let Ok(bytes) = serde_json::to_vec(&all) {
            let _ = crate::paths::write_atomic(&self.record_path, &bytes);
        }
    }

    fn resume_leftovers_locked(&self, g: &mut GovInner) {
        let Ok(bytes) = std::fs::read(&self.record_path) else { return };
        let Ok(left) = serde_json::from_slice::<Vec<PausedRecord>>(&bytes) else {
            let _ = std::fs::remove_file(&self.record_path);
            return;
        };
        if !left.is_empty() {
            if let Some(sys) = g.system.as_mut() {
                sys.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing());
                for rec in &left {
                    if sys.process(Pid::from_u32(rec.pid)).is_some_and(|p| p.start_time() == rec.start_time) {
                        g.controller.resume_group(rec.group);
                    }
                }
            }
        }
        let _ = std::fs::remove_file(&self.record_path);
    }
}

/// Suppresses unused-import warnings when `Instant` is only used in future timing helpers.
#[allow(dead_code)]
fn _clock_anchor() -> Instant {
    Instant::now()
}

#[cfg(test)]
mod tests {
    use chrono::Duration as ChronoDuration;

    use super::*;

    fn t0() -> DateTime<Utc> {
        DateTime::from_timestamp(1_000_000, 0).unwrap()
    }

    fn agents(count: u32, work: bool) -> Vec<AgentLoad> {
        (0..count)
            .map(|i| AgentLoad {
                pid: 100 + i,
                started: t0() + ChronoDuration::seconds((i as i64) * 60),
                has_work: work,
                heavy: false,
                exempt: false,
            })
            .collect()
    }

    fn heavy_agents(count: u32) -> Vec<AgentLoad> {
        agents(count, true)
            .into_iter()
            .map(|mut a| {
                a.heavy = true;
                a
            })
            .collect()
    }

    fn throttles(states: &HashMap<u32, AgentGovernorState>) -> HashMap<u32, AgentThrottle> {
        states.iter().map(|(&k, v)| (k, v.throttle)).collect()
    }

    #[test]
    fn strain_reads_memory_and_heat_but_not_busy_processor() {
        assert_eq!(Policy::strain(1, Some(0.0), false), MachineStrain::Calm);
        assert_eq!(Policy::strain(1, None, true), MachineStrain::Pressed);
        assert_eq!(Policy::strain(2, None, false), MachineStrain::Pressed);
        assert_eq!(Policy::strain(1, Some(SWAPINS_PER_SECOND_TIGHT), false), MachineStrain::Pressed);
        assert_eq!(Policy::strain(1, Some(SWAPINS_PER_SECOND_CRITICAL), false), MachineStrain::Critical);
        assert_eq!(Policy::strain(4, Some(0.0), false), MachineStrain::Critical);
    }

    #[test]
    fn strain_from_memory_maps_ram_and_swap_pressure() {
        let gib = 1024 * 1024 * 1024u64;
        assert_eq!(Policy::strain_from_memory(8 * gib, 16 * gib, 0, 4 * gib, false), MachineStrain::Calm);
        assert_eq!(Policy::strain_from_memory(8 * gib, 16 * gib, 0, 4 * gib, true), MachineStrain::Pressed);
        assert_eq!(Policy::strain_from_memory(14 * gib, 16 * gib, 0, 4 * gib, false), MachineStrain::Pressed);
        assert_eq!(Policy::strain_from_memory(14 * gib, 16 * gib, 2 * gib, 4 * gib, false), MachineStrain::Critical);
        assert_eq!(Policy::strain_from_memory(15 * gib, 16 * gib, 0, 0, false), MachineStrain::Critical);
    }

    #[test]
    fn calm_machine_leaves_agents_alone() {
        let next = Policy::next(&agents(3, true), &HashMap::new(), MachineStrain::Calm, Some(t0()), t0());
        assert!(next.values().all(|s| s.throttle == AgentThrottle::Normal));
    }

    #[test]
    fn pressed_machine_moves_every_agent_to_background() {
        let all = agents(3, true);
        let next = Policy::next(&all, &HashMap::new(), MachineStrain::Pressed, Some(t0()), t0());
        assert!(next.values().all(|s| s.throttle == AgentThrottle::Background));
        let back = Policy::next(&all, &next, MachineStrain::Calm, Some(t0()), t0() + ChronoDuration::seconds(10));
        assert!(back.values().all(|s| s.throttle == AgentThrottle::Normal));
    }

    #[test]
    fn critical_pauses_youngest_one_at_a_time_and_oldest_goes_on() {
        let all = agents(3, true);
        let now = t0() + ChronoDuration::seconds(600);
        let first = Policy::next(&all, &HashMap::new(), MachineStrain::Critical, None, now);
        assert_eq!(
            throttles(&first),
            HashMap::from([(100, AgentThrottle::Background), (101, AgentThrottle::Background), (102, AgentThrottle::Paused)])
        );
        let second = Policy::next(&all, &first, MachineStrain::Critical, None, now + ChronoDuration::seconds(5));
        assert_eq!(
            throttles(&second),
            HashMap::from([(100, AgentThrottle::Background), (101, AgentThrottle::Paused), (102, AgentThrottle::Paused)])
        );
        let third = Policy::next(&all, &second, MachineStrain::Critical, None, now + ChronoDuration::seconds(10));
        assert_eq!(third[&100].throttle, AgentThrottle::Background);
    }

    #[test]
    fn one_agent_alone_or_idle_agents_are_never_paused() {
        let next = Policy::next(&agents(1, true), &HashMap::new(), MachineStrain::Critical, None, t0());
        assert_eq!(throttles(&next), HashMap::from([(100, AgentThrottle::Background)]));
        let idle = Policy::next(&agents(3, false), &HashMap::new(), MachineStrain::Critical, None, t0());
        assert!(!idle.values().any(|s| s.throttle == AgentThrottle::Paused));
    }

    #[test]
    fn paused_work_resumes_one_at_a_time_once_room_returns() {
        let all = agents(3, true);
        let now = t0() + ChronoDuration::seconds(600);
        let paused = HashMap::from([
            (100, AgentGovernorState::new(AgentThrottle::Background, now)),
            (101, AgentGovernorState::new(AgentThrottle::Paused, now)),
            (102, AgentGovernorState::new(AgentThrottle::Paused, now)),
        ]);
        let calm_at = now + ChronoDuration::seconds(20);
        let early = Policy::next(&all, &paused, MachineStrain::Pressed, Some(calm_at), now + ChronoDuration::seconds(25));
        assert_eq!(early[&101].throttle, AgentThrottle::Paused);
        let later =
            Policy::next(&all, &early, MachineStrain::Pressed, Some(calm_at), calm_at + ChronoDuration::seconds(RESUME_AFTER_CALM_SECS));
        assert_eq!(
            throttles(&later),
            HashMap::from([(100, AgentThrottle::Background), (101, AgentThrottle::Background), (102, AgentThrottle::Paused)])
        );
        let after =
            Policy::next(&all, &later, MachineStrain::Calm, Some(calm_at), calm_at + ChronoDuration::seconds(RESUME_AFTER_CALM_SECS + 5));
        assert!(after.values().all(|s| s.throttle == AgentThrottle::Normal));
    }

    #[test]
    fn pause_ends_after_limit_and_honors_cooldown() {
        let all = agents(2, true);
        let now = t0() + ChronoDuration::seconds(600);
        let paused = HashMap::from([(101, AgentGovernorState::new(AgentThrottle::Paused, now))]);
        let end = now + ChronoDuration::seconds(MAX_PAUSE_SECS);
        let next = Policy::next(&all, &paused, MachineStrain::Critical, None, end);
        assert_eq!(next[&101].throttle, AgentThrottle::Background);
        let again = Policy::next(&all, &next, MachineStrain::Critical, None, end + ChronoDuration::seconds(5));
        assert_eq!(again[&101].throttle, AgentThrottle::Background);
        let later = Policy::next(&all, &again, MachineStrain::Critical, None, end + ChronoDuration::seconds(PAUSE_COOLDOWN_SECS));
        assert_eq!(later[&101].throttle, AgentThrottle::Paused);
    }

    #[test]
    fn exempt_agent_is_never_paused_and_resumes_immediately() {
        let mut all = agents(3, true);
        all[2].exempt = true;
        let next = Policy::next(&all, &HashMap::new(), MachineStrain::Critical, None, t0() + ChronoDuration::seconds(600));
        assert_eq!(
            throttles(&next),
            HashMap::from([(100, AgentThrottle::Background), (101, AgentThrottle::Paused), (102, AgentThrottle::Background)])
        );
        all[1].exempt = true;
        let freed = Policy::next(&all, &next, MachineStrain::Critical, None, t0() + ChronoDuration::seconds(605));
        assert_eq!(freed[&101].throttle, AgentThrottle::Background);
    }

    #[test]
    fn pressed_lets_one_heavy_job_run_full_speed_and_pauses_younger() {
        let mut all = heavy_agents(2);
        all.push(AgentLoad { pid: 102, started: t0() + ChronoDuration::seconds(120), has_work: true, heavy: false, exempt: false });
        let next = Policy::next(&all, &HashMap::new(), MachineStrain::Pressed, Some(t0()), t0() + ChronoDuration::seconds(600));
        assert_eq!(
            throttles(&next),
            HashMap::from([(100, AgentThrottle::Normal), (101, AgentThrottle::Paused), (102, AgentThrottle::Background)])
        );
    }

    #[test]
    fn waiting_heavy_work_resumes_only_after_other_heavy_job_finishes() {
        let now = t0() + ChronoDuration::seconds(600);
        let mut all = heavy_agents(2);
        let waiting = HashMap::from([
            (100, AgentGovernorState::new(AgentThrottle::Normal, now)),
            (101, AgentGovernorState::new(AgentThrottle::Paused, now)),
        ]);
        let still = Policy::next(&all, &waiting, MachineStrain::Calm, Some(t0()), now + ChronoDuration::seconds(30));
        assert_eq!(still[&101].throttle, AgentThrottle::Paused);
        all[0].heavy = false;
        all[0].has_work = false;
        let free = Policy::next(&all, &still, MachineStrain::Calm, Some(t0()), now + ChronoDuration::seconds(35));
        assert_eq!(throttles(&free), HashMap::from([(100, AgentThrottle::Normal), (101, AgentThrottle::Normal)]));
    }

    #[test]
    fn agent_work_tree_excludes_own_group() {
        let table = [
            ProcessEntry { pid: 10, parent: 1, group: 10 },
            ProcessEntry { pid: 11, parent: 10, group: 10 },
            ProcessEntry { pid: 20, parent: 10, group: 20 },
            ProcessEntry { pid: 21, parent: 20, group: 20 },
            ProcessEntry { pid: 22, parent: 21, group: 20 },
            ProcessEntry { pid: 30, parent: 10, group: 30 },
            ProcessEntry { pid: 40, parent: 1, group: 40 },
        ];
        let work = AgentWork::of(10, &table);
        assert_eq!(work.groups, BTreeSet::from([20, 30]));
        assert_eq!(work.processes, vec![20, 21, 22, 30]);
        assert_eq!(AgentWork::of(40, &table), AgentWork::default());
    }

    #[test]
    fn build_slots_cap_concurrency_and_release_on_drop() {
        let dir = std::env::temp_dir().join(format!("nook-slot-test-{}", Uuid::new_v4()));
        let slots = BuildSlots::new(dir.clone(), 2);
        let g1 = slots.try_acquire().expect("first slot");
        let g2 = slots.try_acquire().expect("second slot");
        assert!(slots.try_acquire().is_none(), "third slot must wait");
        drop(g1);
        let g3 = slots.try_acquire().expect("slot freed on drop");
        drop(g2);
        drop(g3);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
