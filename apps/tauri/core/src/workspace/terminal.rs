//! Wat de terminals en de dev-servers van de werkruimte nodig hebben zonder venster (`TerminalSessions`,
//! `ProjectScripts` en `DevServers` op de Mac): hoe een shell start, uitvoer bewaren en leesbaar maken voor een agent,
//! de scripts van een project (`nook.json`) en welke lokale servers een sessie draait.

use std::collections::{BTreeMap, HashMap};
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Hoe een terminal start: programma, argumenten en map. Het commando draait eerst; daarna blijft een interactieve
/// shell open, zodat de uitvoer te lezen blijft.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellLaunch {
    pub program: String,
    pub args: Vec<String>,
    pub directory: String,
}

/// `shell`: `$SHELL` (Unix) of `None` voor de standaard. Op Windows PowerShell, met het commando na `Set-Location`.
pub fn shell_launch(directory: &str, command: Option<&str>, shell: Option<&str>, windows: bool) -> ShellLaunch {
    let command = command.map(str::trim).filter(|c| !c.is_empty());
    if windows {
        let mut args = vec!["-NoLogo".to_string(), "-NoExit".to_string()];
        if let Some(c) = command {
            args.push("-Command".into());
            args.push(c.into());
        }
        return ShellLaunch { program: shell.unwrap_or("powershell.exe").into(), args, directory: directory.into() };
    }
    let shell = shell.filter(|s| !s.is_empty()).unwrap_or("/bin/bash");
    let mut script = format!("cd {} 2>/dev/null; ", quote(directory));
    if let Some(c) = command {
        script += c;
        script += "; ";
    }
    script += &format!("exec {} -l", quote(shell));
    ShellLaunch { program: shell.into(), args: vec!["-l".into(), "-c".into(), script], directory: directory.into() }
}

fn quote(text: &str) -> String {
    crate::agents::profiles::shell_quote(text)
}

/// What `run_command` in Nook Chat starts in a visible terminal: a validated command, resolved folder, and tab title.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandRequest {
    pub command: String,
    pub folder: String,
    pub title: String,
}

/// Expands a leading `~` (`~`, `~/sub`, `~\sub`) against `home`, matching NSString.expandingTildeInPath on the Mac.
pub fn expand_tilde(path: &str, home: &str) -> String {
    let trimmed = path.trim();
    if trimmed == "~" {
        return home.to_string();
    }
    if let Some(rest) = trimmed.strip_prefix("~/").or_else(|| trimmed.strip_prefix("~\\")) {
        let base = home.trim_end_matches(['/', '\\']);
        let sep = if base.contains('\\') && !base.contains('/') { '\\' } else { '/' };
        if rest.is_empty() {
            return base.to_string();
        }
        return format!("{base}{sep}{rest}");
    }
    trimmed.to_string()
}

/// Validates and normalizes `run_command` arguments before opening a visible terminal beside the chat.
pub fn command_request(command: &str, folder: &str, home: &str) -> Result<CommandRequest, String> {
    let command = command.trim().to_string();
    if command.is_empty() {
        return Err(crate::i18n::tr("Er is geen commando opgegeven.", "No command was given.").into());
    }
    let raw_folder = folder.trim();
    let folder = if raw_folder.is_empty() { home.to_string() } else { expand_tilde(raw_folder, home) };
    let title: String = command.chars().take(40).collect();
    Ok(CommandRequest { command, folder, title })
}

/// Bewaart de laatste uitvoer van een terminal (ruwe tekst met escapecodes), om hem opnieuw te tonen en voor agents.
#[derive(Debug, Clone, Default)]
pub struct OutputBuffer {
    text: String,
    pending: Vec<u8>,
}

impl OutputBuffer {
    pub const LIMIT: usize = 400_000;

    /// Voegt bytes toe; een UTF-8-teken dat over twee stukken verdeeld is, wacht op de rest. Geeft de nieuwe tekst.
    pub fn push(&mut self, bytes: &[u8]) -> String {
        self.pending.extend_from_slice(bytes);
        let valid = match std::str::from_utf8(&self.pending) {
            Ok(_) => self.pending.len(),
            Err(e) if e.error_len().is_none() => e.valid_up_to(),
            Err(_) => self.pending.len(),
        };
        let chunk: Vec<u8> = self.pending.drain(..valid).collect();
        let text = String::from_utf8_lossy(&chunk).into_owned();
        self.text.push_str(&text);
        if self.text.len() > Self::LIMIT {
            let mut cut = self.text.len() - Self::LIMIT * 3 / 4;
            while !self.text.is_char_boundary(cut) {
                cut += 1;
            }
            self.text.drain(..cut);
        }
        text
    }

    pub fn raw(&self) -> &str {
        &self.text
    }

    /// De laatste regels zoals een mens ze ziet: zonder kleur- en stuurcodes.
    pub fn tail(&self, lines: usize, limit: usize) -> String {
        super::bridge::terminal_tail(&strip_ansi(&self.text), lines, limit)
    }
}

/// Haalt ANSI-escapecodes weg (kleuren, cursor, titels) en verwerkt een `\r` zonder `\n` als "begin de regel opnieuw".
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    let mut line_start = 0;
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.peek() {
                Some('[') => {
                    chars.next();
                    while let Some(&n) = chars.peek() {
                        chars.next();
                        if ('@'..='~').contains(&n) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    while let Some(n) = chars.next() {
                        if n == '\u{7}' {
                            break;
                        }
                        if n == '\u{1b}' && chars.peek() == Some(&'\\') {
                            chars.next();
                            break;
                        }
                    }
                }
                Some(_) => {
                    chars.next();
                }
                None => {}
            },
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    continue;
                }
                out.truncate(line_start);
            }
            '\n' => {
                out.push('\n');
                line_start = out.len();
            }
            '\u{8}' => {
                if out.len() > line_start {
                    out.pop();
                }
            }
            c if c.is_control() && c != '\t' => {}
            c => out.push(c),
        }
    }
    out
}

// MARK: Scripts van het project

fn default_true() -> bool {
    true
}

/// Een commando dat een project voor zijn sessies definieert, in `nook.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectScript {
    pub id: String,
    pub name: String,
    pub command: String,
    /// Draait vanzelf in een terminal direct nadat Nook een worktree maakte.
    pub run_on_worktree_create: bool,
    pub preview_url: Option<String>,
    pub auto_open_preview: bool,
    #[serde(default)]
    pub stop_on_settle: bool,
    #[serde(default)]
    pub run_on_settle: bool,
    /// Only for `runOnWorktreeCreate`: `true` (default) launches the agent while the script runs; `"async": false`
    /// holds the agent's first turn until the script ends, and fails the start if the script exits non-zero.
    #[serde(rename = "async", default = "default_true")]
    pub async_run: bool,
}

pub const SCRIPT_FILE: &str = "nook.json";

/// De scripts van het project rond `folder`: de dichtstbijzijnde `nook.json`, tot de root van de repository.
pub fn load_scripts(folder: &str) -> Vec<ProjectScript> {
    if folder.is_empty() {
        return vec![];
    }
    let mut dir = Path::new(folder).to_path_buf();
    for _ in 0..12 {
        if let Ok(bytes) = std::fs::read(dir.join(SCRIPT_FILE)) {
            let scripts = parse_scripts(&bytes);
            if !scripts.is_empty() {
                return scripts;
            }
        }
        if dir.join(".git").exists() {
            break;
        }
        let Some(parent) = dir.parent() else { break };
        dir = parent.to_path_buf();
    }
    vec![]
}

/// Ruimhartig: een script zonder commando valt weg, ontbrekende namen en ids volgen vanzelf, hooguit 50.
pub fn parse_scripts(bytes: &[u8]) -> Vec<ProjectScript> {
    let Ok(root) = serde_json::from_slice::<Value>(bytes) else { return vec![] };
    let Some(list) = root.get("scripts").and_then(Value::as_array) else { return vec![] };
    let mut seen = std::collections::HashSet::new();
    let mut out = vec![];
    for (index, item) in list.iter().take(50).enumerate() {
        let text = |k: &str| item.get(k).and_then(Value::as_str).unwrap_or("").trim().to_string();
        let command = text("command");
        if command.is_empty() {
            continue;
        }
        let name = text("name");
        let mut id = text("id");
        if id.is_empty() {
            id = super::models::slug(if name.is_empty() { &command } else { &name }, 32);
        }
        if seen.contains(&id) {
            id = format!("{id}-{index}");
        }
        seen.insert(id.clone());
        out.push(ProjectScript {
            id,
            name: if name.is_empty() { command.clone() } else { name },
            command,
            run_on_worktree_create: item.get("runOnWorktreeCreate").and_then(Value::as_bool).unwrap_or(false),
            preview_url: item.get("previewUrl").and_then(Value::as_str).and_then(super::bridge::allowed_url),
            auto_open_preview: item.get("autoOpenPreview").and_then(Value::as_bool).unwrap_or(false),
            stop_on_settle: item.get("stopOnSettle").and_then(Value::as_bool).unwrap_or(false),
            run_on_settle: item.get("runOnSettle").and_then(Value::as_bool).unwrap_or(false),
            async_run: item.get("async").and_then(Value::as_bool).unwrap_or(true),
        });
    }
    out
}

/// The setup scripts of a new worktree, and whether any of them holds the agent until it ends (`"async": false`).
pub fn setup_scripts(scripts: &[ProjectScript]) -> (Vec<ProjectScript>, bool) {
    let setup: Vec<ProjectScript> = scripts.iter().filter(|s| s.run_on_worktree_create).cloned().collect();
    let holds = setup.iter().any(|s| !s.async_run);
    (setup, holds)
}

/// Wraps a blocking setup script so it writes its exit code to `status_file` and closes its terminal on success
/// (while staying open with the error output when it fails). Matches macOS `ProjectScripts.blockingCommand`.
pub fn blocking_command(command: &str, status_file: &str, windows: bool) -> String {
    if windows {
        let escaped_file = status_file.replace('\'', "''");
        return format!(
            "& {{ $global:LASTEXITCODE = 0; try {{ {command}; if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {{ $__nook_status = [int]$LASTEXITCODE }} elseif ($?) {{ $__nook_status = 0 }} else {{ $__nook_status = 1 }} }} catch {{ Write-Error $_; $__nook_status = 1 }}; [System.IO.File]::WriteAllText('{escaped_file}', [string]$__nook_status); if ($__nook_status -eq 0) {{ exit 0 }} }}"
        );
    }
    let script =
        format!("(\n{command}\n)\n__nook_status=$?\nprintf '%s' \"$__nook_status\" > {}\nexit \"$__nook_status\"", quote(status_file));
    format!("/bin/sh -c {} && exit 0", quote(&script))
}

/// Parses the exit code written by [`blocking_command`]; returns `None` while the script is still running.
pub fn exit_status(bytes: Option<&[u8]>) -> Option<i32> {
    let data = bytes?;
    String::from_utf8_lossy(data).trim().parse::<i32>().ok()
}

// MARK: Dev-servers

/// Een lokale server die een sessie startte: een proces in de map van de sessie dat op een TCP-poort luistert.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DevServer {
    pub pid: u32,
    pub command: String,
    pub port: u16,
    /// Altijd op localhost: een server die op alle adressen luistert, antwoordt daar ook.
    pub url: String,
}

/// Poorten die nooit een pagina zijn (databases, caches, debuggers).
const SKIPPED_PORTS: [u16; 9] = [22, 53, 3306, 5432, 6379, 9229, 9222, 27017, 11211];

/// `/proc/net/tcp` en `tcp6`: de inodes van luisterende sockets (status 0A) met hun poort.
pub fn parse_proc_net_tcp(text: &str) -> Vec<(u64, u16)> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 10 || cols[3] != "0A" {
                return None;
            }
            let port = u16::from_str_radix(cols[1].rsplit(':').next()?, 16).ok()?;
            let inode = cols[9].parse().ok()?;
            Some((inode, port))
        })
        .collect()
}

/// `netstat -ano -p TCP` op Windows: per proces de poorten waarop het luistert.
pub fn parse_netstat(text: &str) -> Vec<(u32, u16)> {
    text.lines()
        .filter_map(|line| {
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 5 || !cols[0].eq_ignore_ascii_case("TCP") || !cols[3].eq_ignore_ascii_case("LISTENING") {
                return None;
            }
            let port = cols[1].rsplit(':').next()?.parse().ok()?;
            Some((cols[4].parse().ok()?, port))
        })
        .collect()
}

/// Eén server per poort, gesorteerd; de poorten van `SKIPPED_PORTS` vallen weg.
pub fn servers(listeners: &[(u32, u16)], commands: &HashMap<u32, String>) -> Vec<DevServer> {
    let mut by_port: BTreeMap<u16, DevServer> = BTreeMap::new();
    for &(pid, port) in listeners {
        if SKIPPED_PORTS.contains(&port) || by_port.contains_key(&port) {
            continue;
        }
        by_port.insert(
            port,
            DevServer { pid, command: commands.get(&pid).cloned().unwrap_or_default(), port, url: format!("http://localhost:{port}") },
        );
    }
    by_port.into_values().collect()
}

/// Ligt `cwd` in `folder` (of is het die map)?
pub fn within(cwd: &str, folder: &str) -> bool {
    let root = folder.trim_end_matches(['/', '\\']);
    if root.is_empty() {
        return false;
    }
    let cwd = cwd.trim_end_matches(['/', '\\']);
    cwd == root || cwd.starts_with(&format!("{root}/")) || cwd.starts_with(&format!("{root}\\"))
}

/// De dev-servers van een map: elke luisterende TCP-socket op deze computer, als het proces in die map werkt. Geen
/// netwerkverkeer: alleen de eigen tabellen van het systeem.
pub fn scan_dev_servers(folder: &str) -> Vec<DevServer> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};
    let root = folder.trim_end_matches(['/', '\\']);
    if root.is_empty() || root == "/" {
        return vec![];
    }
    let listeners = listening_sockets();
    if listeners.is_empty() {
        return vec![];
    }
    let Ok(mut system) = System::new() else { return vec![] };
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_cwd(UpdateKind::Always).with_cmd(UpdateKind::Always),
    );
    let mut commands = HashMap::new();
    let mut kept = vec![];
    for &(pid, port) in &listeners {
        let Some(p) = system.process(sysinfo::Pid::from_u32(pid)) else { continue };
        let Some(cwd) = p.cwd() else { continue };
        if !within(&cwd.to_string_lossy(), root) {
            continue;
        }
        commands.insert(pid, p.name().to_string_lossy().into_owned());
        kept.push((pid, port));
    }
    servers(&kept, &commands)
}

#[cfg(target_os = "linux")]
fn listening_sockets() -> Vec<(u32, u16)> {
    let mut inodes: HashMap<u64, u16> = HashMap::new();
    for file in ["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(text) = std::fs::read_to_string(file) {
            inodes.extend(parse_proc_net_tcp(&text));
        }
    }
    if inodes.is_empty() {
        return vec![];
    }
    let mut out = vec![];
    let Ok(procs) = std::fs::read_dir("/proc") else { return out };
    for entry in procs.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<u32>() else { continue };
        let Ok(fds) = std::fs::read_dir(entry.path().join("fd")) else { continue };
        for fd in fds.flatten() {
            let Ok(target) = std::fs::read_link(fd.path()) else { continue };
            let t = target.to_string_lossy();
            if let Some(inode) = t.strip_prefix("socket:[").and_then(|r| r.strip_suffix(']')).and_then(|n| n.parse::<u64>().ok()) {
                if let Some(&port) = inodes.get(&inode) {
                    out.push((pid, port));
                }
            }
        }
    }
    out
}

#[cfg(target_os = "windows")]
fn listening_sockets() -> Vec<(u32, u16)> {
    use std::os::windows::process::CommandExt;
    let Ok(output) = std::process::Command::new("netstat").args(["-ano", "-p", "TCP"]).creation_flags(0x0800_0000).output() else {
        return vec![];
    };
    parse_netstat(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
fn listening_sockets() -> Vec<(u32, u16)> {
    vec![]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launches() {
        let unix = shell_launch("/home/me/my app", Some("npm run dev"), Some("/bin/zsh"), false);
        assert_eq!(unix.program, "/bin/zsh");
        assert_eq!(unix.args[2], "cd '/home/me/my app' 2>/dev/null; npm run dev; exec /bin/zsh -l");
        let plain = shell_launch("/tmp", None, None, false);
        assert_eq!(plain.args[2], "cd /tmp 2>/dev/null; exec /bin/bash -l");
        let win = shell_launch("C:\\code", Some("npm test"), None, true);
        assert_eq!(win.program, "powershell.exe");
        assert_eq!(win.args, vec!["-NoLogo", "-NoExit", "-Command", "npm test"]);
        assert_eq!(win.directory, "C:\\code");
    }

    #[test]
    fn output_buffer_keeps_split_characters_and_strips_codes() {
        let mut b = OutputBuffer::default();
        let bytes = "héllo\n".as_bytes();
        assert_eq!(b.push(&bytes[..2]), "h");
        assert_eq!(b.push(&bytes[2..]), "éllo\n");
        b.push(b"\x1b[32mgreen\x1b[0m\r\nprogress 10%\rprogress 100%\n\x1b]0;title\x07done");
        assert_eq!(b.tail(10, 1000), "héllo\ngreen\nprogress 100%\ndone");
        assert_eq!(strip_ansi("ab\u{8}c"), "ac");
        let mut big = OutputBuffer::default();
        for _ in 0..1000 {
            big.push(&[b'x'; 1000]);
        }
        assert!(big.raw().len() <= OutputBuffer::LIMIT);
    }

    #[test]
    fn scripts() {
        let json = br#"{"scripts":[{"name":"Dev server","command":"pnpm dev","previewUrl":"http://localhost:5173","autoOpenPreview":true},
            {"id":"x","command":" "},{"command":"npm test"},{"id":"dev-server","command":"b"},{"previewUrl":"javascript:alert(1)","command":"c"}]}"#;
        let s = parse_scripts(json);
        assert_eq!(s.len(), 4);
        assert_eq!(s[0].id, "dev-server");
        assert_eq!(s[0].preview_url.as_deref(), Some("http://localhost:5173"));
        assert!(s[0].auto_open_preview);
        assert_eq!(s[1].name, "npm test");
        assert_eq!(s[2].id, "dev-server-3");
        assert!(s[3].preview_url.is_none());
        assert!(parse_scripts(b"nope").is_empty());

        let dir = std::env::temp_dir().join(format!("nook-scripts-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::write(dir.join("nook.json"), br#"{"scripts":[{"command":"make"}]}"#).unwrap();
        assert_eq!(load_scripts(&dir.join("sub").to_string_lossy())[0].command, "make");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dev_servers() {
        let tcp = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 00000000:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1\n   1: 0100007F:0016 00000000:0000 01 00000000:00000000 00:00000000 00000000  1000        0 99 1\n";
        assert_eq!(parse_proc_net_tcp(tcp), vec![(12345, 5173)]);
        let netstat = "\n  Proto  Local Address  Foreign Address  State  PID\n  TCP    0.0.0.0:3000   0.0.0.0:0  LISTENING  4242\n  TCP    [::]:3000  [::]:0  LISTENING  4242\n  TCP    127.0.0.1:5432  0.0.0.0:0  LISTENING  7\n  TCP    10.0.0.2:5555  1.2.3.4:443  ESTABLISHED  9\n";
        let l = parse_netstat(netstat);
        assert_eq!(l, vec![(4242, 3000), (4242, 3000), (7, 5432)]);
        let s = servers(&l, &HashMap::from([(4242, "node".to_string())]));
        assert_eq!(s, vec![DevServer { pid: 4242, command: "node".into(), port: 3000, url: "http://localhost:3000".into() }]);
        assert!(within("/p/app/web", "/p/app/"));
        assert!(within("C:\\p\\app\\web", "C:\\p\\app"));
        assert!(!within("/p/apple", "/p/app"));
        assert!(!within("/p", ""));
    }

    #[test]
    fn command_requests_expand_tilde_and_require_a_command() {
        assert_eq!(expand_tilde("~", "/home/alice"), "/home/alice");
        assert_eq!(expand_tilde(" ~/code ", "/home/alice"), "/home/alice/code");
        assert_eq!(expand_tilde("~\\code", "C:\\Users\\alice"), "C:\\Users\\alice\\code");
        assert_eq!(expand_tilde("/tmp/work", "/home/alice"), "/tmp/work");

        assert!(command_request("   ", "", "/home/alice").is_err());
        let default_dir = command_request("  git status  ", "", "/home/alice").unwrap();
        assert_eq!(default_dir, CommandRequest { command: "git status".into(), folder: "/home/alice".into(), title: "git status".into() });

        let long_cmd = "a".repeat(60);
        let long = command_request(&long_cmd, "~/proj", "/home/alice").unwrap();
        assert_eq!(long.folder, "/home/alice/proj");
        assert_eq!(long.title.chars().count(), 40);
    }

    #[test]
    fn setup_scripts_and_blocking_command() {
        let json = br#"{"scripts":[
            {"name":"Install","command":"pnpm install","runOnWorktreeCreate":true,"async":false},
            {"name":"Warm","command":"pnpm warm","runOnWorktreeCreate":true},
            {"name":"Dev","command":"pnpm dev","stopOnSettle":true,"runOnSettle":false}
        ]}"#;
        let all = parse_scripts(json);
        assert_eq!(all.len(), 3);
        assert!(!all[0].async_run);
        assert!(all[1].async_run);
        assert!(all[2].stop_on_settle);

        let (setup, holds) = setup_scripts(&all);
        assert_eq!(setup.len(), 2);
        assert!(holds);

        let (bg_only, holds_bg) = setup_scripts(&all[1..]);
        assert_eq!(bg_only.len(), 1);
        assert!(!holds_bg);

        assert_eq!(exit_status(None), None);
        assert_eq!(exit_status(Some(b"")), None);
        assert_eq!(exit_status(Some(b"0\n")), Some(0));
        assert_eq!(exit_status(Some(b" 42 ")), Some(42));

        let unix = blocking_command("echo hi && exit 7", "/tmp/status file", false);
        assert!(unix.starts_with("/bin/sh -c "));
        assert!(unix.ends_with(" && exit 0"));
        assert!(unix.contains("/tmp/status file"));

        let win = blocking_command("npm ci", r"C:\Temp\nook's-status", true);
        assert!(win.contains("npm ci"));
        assert!(win.contains("WriteAllText"));
        assert!(win.contains("nook''s-status"));
    }
}
