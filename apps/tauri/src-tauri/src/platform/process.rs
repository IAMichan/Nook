//! Een hulpprogramma draaien zonder shell, met een harde tijdslimiet (`SystemControl.runProcess` op de Mac).

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Of een programma op het PATH staat.
pub fn which(program: &str) -> bool {
    let exts: Vec<String> = if cfg!(windows) { vec![String::new(), ".exe".into(), ".cmd".into()] } else { vec![String::new()] };
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| exts.iter().any(|ext| dir.join(format!("{program}{ext}")).is_file())))
}

/// Draait `program` met `args`, geeft stdout terug. Stopt het hard na `timeout`.
pub fn run(program: &str, args: &[&str], input: Option<&[u8]>, timeout: Duration) -> Result<Vec<u8>, String> {
    let mut command = Command::new(program);
    command.args(args).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Geen consolevenster dat even opflitst.
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn().map_err(|e| format!("{program} kon niet starten: {e}"))?;
    if let (Some(bytes), Some(mut stdin)) = (input, child.stdin.take()) {
        let bytes = bytes.to_vec();
        std::thread::spawn(move || {
            let _ = stdin.write_all(&bytes);
        });
    }
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        if let Some(s) = stdout.as_mut() {
            let _ = s.read_to_end(&mut out);
        }
        out
    });
    let mut stderr = child.stderr.take();
    let err_reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        if let Some(s) = stderr.as_mut() {
            let _ = s.read_to_end(&mut out);
        }
        out
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() > timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{program} deed er te lang over."));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(15)),
            Err(e) => return Err(e.to_string()),
        }
    };
    let out = reader.join().unwrap_or_default();
    let err = err_reader.join().unwrap_or_default();
    if status.success() {
        Ok(out)
    } else {
        let message = String::from_utf8_lossy(&err).trim().chars().take(300).collect::<String>();
        Err(if message.is_empty() { format!("{program} gaf een fout ({status}).") } else { message })
    }
}

pub fn run_text(program: &str, args: &[&str], timeout: Duration) -> Result<String, String> {
    run(program, args, None, timeout).map(|b| String::from_utf8_lossy(&b).to_string())
}
