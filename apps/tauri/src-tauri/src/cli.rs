//! Nook als hulpprogramma voor agents, vóór Tauri start: `nook --hook …` (of gestart als `~/.nook/nook-hook`) levert
//! een gebeurtenis van een agent af bij de draaiende Nook; `nook --mcp …` (of `~/.nook/nook-mcp`) is de MCP-server
//! op stdin/stdout waarmee een agent Nooks werkruimte gebruikt.
//!
//! Waarom de app zelf en geen apart programma: er is maar één bestand om te installeren en bij te werken, en Nook zet
//! bij elke start de koppeling in `~/.nook` (een pad zonder spaties) naar zichzelf. In een release op Windows is Nook
//! een GUI-programma (geen consolevenster); stdin en stdout werken dan gewoon via de pijpen die de agent meegeeft.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nook_core::agents::hook::{self, Mode};
use nook_core::agents::{installer, ipc};

/// Behandelt de hulpstanden. `Some(exitcode)` als Nook niet als app hoeft te starten.
pub fn dispatch() -> Option<i32> {
    let args: Vec<String> = std::env::args().collect();
    let invoked = args.first().map(|a| std::path::Path::new(a).file_stem().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default());
    let rest = args.get(1..).unwrap_or(&[]).to_vec();
    if invoked.as_deref() == Some("nook-hook") || rest.first().map(String::as_str) == Some("--hook") {
        return Some(run_hook(&rest));
    }
    if invoked.as_deref() == Some("nook-mcp") || rest.first().map(String::as_str) == Some("--mcp") {
        return Some(crate::workspace::bridge_cli::run(&rest));
    }
    None
}

/// Het hook-commando. Draait Nook niet of duurt het te lang, dan stopt het netjes en gaat de agent door.
fn run_hook(args: &[String]) -> i32 {
    let parsed = hook::parse_args(args);
    // (agent, stand) voor de waakhond: wat er bij een time-out afgedrukt moet worden.
    let current = Arc::new(Mutex::new((parsed.agent.clone(), parsed.mode)));
    let deadline = Arc::new(Mutex::new(Instant::now() + Duration::from_secs(5)));
    let done = Arc::new(AtomicBool::new(false));
    {
        let (current, deadline, done) = (current.clone(), deadline.clone(), done.clone());
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(100));
            if done.load(Ordering::SeqCst) {
                return;
            }
            if Instant::now() >= *deadline.lock().unwrap_or_else(|e| e.into_inner()) {
                let (agent, mode) = current.lock().unwrap_or_else(|e| e.into_inner()).clone();
                if mode != Mode::Statusline {
                    if let Some(out) = hook::output(&agent, mode, "") {
                        println!("{out}");
                    }
                }
                let _ = std::io::stdout().flush();
                std::process::exit(0);
            }
        });
    }

    let payload = match &parsed.payload {
        Some(p) => p.clone(),
        None => {
            let mut text = String::new();
            let _ = std::io::stdin().read_to_string(&mut text);
            text
        }
    };
    let env = |key: &str| std::env::var(key).ok();
    let (lines, agent, mode) = hook::messages(&parsed, &payload, &env);
    *current.lock().unwrap_or_else(|e| e.into_inner()) = (agent.clone(), mode);
    *deadline.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now() + mode.timeout();

    let address = ipc::address("hub");
    let mut reply = String::new();
    for line in &lines {
        reply = ipc::send_line(&address, line, true).unwrap_or_default();
    }
    done.store(true, Ordering::SeqCst);
    if mode == Mode::Statusline {
        print!("{}", statusline(&payload));
    } else if let Some(out) = hook::output(&agent, mode, &reply) {
        println!("{out}");
    }
    let _ = std::io::stdout().flush();
    0
}

/// De eerdere statusregel van de gebruiker als die er was, anders een korte eigen regel.
fn statusline(payload: &str) -> String {
    let saved =
        std::fs::read(installer::previous_status_line_file()).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
    if let Some(command) = saved.as_ref().and_then(|s| s.get("command")).and_then(|c| c.as_str()).filter(|c| !c.is_empty()) {
        let mut shell = if cfg!(windows) && nook_core::agents::which("sh").is_none() {
            let mut c = std::process::Command::new("cmd");
            c.args(["/C", command]);
            c
        } else {
            let mut c = std::process::Command::new("sh");
            c.args(["-c", command]);
            c
        };
        shell.stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null());
        if let Ok(mut child) = shell.spawn() {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(payload.as_bytes());
            }
            if let Ok(out) = child.wait_with_output() {
                return String::from_utf8_lossy(&out.stdout).into_owned();
            }
        }
    }
    format!("{}\n", hook::fallback_statusline(payload))
}
