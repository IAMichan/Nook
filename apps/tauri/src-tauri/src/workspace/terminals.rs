//! De terminals van de werkruimte (`TerminalStore` op de Mac): echte shells in een pseudo-terminal (portable-pty:
//! ConPTY op Windows, een pty op Linux), gestart in een map en eventueel met een commando. Ze blijven leven als je van
//! tab wisselt; sluiten beëindigt de shell. De interface tekent ze met xterm.js en krijgt de uitvoer als
//! `terminal-output`; de lijst verandert met `terminals-changed`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

use nook_core::workspace::terminal::{shell_launch, OutputBuffer};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

use crate::agents::lock;

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

struct Term {
    info: TerminalInfo,
    /// Input for the shell, written by its own thread: a write to a pty blocks once its buffer is full (a large paste
    /// into a program that does not read), and doing that here would hold the map lock the output reader needs.
    input: std::sync::mpsc::Sender<Vec<u8>>,
    master: Box<dyn MasterPty + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    buffer: OutputBuffer,
}

#[derive(Default)]
pub struct Terminals {
    inner: Arc<Mutex<HashMap<String, Term>>>,
    order: Mutex<Vec<String>>,
    opened: Mutex<u32>,
}

#[derive(Clone, Serialize)]
struct Chunk {
    id: String,
    data: String,
}

impl Terminals {
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
        if !std::path::Path::new(directory).is_dir() {
            return Err(format!("De map bestaat niet: {directory}"));
        }
        let shell = if cfg!(windows) { None } else { std::env::var("SHELL").ok() };
        let launch = shell_launch(directory, command, shell.as_deref(), cfg!(windows));
        let pty = native_pty_system();
        let pair =
            pty.openpty(PtySize { rows: 30, cols: 100, pixel_width: 0, pixel_height: 0 }).map_err(|e| format!("Geen terminal: {e}"))?;
        let mut builder = CommandBuilder::new(&launch.program);
        builder.args(&launch.args);
        builder.cwd(&launch.directory);
        builder.env("TERM", "xterm-256color");
        builder.env("NOOK_TERMINAL", "1");
        let mut child = pair.slave.spawn_command(builder).map_err(|e| format!("De shell starten lukte niet: {e}"))?;
        drop(pair.slave);
        let killer = child.clone_killer();
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let mut writer = pair.master.take_writer().map_err(|e| e.to_string())?;
        let (input, keys) = std::sync::mpsc::channel::<Vec<u8>>();
        // Ends when the terminal is closed (the sender is dropped) or the shell is gone.
        std::thread::spawn(move || {
            while let Ok(data) = keys.recv() {
                if writer.write_all(&data).and_then(|_| writer.flush()).is_err() {
                    break;
                }
            }
        });
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
        lock(&self.inner)
            .insert(id.clone(), Term { info: info.clone(), input, master: pair.master, killer, buffer: OutputBuffer::default() });
        lock(&self.order).push(id.clone());
        // Uitvoer lezen tot de shell stopt.
        let inner = self.inner.clone();
        let handle = app.clone();
        let reader_id = id.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let text = match lock(&inner).get_mut(&reader_id) {
                            Some(t) => t.buffer.push(&buf[..n]),
                            None => break,
                        };
                        if !text.is_empty() {
                            let _ = handle.emit("terminal-output", Chunk { id: reader_id.clone(), data: text });
                        }
                    }
                }
            }
        });
        let inner = self.inner.clone();
        let handle = app.clone();
        let wait_id = id.clone();
        std::thread::spawn(move || {
            let code = child.wait().ok().map(|s| s.exit_code());
            if let Some(t) = lock(&inner).get_mut(&wait_id) {
                t.info.running = false;
                t.info.exit_code = code;
            }
            let _ = handle.emit("terminals-changed", ());
        });
        let _ = app.emit("terminals-changed", ());
        Ok(info)
    }

    pub fn write(&self, id: &str, data: &str) -> Result<(), String> {
        let map = lock(&self.inner);
        let t = map.get(id).ok_or("Deze terminal bestaat niet meer.")?;
        t.input.send(data.as_bytes().to_vec()).map_err(|_| "De shell neemt geen invoer meer aan.".to_string())
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) {
        if let Some(t) = lock(&self.inner).get(id) {
            let _ = t.master.resize(PtySize { rows: rows.max(2), cols: cols.max(10), pixel_width: 0, pixel_height: 0 });
        }
    }

    /// Ctrl+C naar wat er in de shell draait; de shell zelf blijft open zodat de uitvoer leesbaar blijft.
    pub fn interrupt(&self, id: &str) -> Result<(), String> {
        self.write(id, "\u{3}")
    }

    pub fn replay(&self, id: &str) -> String {
        lock(&self.inner).get(id).map(|t| t.buffer.raw().to_string()).unwrap_or_default()
    }

    /// De laatste `lines` regels, zonder escapecodes, voor een agent.
    pub fn output(&self, id: &str, lines: usize) -> Option<String> {
        lock(&self.inner).get(id).map(|t| t.buffer.tail(lines, 20_000))
    }

    pub fn close(&self, app: &AppHandle, id: &str) {
        if let Some(mut t) = lock(&self.inner).remove(id) {
            if t.info.running {
                let _ = t.killer.kill();
            }
        }
        lock(&self.order).retain(|x| x != id);
        let _ = app.emit("terminals-changed", ());
    }

    /// Bij afsluiten: alle shells stoppen.
    pub fn close_all(&self) {
        for (_, mut t) in lock(&self.inner).drain() {
            if t.info.running {
                let _ = t.killer.kill();
            }
        }
    }
}
