//! De terminals van de werkruimte (`TerminalStore` op de Mac): echte shells in een pseudo-terminal (portable-pty:
//! ConPTY op Windows, een pty op Linux), gestart in een map en eventueel met een commando. Ze blijven leven als je van
//! tab wisselt; sluiten beëindigt de shell. De interface tekent ze met xterm.js en krijgt de uitvoer als
//! `terminal-output`; de lijst verandert met `terminals-changed`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nook_core::workspace::terminal::{shell_launch, OutputBuffer, ShellLaunch};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::agents::lock;

/// Fallback PTY size used only when a background terminal hits its start deadline before any
/// terminal on screen has reported a real size.
pub const DEFAULT_COLS: u16 = 100;
pub const DEFAULT_ROWS: u16 = 30;
/// Minimum fitted dimensions accepted as a real on-screen terminal size. A container that is
/// still laying out can briefly report a few cells; starting a shell at that width would wrap
/// prompts and banners prematurely.
pub const MIN_SHOWN_COLS: u16 = 10;
pub const MIN_SHOWN_ROWS: u16 = 2;
/// How long a newly opened terminal waits for `resize` (`shown`) before starting its shell at
/// the last shown terminal size (or `DEFAULT_COLS × DEFAULT_ROWS`) anyway, matching Mac's
/// `TerminalSession.startDeadline`.
const START_DEADLINE: Duration = Duration::from_millis(500);

/// De agent die een terminal startte via de werkruimte-brug (`terminal_run`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOwner {
    /// "Claude Code".
    pub agent: String,
    /// Alleen deze aanroeper mag de terminal stoppen.
    pub key: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInfo {
    pub id: String,
    /// Kort id waarmee agents ernaar verwijzen: "t3".
    pub short_id: String,
    pub title: String,
    /// De map waarin hij openging, zodat hij bij die sessie blijft, ook na een `cd`.
    pub origin: String,
    pub command: Option<String>,
    pub owner: Option<TerminalOwner>,
    pub running: bool,
    pub exit_code: Option<u32>,
    pub created: chrono::DateTime<chrono::Utc>,
}

#[derive(Clone, Serialize)]
struct Chunk {
    id: String,
    data: String,
}

enum TerminalEvent {
    Output { id: String, data: String },
    Changed,
}

type EmitterFn = Arc<dyn Fn(TerminalEvent) + Send + Sync>;

fn app_emitter(app: &AppHandle) -> EmitterFn {
    let handle = app.clone();
    Arc::new(move |event| match event {
        TerminalEvent::Output { id, data } => {
            let _ = handle.emit("terminal-output", Chunk { id, data });
        }
        TerminalEvent::Changed => {
            let _ = handle.emit("terminals-changed", ());
        }
    })
}

fn pty_size(cols: u16, rows: u16) -> PtySize {
    PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }
}

fn valid_shown_size(cols: u16, rows: u16) -> Option<PtySize> {
    (cols >= MIN_SHOWN_COLS && rows >= MIN_SHOWN_ROWS).then(|| pty_size(cols, rows))
}

struct PendingLaunch {
    launch: ShellLaunch,
    emitter: EmitterFn,
    queued_input: Vec<Vec<u8>>,
}

struct RunningTerm {
    /// Input for the shell, written by its own thread: a write to a pty blocks once its buffer is full (a large paste
    /// into a program that does not read), and doing that here would hold the map lock the output reader needs.
    input: std::sync::mpsc::Sender<Vec<u8>>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    /// The shell's process, to tell which dev servers a terminal started (AG-134).
    pid: Option<u32>,
}

enum TermState {
    /// Waiting for `resize` (`shown`) to report the real screen dimensions before spawning the shell.
    Pending(PendingLaunch),
    /// Currently spawning the PTY and child process outside the `inner` lock.
    Starting { queued_input: Vec<Vec<u8>>, latest_size: PtySize },
    /// The shell is running inside its PTY.
    Running(RunningTerm),
    /// The shell exited or failed to start.
    Exited,
}

struct Term {
    info: TerminalInfo,
    state: TermState,
    buffer: OutputBuffer,
}

pub struct Terminals {
    inner: Arc<Mutex<HashMap<String, Term>>>,
    order: Mutex<Vec<String>>,
    opened: Mutex<u32>,
    /// The size the last terminal on screen had: a terminal that starts before it is shown (e.g. an
    /// agent's background dev server) takes that size instead of a made-up 100×30, matching Mac's
    /// `TerminalSession.lastShownSize`.
    last_shown_size: Arc<Mutex<Option<PtySize>>>,
    start_deadline: Duration,
}

impl Default for Terminals {
    fn default() -> Self {
        Self::with_start_deadline(START_DEADLINE)
    }
}

impl Terminals {
    fn with_start_deadline(start_deadline: Duration) -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            order: Mutex::new(Vec::new()),
            opened: Mutex::new(0),
            last_shown_size: Arc::new(Mutex::new(None)),
            start_deadline,
        }
    }

    /// The shells of the open terminals.
    pub fn shell_pids(&self) -> Vec<u32> {
        lock(&self.inner)
            .values()
            .filter_map(|t| match &t.state {
                TermState::Running(r) => r.pid,
                _ => None,
            })
            .collect()
    }

    pub fn list(&self) -> Vec<TerminalInfo> {
        let map = lock(&self.inner);
        lock(&self.order).iter().filter_map(|id| map.get(id).map(|t| t.info.clone())).collect()
    }

    /// Een terminal op kort id ("t3") of volledig id.
    pub fn find(&self, reference: &str) -> Option<TerminalInfo> {
        let key = reference.trim().to_lowercase();
        lock(&self.inner).values().find(|t| t.info.short_id == key || t.info.id == key).map(|t| t.info.clone())
    }

    /// De terminals die in `folder` (of eronder) openden: die van de sessie die daar werkt.
    pub fn in_folder(&self, folder: &str) -> Vec<TerminalInfo> {
        self.list().into_iter().filter(|t| nook_core::workspace::terminal::within(&t.origin, folder)).collect()
    }

    pub fn open(
        &self,
        app: &AppHandle,
        directory: &str,
        command: Option<&str>,
        title: Option<&str>,
        owner: Option<TerminalOwner>,
    ) -> Result<TerminalInfo, String> {
        self.open_with_size(app, directory, command, title, owner, None)
    }

    pub fn open_with_size(
        &self,
        app: &AppHandle,
        directory: &str,
        command: Option<&str>,
        title: Option<&str>,
        owner: Option<TerminalOwner>,
        size: Option<(u16, u16)>,
    ) -> Result<TerminalInfo, String> {
        self.open_internal(app_emitter(app), directory, command, title, owner, size)
    }

    fn open_internal(
        &self,
        emitter: EmitterFn,
        directory: &str,
        command: Option<&str>,
        title: Option<&str>,
        owner: Option<TerminalOwner>,
        size: Option<(u16, u16)>,
    ) -> Result<TerminalInfo, String> {
        if !std::path::Path::new(directory).is_dir() {
            return Err(format!("De map bestaat niet: {directory}"));
        }
        let shell = if cfg!(windows) { None } else { std::env::var("SHELL").ok() };
        let launch = shell_launch(directory, command, shell.as_deref(), cfg!(windows));
        let number = {
            let mut n = lock(&self.opened);
            *n += 1;
            *n
        };
        let id = uuid::Uuid::new_v4().to_string();
        let name = title.map(str::to_string).unwrap_or_else(|| nook_core::agents::text::project_name(directory));
        let info = TerminalInfo {
            id: id.clone(),
            short_id: format!("t{number}"),
            title: if name.is_empty() { "Terminal".into() } else { name },
            origin: directory.into(),
            command: command.map(str::to_string).filter(|c| !c.trim().is_empty()),
            owner,
            running: true,
            exit_code: None,
            created: chrono::Utc::now(),
        };
        let explicit_size = size.and_then(|(cols, rows)| valid_shown_size(cols, rows));
        if let Some(sized) = explicit_size {
            *lock(&self.last_shown_size) = Some(sized);
        }
        lock(&self.inner).insert(
            id.clone(),
            Term {
                info: info.clone(),
                state: TermState::Pending(PendingLaunch { launch, emitter: emitter.clone(), queued_input: Vec::new() }),
                buffer: OutputBuffer::default(),
            },
        );
        lock(&self.order).push(id.clone());
        emitter(TerminalEvent::Changed);

        if let Some(sized) = explicit_size {
            // Caller already gave us the exact screen dimensions; start immediately without waiting.
            if let Err(err) = Self::start_pending(&self.inner, &id, sized) {
                lock(&self.inner).remove(&id);
                lock(&self.order).retain(|x| x != &id);
                emitter(TerminalEvent::Changed);
                return Err(err);
            }
        } else {
            // Wait briefly for `resize` (`shown`) to report the real on-screen width; if nobody
            // shows this terminal (e.g. a background dev server), start it at the last shown size
            // (or fallback 100×30) once the deadline passes.
            let inner = self.inner.clone();
            let last_shown = self.last_shown_size.clone();
            let deadline = self.start_deadline;
            let start_id = id.clone();
            std::thread::spawn(move || {
                std::thread::sleep(deadline);
                let fallback = lock(&last_shown).unwrap_or_else(|| pty_size(DEFAULT_COLS, DEFAULT_ROWS));
                let _ = Self::start_pending(&inner, &start_id, fallback);
            });
        }
        Ok(info)
    }

    fn start_pending(inner: &Arc<Mutex<HashMap<String, Term>>>, id: &str, size: PtySize) -> Result<(), String> {
        let pending = {
            let mut map = lock(inner);
            let Some(term) = map.get_mut(id) else {
                return Ok(());
            };
            if !matches!(term.state, TermState::Pending(_)) {
                return Ok(());
            }
            let prev = std::mem::replace(&mut term.state, TermState::Starting { queued_input: Vec::new(), latest_size: size });
            match prev {
                TermState::Pending(p) => p,
                _ => unreachable!(),
            }
        };

        let spawned = Self::spawn_pty(&pending.launch, size);
        let (master, mut child, killer, pid, mut reader, mut writer) = match spawned {
            Ok(parts) => parts,
            Err(err) => {
                if let Some(term) = lock(inner).get_mut(id) {
                    term.info.running = false;
                    term.state = TermState::Exited;
                }
                (pending.emitter)(TerminalEvent::Changed);
                return Err(err);
            }
        };

        let (input, keys) = std::sync::mpsc::channel::<Vec<u8>>();
        // Ends when the terminal is closed (the sender is dropped) or the shell is gone.
        std::thread::spawn(move || {
            while let Ok(data) = keys.recv() {
                if writer.write_all(&data).and_then(|_| writer.flush()).is_err() {
                    break;
                }
            }
        });

        let emitter = pending.emitter;
        let orphan_killer = {
            let mut map = lock(inner);
            if let Some(term) = map.get_mut(id) {
                let (extra_input, latest_size) = match std::mem::replace(&mut term.state, TermState::Exited) {
                    TermState::Starting { queued_input, latest_size } => (queued_input, latest_size),
                    _ => (Vec::new(), size),
                };
                if latest_size.cols != size.cols || latest_size.rows != size.rows {
                    let _ = master.resize(latest_size);
                }
                for chunk in pending.queued_input.into_iter().chain(extra_input) {
                    let _ = input.send(chunk);
                }
                term.state = TermState::Running(RunningTerm { input, master, killer, pid });
                None
            } else {
                Some(killer)
            }
        };

        if let Some(mut killer) = orphan_killer {
            let _ = killer.kill();
            return Ok(());
        }

        // Read PTY output until the shell exits.
        let reader_inner = inner.clone();
        let reader_emitter = emitter.clone();
        let reader_id = id.to_string();
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let text = match lock(&reader_inner).get_mut(&reader_id) {
                            Some(t) => t.buffer.push(&buf[..n]),
                            None => break,
                        };
                        if !text.is_empty() {
                            reader_emitter(TerminalEvent::Output { id: reader_id.clone(), data: text });
                        }
                    }
                }
            }
        });

        let wait_inner = inner.clone();
        let wait_id = id.to_string();
        std::thread::spawn(move || {
            let code = child.wait().ok().map(|s| s.exit_code());
            if let Some(t) = lock(&wait_inner).get_mut(&wait_id) {
                t.info.running = false;
                t.info.exit_code = code;
                t.state = TermState::Exited;
            }
            emitter(TerminalEvent::Changed);
        });

        Ok(())
    }

    #[allow(clippy::type_complexity)]
    fn spawn_pty(
        launch: &ShellLaunch,
        size: PtySize,
    ) -> Result<
        (
            Box<dyn MasterPty + Send>,
            Box<dyn portable_pty::Child + Send + Sync>,
            Box<dyn ChildKiller + Send + Sync>,
            Option<u32>,
            Box<dyn Read + Send>,
            Box<dyn Write + Send>,
        ),
        String,
    > {
        let pty = native_pty_system();
        let pair = pty.openpty(size).map_err(|e| format!("Geen terminal: {e}"))?;
        let mut builder = CommandBuilder::new(&launch.program);
        builder.args(&launch.args);
        builder.cwd(&launch.directory);
        builder.env("TERM", "xterm-256color");
        builder.env("NOOK_TERMINAL", "1");
        let child = pair.slave.spawn_command(builder).map_err(|e| format!("De shell starten lukte niet: {e}"))?;
        drop(pair.slave);
        let killer = child.clone_killer();
        let pid = child.process_id();
        let reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        Ok((pair.master, child, killer, pid, reader, writer))
    }

    pub fn write(&self, id: &str, data: &str) -> Result<(), String> {
        let mut map = lock(&self.inner);
        let t = map.get_mut(id).ok_or("Deze terminal bestaat niet meer.")?;
        match &mut t.state {
            TermState::Pending(p) => {
                p.queued_input.push(data.as_bytes().to_vec());
                Ok(())
            }
            TermState::Starting { queued_input, .. } => {
                queued_input.push(data.as_bytes().to_vec());
                Ok(())
            }
            TermState::Running(r) => r.input.send(data.as_bytes().to_vec()).map_err(|_| "De shell neemt geen invoer meer aan.".to_string()),
            TermState::Exited => Err("De shell neemt geen invoer meer aan.".to_string()),
        }
    }

    /// Reports the terminal's fitted size on screen (`TerminalSession.shown` on Mac).
    /// If the shell has not started yet, this starts it immediately at `(cols, rows)` instead of
    /// waiting for the fallback deadline.
    pub fn resize(&self, id: &str, cols: u16, rows: u16) {
        let Some(size) = valid_shown_size(cols, rows) else {
            return;
        };
        *lock(&self.last_shown_size) = Some(size);

        let should_start = {
            let mut map = lock(&self.inner);
            let Some(t) = map.get_mut(id) else {
                return;
            };
            match &mut t.state {
                TermState::Pending(_) => true,
                TermState::Starting { latest_size, .. } => {
                    *latest_size = size;
                    false
                }
                TermState::Running(r) => {
                    let _ = r.master.resize(size);
                    false
                }
                TermState::Exited => false,
            }
        };
        if should_start {
            let _ = Self::start_pending(&self.inner, id, size);
        }
    }

    /// Ctrl+C naar wat er in de shell draait; de shell zelf blijft open zodat de uitvoer leesbaar blijft.
    pub fn interrupt(&self, id: &str) -> Result<(), String> {
        let map = lock(&self.inner);
        let t = map.get(id).ok_or("Deze terminal bestaat niet meer.")?;
        match &t.state {
            TermState::Running(r) => r.input.send(b"\x03".to_vec()).map_err(|_| "De shell neemt geen invoer meer aan.".to_string()),
            // Matching Mac's `guard running, started else { return }`: no process to interrupt yet.
            TermState::Pending(_) | TermState::Starting { .. } | TermState::Exited => Ok(()),
        }
    }

    pub fn replay(&self, id: &str) -> String {
        lock(&self.inner).get(id).map(|t| t.buffer.raw().to_string()).unwrap_or_default()
    }

    /// De laatste `lines` regels, zonder escapecodes, voor een agent.
    pub fn output(&self, id: &str, lines: usize) -> Option<String> {
        lock(&self.inner).get(id).map(|t| t.buffer.tail(lines, 20_000))
    }

    pub fn close(&self, app: &AppHandle, id: &str) {
        self.close_internal(Some(&app_emitter(app)), id);
    }

    fn close_internal(&self, emitter: Option<&EmitterFn>, id: &str) {
        if let Some(t) = lock(&self.inner).remove(id) {
            if let TermState::Running(mut r) = t.state {
                if t.info.running {
                    let _ = r.killer.kill();
                }
            }
        }
        lock(&self.order).retain(|x| x != id);
        if let Some(emit) = emitter {
            emit(TerminalEvent::Changed);
        }
    }

    /// Bij afsluiten: alle shells stoppen.
    pub fn close_all(&self) {
        for (_, t) in lock(&self.inner).drain() {
            if let TermState::Running(mut r) = t.state {
                if t.info.running {
                    let _ = r.killer.kill();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noop_emitter() -> EmitterFn {
        Arc::new(|_| {})
    }

    #[test]
    fn valid_shown_size_rejects_layout_glitches() {
        assert!(valid_shown_size(0, 0).is_none());
        assert!(valid_shown_size(9, 24).is_none());
        assert!(valid_shown_size(80, 1).is_none());
        let ok = valid_shown_size(64, 20).expect("valid dimensions");
        assert_eq!(ok.cols, 64);
        assert_eq!(ok.rows, 20);
    }

    #[test]
    fn closing_before_shown_never_spawns_a_shell() {
        let terms = Terminals::with_start_deadline(Duration::from_millis(200));
        let dir = std::env::temp_dir();
        let info =
            terms.open_internal(noop_emitter(), dir.to_str().unwrap(), None, Some("Pending"), None, None).expect("open pending terminal");
        assert!(terms.shell_pids().is_empty(), "shell must wait for shown/deadline before spawning");

        terms.close_internal(None, &info.id);
        std::thread::sleep(Duration::from_millis(260));
        assert!(terms.list().is_empty());
        assert!(terms.shell_pids().is_empty());
    }

    #[cfg(unix)]
    fn parse_stty_size(output: &str) -> Option<(u16, u16)> {
        output.lines().find_map(|line| {
            let mut parts = line.split_whitespace();
            let rows: u16 = parts.next()?.parse().ok()?;
            let cols: u16 = parts.next()?.parse().ok()?;
            if parts.next().is_some() {
                return None;
            }
            Some((rows, cols))
        })
    }

    #[cfg(unix)]
    fn wait_for_stty_size(terms: &Terminals, id: &str) -> (u16, u16) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(out) = terms.output(id, 200) {
                if let Some(size) = parse_stty_size(&out) {
                    return size;
                }
            }
            assert!(std::time::Instant::now() < deadline, "terminal did not print stty size; output was: {:?}", terms.output(id, 200));
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[cfg(unix)]
    #[test]
    fn terminal_starts_at_its_shown_width_and_remembers_it_for_background_terminals() {
        let terms = Terminals::with_start_deadline(Duration::from_millis(250));
        let dir = std::env::temp_dir();
        let dir_str = dir.to_str().unwrap();

        // 1. Open a terminal without explicit size: shell waits for `resize` (`shown`).
        let first =
            terms.open_internal(noop_emitter(), dir_str, Some("stty size"), Some("Shown"), None, None).expect("open first terminal");
        // Tiny layout-glitch resize must be ignored.
        terms.resize(&first.id, 4, 1);
        assert!(terms.shell_pids().is_empty(), "tiny resize must not spawn the shell");

        // Real screen size arrives before the deadline: shell spawns at 64×20, not 100×30.
        terms.resize(&first.id, 64, 20);
        let (rows, cols) = wait_for_stty_size(&terms, &first.id);
        assert_eq!((rows, cols), (20, 64), "shell must read the shown screen dimensions at launch");

        // 2. Open a second (background) terminal that is never shown: after the deadline it must
        //    start at the remembered last_shown_size (64×20) rather than fixed 100×30.
        let second = terms
            .open_internal(noop_emitter(), dir_str, Some("stty size"), Some("Background"), None, None)
            .expect("open background terminal");
        let (bg_rows, bg_cols) = wait_for_stty_size(&terms, &second.id);
        assert_eq!((bg_rows, bg_cols), (20, 64), "background terminal must reuse last_shown_size");

        terms.close_all();
    }
}
