//! Sessions on another machine, over SSH (`RemoteMachines`, `RemoteLaunch` and `RemoteShell` on the Mac). The agent
//! runs there and speaks over the SSH connection exactly as it does here: Claude Code's stream-json, Codex's app-server
//! and ACP all use stdin and stdout. Only how to reach a machine is kept (`machines.json` in Nook's folder); keys stay
//! in `~/.ssh` and your ssh agent. Nothing here runs a process: it builds the command lines and checks the input.
//!
//! Not yet on Windows and Linux (the Mac has them, AG-132): machines that log in with a password, git over ssh (the
//! diff, snapshots per turn and worktrees there), and Nook's tools for the agent there (`RemoteBridge`).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::command::LaunchSpec;

/// A machine you can reach with `ssh`: an alias from `~/.ssh/config` or `user@host`, with a key from your ssh config,
/// your agent or a key file here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteMachine {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// A key file for this machine only (`~/.ssh/buildbox_ed25519`); `None` uses your ssh config and agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity_file: Option<String>,
    /// When a connection test passed or a session started there last.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<DateTime<Utc>>,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

impl RemoteMachine {
    /// A machine from what you typed: the host trimmed, the name from the host when you gave none, an empty key file
    /// dropped. `Err` with what is wrong, in your language.
    pub fn from_input(id: Option<String>, name: &str, host: &str, port: Option<u16>, identity_file: &str) -> Result<Self, String> {
        let host = host.trim();
        if !is_valid_host(host) {
            return Err(crate::i18n::tr(
                "Dat is geen adres voor ssh. Typ een alias uit je ssh-config of gebruiker@host.",
                "That is not an address for ssh. Type an alias from your ssh config or user@host.",
            )
            .into());
        }
        let key = identity_file.trim();
        if !key.is_empty() && !is_valid_identity_file(key) {
            return Err(crate::i18n::tr(
                "Een sleutelbestand begint met / of ~/ (bijvoorbeeld ~/.ssh/id_ed25519).",
                "A key file starts with / or ~/ (for example ~/.ssh/id_ed25519).",
            )
            .into());
        }
        let name = name.trim();
        Ok(Self {
            id: id.filter(|i| !i.trim().is_empty()).unwrap_or_else(new_id),
            name: if name.is_empty() { suggested_name(host) } else { name.into() },
            host: host.into(),
            port: port.filter(|p| *p != 0 && *p != 22),
            identity_file: (!key.is_empty()).then(|| key.into()),
            last_used_at: None,
        })
    }
}

/// Where a session runs on a remote machine. The folder is a path on that machine (`~/code/app` or `/srv/app`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoteTarget {
    pub machine_id: String,
    pub name: String,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity_file: Option<String>,
    pub directory: String,
}

impl RemoteTarget {
    pub fn new(machine: &RemoteMachine, directory: &str) -> Self {
        Self {
            machine_id: machine.id.clone(),
            name: machine.name.clone(),
            host: machine.host.clone(),
            port: machine.port,
            identity_file: machine.identity_file.clone(),
            directory: directory.trim().into(),
        }
    }
}

/// The saved machines, in the order you added them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct RemoteMachines {
    #[serde(default)]
    pub machines: Vec<RemoteMachine>,
}

impl RemoteMachines {
    pub fn file() -> PathBuf {
        crate::paths::support_directory().join("machines.json")
    }

    /// Machine by machine: one that cannot be read is left out; an unreadable file is copied aside first, so the next
    /// save never takes the others with it.
    pub fn load(file: &Path) -> Self {
        let Ok(bytes) = std::fs::read(file) else { return Self::default() };
        #[derive(Deserialize)]
        struct Stored {
            #[serde(default)]
            machines: Vec<serde_json::Value>,
        }
        match serde_json::from_slice::<Stored>(&bytes) {
            Ok(s) => Self { machines: s.machines.into_iter().filter_map(|v| serde_json::from_value(v).ok()).collect() },
            Err(_) => {
                let _ = std::fs::copy(file, file.with_extension("json.unreadable"));
                Self::default()
            }
        }
    }

    pub fn save_to(&self, file: &Path) -> std::io::Result<()> {
        crate::paths::write_atomic(file, &serde_json::to_vec_pretty(self).unwrap_or_default())
    }

    pub fn find(&self, id: &str) -> Option<&RemoteMachine> {
        self.machines.iter().find(|m| m.id == id)
    }

    /// Adds a machine, or changes the one with the same id where it is in the list (keeping when it was last used).
    pub fn upsert(&mut self, mut machine: RemoteMachine) {
        if let Some(existing) = self.machines.iter_mut().find(|m| m.id == machine.id) {
            machine.last_used_at = machine.last_used_at.or(existing.last_used_at);
            *existing = machine;
        } else {
            self.machines.push(machine);
        }
    }

    pub fn remove(&mut self, id: &str) {
        self.machines.retain(|m| m.id != id);
    }

    /// Notes that the machine answered: a connection test passed, or a session started there.
    pub fn mark_used(&mut self, id: &str, at: DateTime<Utc>) {
        if let Some(m) = self.machines.iter_mut().find(|m| m.id == id) {
            m.last_used_at = Some(at);
        }
    }
}

/// An ssh destination: an alias or `user@host`, never something ssh would read as an option.
pub fn is_valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 255
        && !host.starts_with('-')
        && host.chars().all(|c| c.is_ascii_alphanumeric() || "@.-_:[]".contains(c))
}

/// The name a machine gets from its address until you give it one: the host without the user and the domain
/// (`me@buildbox.local` → `buildbox`), or an IP address and an alias as they are.
pub fn suggested_name(host: &str) -> String {
    let bare = host.rsplit('@').next().unwrap_or(host);
    if bare.is_empty() {
        return String::new();
    }
    let is_address = bare.contains(':') || bare.split('.').all(|p| p.parse::<u32>().is_ok());
    if is_address {
        bare.into()
    } else {
        bare.split('.').next().unwrap_or(bare).into()
    }
}

/// A key file on this computer: absolute or from your home (`~/.ssh/id_buildbox`), one line.
pub fn is_valid_identity_file(path: &str) -> bool {
    let clean = path.trim();
    !clean.is_empty()
        && clean.len() <= 1024
        && !clean.contains('\n')
        && !clean.contains('\0')
        && (clean.starts_with('/') || clean.starts_with("~/") || is_windows_absolute(clean))
}

fn is_windows_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'\\' || bytes[2] == b'/')
}

/// A folder on the remote machine: absolute, or from its home (`~`, `~/code`).
pub fn is_valid_directory(path: &str) -> bool {
    let clean = path.trim();
    !clean.is_empty()
        && !clean.contains('\n')
        && !clean.contains('\0')
        && (clean.starts_with('/') || clean == "~" || clean.starts_with("~/"))
}

/// The ssh program: Windows' own OpenSSH client when it is there, else `ssh` on `PATH`.
pub fn ssh_program() -> String {
    #[cfg(windows)]
    {
        let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let own = Path::new(&root).join(r"System32\OpenSSH\ssh.exe");
        if own.exists() {
            return own.to_string_lossy().into_owned();
        }
    }
    "ssh".into()
}

/// A word for the remote POSIX shell, in single quotes (`CustomAgents.quote` on the Mac).
pub fn quote(word: &str) -> String {
    if !word.is_empty() && word.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:@,+%".contains(c)) {
        return word.into();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}

/// `~/code/app` stays relative to the remote home: the tilde unquoted, the rest quoted.
pub fn quoted_directory(path: &str) -> String {
    let clean = path.trim();
    if clean == "~" {
        return "~".into();
    }
    if let Some(rest) = clean.strip_prefix("~/") {
        return format!("~/{}", quote(rest));
    }
    quote(clean)
}

/// Without a password ssh never prompts (`BatchMode`), so a missing key fails at once instead of waiting for a prompt
/// nobody sees. The port and key file every call to a machine takes; with its own key file ssh offers only that key.
fn options(target: &RemoteTarget) -> Vec<String> {
    let mut out: Vec<String> = ["-T", "-o", "BatchMode=yes"].map(String::from).to_vec();
    if let Some(port) = target.port {
        out.extend(["-p".into(), port.to_string()]);
    }
    if let Some(key) = target.identity_file.as_deref().map(str::trim).filter(|k| is_valid_identity_file(k)) {
        out.extend(["-i".into(), key.into(), "-o".into(), "IdentitiesOnly=yes".into()]);
    }
    out
}

fn exports(environment: &BTreeMap<String, String>) -> String {
    environment
        .iter()
        .filter(|(k, _)| {
            let mut chars = k.chars();
            chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
        .map(|(k, v)| format!("export {k}={}; ", quote(v)))
        .collect()
}

/// The command line the remote side runs: its login shell, so the agent is found the way your terminal there finds it,
/// in the folder, with the agent's own name in place of a path on this computer.
pub fn command(program: &str, arguments: &[String], directory: &str, environment: &BTreeMap<String, String>) -> String {
    let agent = std::iter::once(program.to_string()).chain(arguments.iter().cloned()).map(|w| quote(&w)).collect::<Vec<_>>().join(" ");
    let inner = format!("{}cd {} && exec {agent}", exports(environment), quoted_directory(directory));
    format!(r#"exec "${{SHELL:-/bin/sh}}" -lc {}"#, quote(&inner))
}

/// Turns a launch on this computer into the same agent started on the remote machine:
/// `ssh -T … -- host 'exec "$SHELL" -lc "cd … && exec agent …"'`. `program` is the agent's command there (`claude`);
/// `environment` is what goes along (an account folder on this computer means nothing over there, so it stays here).
pub fn wrap(spec: LaunchSpec, target: &RemoteTarget, program: &str, environment: &BTreeMap<String, String>) -> LaunchSpec {
    let mut arguments = options(target);
    arguments.extend(["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4"].map(String::from));
    arguments.extend(["--".into(), target.host.clone(), command(program, &spec.arguments, &target.directory, environment)]);
    LaunchSpec {
        executable: ssh_program(),
        arguments,
        extra_environment: BTreeMap::new(),
        working_directory: dirs::home_dir().unwrap_or_else(std::env::temp_dir).to_string_lossy().into_owned(),
        initial_input: spec.initial_input,
        keeps_input_open: spec.keeps_input_open,
    }
}

/// The ssh arguments of the connection test: one login that also lists which of `commands` (the agents' programs) are
/// on the machine's `PATH`, the way a session's login shell would find them. Prints one found command per line.
pub fn check_arguments(target: &RemoteTarget, commands: &[&str]) -> Vec<String> {
    let names: Vec<&str> =
        commands.iter().copied().filter(|c| !c.is_empty() && c.chars().all(|x| x.is_ascii_alphanumeric() || "._-".contains(x))).collect();
    let script = if names.is_empty() {
        "true".to_string()
    } else {
        format!(r#"for c in {}; do command -v "$c" >/dev/null 2>&1 && printf '%s\n' "$c"; done; true"#, names.join(" "))
    };
    let mut arguments = options(target);
    arguments.extend(["-o", "ConnectTimeout=10"].map(String::from));
    arguments.extend(["--".into(), target.host.clone(), format!(r#"exec "${{SHELL:-/bin/sh}}" -lc {}"#, quote(&script))]);
    arguments
}

/// The ssh arguments that check the folder there and answer its full path (`cd … && pwd`): `~/code/app` becomes
/// `/home/me/code/app`, which Codex's app-server and ACP agents need as their folder.
pub fn folder_arguments(target: &RemoteTarget) -> Vec<String> {
    let mut arguments = options(target);
    arguments.extend(["-o", "ConnectTimeout=10"].map(String::from));
    let line = format!("cd {} && pwd", quoted_directory(&target.directory));
    arguments.extend(["--".into(), target.host.clone(), format!(r#"exec "${{SHELL:-/bin/sh}}" -lc {}"#, quote(&line))]);
    arguments
}

/// Runs ssh once with `arguments` and waits at most `timeout`: its output, or what went wrong in a line you can act
/// on. Blocks: call it off the interface's thread.
pub fn run_ssh(arguments: &[String], timeout: std::time::Duration) -> Result<String, String> {
    use std::io::Read;
    let mut cmd = std::process::Command::new(ssh_program());
    cmd.args(arguments).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd.spawn().map_err(|e| crate::i18n::trf("ssh starten lukte niet: {e}", "Could not start ssh: {e}", &[("e", &e)]))?;
    let started = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < timeout => std::thread::sleep(std::time::Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(crate::i18n::tr(
                    "De machine antwoordde niet op tijd. Kijk of hij aanstaat en of het adres klopt.",
                    "The machine did not answer in time. Check that it is on and that the address is right.",
                )
                .into());
            }
        }
    };
    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = out.read_to_string(&mut stdout);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = err.read_to_string(&mut stderr);
    }
    if status.success() {
        Ok(stdout)
    } else if status.code() == Some(255) || stderr.to_lowercase().contains("ssh:") || stderr.contains("Permission denied") {
        Err(explain_failure(&stderr))
    } else {
        // ssh got in; the command there failed (a folder that is not there, for one).
        Err(stderr.lines().map(str::trim).rfind(|l| !l.is_empty()).unwrap_or("").chars().take(300).collect())
    }
}

/// The commands from the test's output, in the order they were asked for.
pub fn found_agents(output: &str, asked: &[&str]) -> Vec<String> {
    let found: std::collections::HashSet<&str> = output.lines().map(str::trim).collect();
    asked.iter().filter(|c| found.contains(*c)).map(|c| c.to_string()).collect()
}

/// What ssh's error says in a line you can act on: no key let you in, the host key changed or is new, or the
/// machine could not be reached. Anything else is shown as ssh wrote it (its last line, shortened).
pub fn explain_failure(stderr: &str) -> String {
    let lower = stderr.to_lowercase();
    if lower.contains("permission denied") {
        return crate::i18n::tr(
            "Geen sleutel kwam binnen. Zet je sleutel in je ssh-agent of kies een sleutelbestand; inloggen met een wachtwoord kan hier nog niet.",
            "No key got in. Add your key to your ssh agent or choose a key file; logging in with a password is not available here yet.",
        )
        .into();
    }
    if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
        return crate::i18n::tr(
            "ssh kent deze machine nog niet (of zijn sleutel veranderde). Verbind één keer zelf met ssh in een terminal en probeer het opnieuw.",
            "ssh does not know this machine yet (or its key changed). Connect once yourself with ssh in a terminal and try again.",
        )
        .into();
    }
    if lower.contains("could not resolve hostname") || lower.contains("connection refused") || lower.contains("timed out") {
        return crate::i18n::tr(
            "De machine is niet bereikbaar. Kijk of hij aanstaat en of het adres klopt.",
            "The machine could not be reached. Check that it is on and that the address is right.",
        )
        .into();
    }
    let last = stderr.lines().map(str::trim).rfind(|l| !l.is_empty()).unwrap_or("");
    last.chars().take(300).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine() -> RemoteMachine {
        RemoteMachine::from_input(Some("m1".into()), "", "me@buildbox.local", Some(2222), "~/.ssh/buildbox").unwrap()
    }

    #[test]
    fn hosts_are_ssh_destinations_never_options() {
        assert!(is_valid_host("buildbox"));
        assert!(is_valid_host("me@10.0.0.4"));
        assert!(is_valid_host("me@[fe80::1]"));
        assert!(!is_valid_host("-oProxyCommand=calc"));
        assert!(!is_valid_host("me@host; rm -rf ~"));
        assert!(!is_valid_host(""));
    }

    #[test]
    fn names_come_from_the_host() {
        assert_eq!(suggested_name("me@buildbox.local"), "buildbox");
        assert_eq!(suggested_name("10.0.0.4"), "10.0.0.4");
        assert_eq!(suggested_name("devbox"), "devbox");
        let m = machine();
        assert_eq!(m.name, "buildbox");
        assert_eq!(m.port, Some(2222));
        assert_eq!(RemoteMachine::from_input(None, "x", "h", Some(22), "").unwrap().port, None, "the default port is not kept");
        assert!(RemoteMachine::from_input(None, "x", "h", None, "id_rsa").is_err(), "a key file is a full path");
    }

    #[test]
    fn folders_on_the_machine() {
        assert!(is_valid_directory("~"));
        assert!(is_valid_directory("~/code/app"));
        assert!(is_valid_directory("/srv/app"));
        assert!(!is_valid_directory("code/app"));
        assert!(!is_valid_directory(""));
        assert_eq!(quoted_directory("~/my app"), "~/'my app'");
        assert_eq!(quoted_directory("/srv/it's"), r"'/srv/it'\''s'");
    }

    #[test]
    fn wraps_the_agent_in_ssh() {
        let target = RemoteTarget::new(&machine(), "~/code/app");
        let spec = LaunchSpec {
            executable: r"C:\Users\me\AppData\Roaming\npm\claude.cmd".into(),
            arguments: vec!["-p".into(), "--output-format".into(), "stream-json".into()],
            extra_environment: [("CLAUDE_CONFIG_DIR".to_string(), r"C:\Users\me\.claude-work".to_string())].into(),
            working_directory: r"C:\code\app".into(),
            initial_input: vec!["{}\n".into()],
            keeps_input_open: true,
        };
        let wrapped = wrap(spec, &target, "claude", &BTreeMap::new());
        assert!(wrapped.executable.ends_with("ssh") || wrapped.executable.ends_with("ssh.exe"));
        assert!(wrapped.extra_environment.is_empty(), "this computer's account folder stays here");
        assert!(wrapped.keeps_input_open);
        assert_eq!(wrapped.initial_input, vec!["{}\n".to_string()]);
        let args = &wrapped.arguments;
        assert!(args.windows(2).any(|w| w == ["-p", "2222"]));
        assert!(args.windows(2).any(|w| w == ["-i", "~/.ssh/buildbox"]));
        assert!(args.windows(2).any(|w| w == ["-o", "BatchMode=yes"]));
        let dash = args.iter().position(|a| a == "--").unwrap();
        assert_eq!(args[dash + 1], "me@buildbox.local");
        assert_eq!(args.len(), dash + 3, "the remote command is one argument");
        let line = &args[dash + 2];
        assert!(line.starts_with(r#"exec "${SHELL:-/bin/sh}" -lc '"#));
        assert!(line.contains("cd ~/code/app && exec claude -p --output-format stream-json"));
        assert!(!line.contains("claude.cmd"));
    }

    #[test]
    fn exports_only_plain_names() {
        let env: BTreeMap<String, String> =
            [("GOOD_NAME".to_string(), "a b".to_string()), ("bad;name".to_string(), "x".to_string())].into();
        let line = command("agy", &[], "~", &env);
        assert!(line.contains("GOOD_NAME="));
        assert!(!line.contains("bad;name"));
    }

    #[test]
    fn the_test_lists_the_agents_found() {
        let target = RemoteTarget::new(&machine(), "~");
        let args = check_arguments(&target, &["claude", "codex", "evil;cmd"]);
        let last = args.last().unwrap();
        assert!(last.contains("for c in claude codex;"));
        assert!(!last.contains("evil"));
        assert_eq!(found_agents("codex\nclaude\n", &["claude", "codex", "gemini"]), vec!["claude", "codex"]);
    }

    #[test]
    fn keeps_machines_and_survives_a_bad_one() {
        let dir = std::env::temp_dir().join(format!("nook-machines-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("machines.json");
        let mut list = RemoteMachines::default();
        list.upsert(machine());
        list.mark_used("m1", Utc::now());
        list.save_to(&file).unwrap();
        let mut loaded = RemoteMachines::load(&file);
        assert_eq!(loaded.machines.len(), 1);
        assert!(loaded.machines[0].last_used_at.is_some());
        let mut changed = machine();
        changed.name = "Build box".into();
        loaded.upsert(changed);
        assert_eq!(loaded.machines.len(), 1);
        assert_eq!(loaded.machines[0].name, "Build box");
        assert!(loaded.machines[0].last_used_at.is_some(), "an edit keeps when it was last used");
        std::fs::write(&file, r#"{"machines":[{"name":"ok","host":"h"},{"bad":true}]}"#).unwrap();
        let loaded = RemoteMachines::load(&file);
        assert_eq!(loaded.machines.len(), 1);
        assert!(!loaded.machines[0].id.is_empty(), "a missing id gets a new one");
        loaded.find(&loaded.machines[0].id).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn explains_what_ssh_said() {
        assert!(explain_failure("me@h: Permission denied (publickey).").contains("key"));
        assert!(explain_failure("ssh: Could not resolve hostname nope").contains("reached"));
        assert_eq!(explain_failure("weird\nlast line\n"), "last line");
    }
}
