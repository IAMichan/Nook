//! Machines you can probably reach, offered when you add one (`RemoteHostDiscovery` on the Mac): the aliases in
//! `~/.ssh/config`, the hosts in `~/.ssh/known_hosts`, and the online devices of your tailnet (`tailscale status
//! --json`, by their MagicDNS name). Nothing is contacted to find them; picking one only fills in the form.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use serde::Serialize;

use super::remote::{is_valid_host, RemoteMachine};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    SshConfig,
    KnownHosts,
    Tailscale,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub name: String,
    pub host: String,
    pub port: Option<u16>,
    pub source: Source,
    /// What else is known: `ubuntu@10.0.0.4` from the config, `linux` from the tailnet.
    pub detail: Option<String>,
}

fn is_pattern(host: &str) -> bool {
    host.contains('*') || host.contains('?') || host.starts_with('!')
}

/// `Key value`, `Key=value` and `Key = value` are all valid.
fn key_value(line: &str) -> (String, String) {
    let is_sep = |c: char| c.is_whitespace() || c == '=';
    match line.find(is_sep) {
        None => (line.to_lowercase(), String::new()),
        Some(i) => {
            let value = line[i..].trim_matches(is_sep).trim_matches('"');
            (line[..i].to_lowercase(), value.to_string())
        }
    }
}

/// Each concrete `Host` alias (no wildcards or negations), with its `HostName` and `User` as detail. `Include` lines
/// are followed through `include`, which gives the text of the files a pattern names; ssh stops at 16 levels, so does this.
pub fn ssh_config(text: &str, include: &dyn Fn(&str) -> Vec<String>, depth: usize) -> Vec<Suggestion> {
    let mut result = vec![];
    let mut aliases: Vec<String> = vec![];
    let mut host_name: Option<String> = None;
    let mut user: Option<String> = None;
    let flush = |aliases: &mut Vec<String>, host_name: &mut Option<String>, user: &mut Option<String>, result: &mut Vec<Suggestion>| {
        let target = [user.as_deref(), host_name.as_deref()].into_iter().flatten().collect::<Vec<_>>().join("@");
        for alias in aliases.drain(..) {
            result.push(Suggestion {
                name: alias.clone(),
                host: alias,
                port: None,
                source: Source::SshConfig,
                detail: (!target.is_empty()).then(|| target.clone()),
            });
        }
        *host_name = None;
        *user = None;
    };
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = key_value(line);
        match key.as_str() {
            "host" => {
                flush(&mut aliases, &mut host_name, &mut user, &mut result);
                aliases = value.split_whitespace().filter(|a| !is_pattern(a) && is_valid_host(a)).map(String::from).collect();
            }
            "match" => flush(&mut aliases, &mut host_name, &mut user, &mut result),
            "include" if depth < 16 => {
                for pattern in value.split_whitespace() {
                    for file in include(pattern) {
                        result.extend(ssh_config(&file, include, depth + 1));
                    }
                }
            }
            "hostname" => host_name = Some(value),
            "user" => user = Some(value),
            _ => {}
        }
    }
    flush(&mut aliases, &mut host_name, &mut user, &mut result);
    result
}

/// `*` and `?` as in a shell glob, for one file name.
pub fn matches(name: &str, pattern: &str) -> bool {
    fn go(n: &[char], p: &[char]) -> bool {
        match p.first() {
            None => n.is_empty(),
            Some('*') => (0..=n.len()).any(|i| go(&n[i..], &p[1..])),
            Some('?') => !n.is_empty() && go(&n[1..], &p[1..]),
            Some(c) => n.first() == Some(c) && go(&n[1..], &p[1..]),
        }
    }
    go(&name.chars().collect::<Vec<_>>(), &pattern.chars().collect::<Vec<_>>())
}

/// The files an `Include` pattern names, as ssh finds them: from your home with `~/`, from `~/.ssh` when relative, with
/// `*` and `?` expanded in the last part, in sorted order.
pub fn included_files(pattern: &str, ssh_directory: &Path, home: &Path) -> Vec<PathBuf> {
    let path = if let Some(rest) = pattern.strip_prefix("~/") {
        home.join(rest)
    } else if Path::new(pattern).is_absolute() {
        PathBuf::from(pattern)
    } else {
        ssh_directory.join(pattern)
    };
    let text = path.to_string_lossy();
    if !text.contains('*') && !text.contains('?') {
        return vec![path];
    }
    let (Some(folder), Some(name)) = (path.parent(), path.file_name().map(|n| n.to_string_lossy().into_owned())) else { return vec![] };
    if folder.to_string_lossy().contains(['*', '?']) {
        return vec![];
    }
    let Ok(entries) = std::fs::read_dir(folder) else { return vec![] };
    let mut names: Vec<String> = entries
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.') && matches(n, &name))
        .collect();
    names.sort();
    names.into_iter().map(|n| folder.join(n)).collect()
}

/// Git hosts ssh knows from pushing and pulling: never a machine to run an agent on.
const FORGES: [&str; 10] = [
    "github.com",
    "gitlab.com",
    "bitbucket.org",
    "ssh.dev.azure.com",
    "vs-ssh.visualstudio.com",
    "codeberg.org",
    "git.sr.ht",
    "heroku.com",
    "ssh.github.com",
    "altssh.gitlab.com",
];

/// The hosts ssh has connected to before. Hashed entries (`|1|…`) cannot be read back and are skipped; `[host]:2222`
/// keeps its port.
pub fn known_hosts(text: &str) -> Vec<Suggestion> {
    let mut seen = HashSet::new();
    let mut result = vec![];
    for raw in text.lines() {
        let mut line = raw.trim().to_string();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('@') {
            line = line.split_once(' ').map(|(_, rest)| rest.to_string()).unwrap_or_default();
        }
        let Some(field) = line.split_whitespace().next().filter(|f| !f.starts_with('|')) else { continue };
        for entry in field.split(',') {
            let (host, port) = match entry.strip_prefix('[').and_then(|r| r.split_once(']')) {
                Some((h, rest)) => (h.to_string(), rest.strip_prefix(':').and_then(|p| p.parse::<u16>().ok())),
                None => (entry.to_string(), None),
            };
            if is_pattern(&host) || !is_valid_host(&host) || FORGES.contains(&host.to_lowercase().as_str()) {
                continue;
            }
            if !seen.insert(format!("{host}:{}", port.unwrap_or(22))) {
                continue;
            }
            result.push(Suggestion { name: host.clone(), host, port: port.filter(|p| *p != 22), source: Source::KnownHosts, detail: None });
        }
    }
    result
}

/// The other online devices of your tailnet, by MagicDNS name. This computer itself and offline devices are left out.
pub fn tailscale(json: &str) -> Vec<Suggestion> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json) else { return vec![] };
    let Some(peers) = value.get("Peer").and_then(|p| p.as_object()) else { return vec![] };
    let mut out: Vec<Suggestion> = peers
        .values()
        .filter(|p| p.get("Online").and_then(|o| o.as_bool()) == Some(true))
        .filter_map(|p| {
            let dns = p.get("DNSName").and_then(|d| d.as_str()).unwrap_or("").trim_end_matches('.').to_string();
            let ip = p.get("TailscaleIPs").and_then(|i| i.as_array()).and_then(|a| a.first()).and_then(|i| i.as_str()).map(String::from);
            let host = if dns.is_empty() { ip? } else { dns };
            if !is_valid_host(&host) {
                return None;
            }
            let name =
                p.get("HostName").and_then(|h| h.as_str()).filter(|h| !h.is_empty()).map(String::from).unwrap_or_else(|| host.clone());
            Some(Suggestion {
                name,
                host,
                port: None,
                source: Source::Tailscale,
                detail: p.get("OS").and_then(|o| o.as_str()).map(String::from),
            })
        })
        .collect();
    out.sort_by_key(|s| s.name.to_lowercase());
    out
}

fn key(host: &str, port: Option<u16>) -> String {
    let bare = host.rsplit('@').next().unwrap_or(host);
    format!("{}:{}", bare.to_lowercase(), port.unwrap_or(22))
}

/// All suggestions without duplicates (the tailnet first, then your config, then known hosts) and without the machines
/// you already added.
pub fn merge(
    tailscale: Vec<Suggestion>,
    ssh_config: Vec<Suggestion>,
    known_hosts: Vec<Suggestion>,
    existing: &[RemoteMachine],
) -> Vec<Suggestion> {
    let mut taken: HashSet<String> = existing.iter().map(|m| key(&m.host, m.port)).collect();
    tailscale.into_iter().chain(ssh_config).chain(known_hosts).filter(|s| taken.insert(key(&s.host, s.port))).collect()
}

/// Reads this computer's ssh files and tailnet. Blocks briefly (the `tailscale` program, at most a few seconds).
pub fn discover(existing: &[RemoteMachine]) -> Vec<Suggestion> {
    let home = dirs::home_dir().unwrap_or_default();
    let ssh = home.join(".ssh");
    let read = |p: &Path| std::fs::read_to_string(p).unwrap_or_default();
    let include = |pattern: &str| included_files(pattern, &ssh, &home).iter().map(|p| read(p)).collect::<Vec<_>>();
    let config = ssh_config(&read(&ssh.join("config")), &include, 0);
    let known = known_hosts(&read(&ssh.join("known_hosts")));
    merge(tailscale(&tailscale_status()), config, known, existing)
}

fn tailscale_status() -> String {
    let mut cmd = std::process::Command::new("tailscale");
    cmd.args(["status", "--json"]).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let Ok(child) = cmd.stdout(std::process::Stdio::piped()).spawn() else { return String::new() };
    let started = std::time::Instant::now();
    let mut child = child;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < std::time::Duration::from_secs(4) => std::thread::sleep(std::time::Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return String::new();
            }
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        use std::io::Read;
        let _ = stdout.read_to_string(&mut out);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_aliases_without_patterns() {
        let config = "Host *\n  ServerAliveInterval 30\nHost buildbox devbox\n  HostName 10.0.0.4\n  User ubuntu\nHost !nope *.corp\nMatch host x\nHost=pi\n";
        let found = ssh_config(config, &|_| vec![], 0);
        assert_eq!(found.iter().map(|s| s.host.as_str()).collect::<Vec<_>>(), vec!["buildbox", "devbox", "pi"]);
        assert_eq!(found[0].detail.as_deref(), Some("ubuntu@10.0.0.4"));
        assert_eq!(found[2].detail, None);
    }

    #[test]
    fn includes_are_followed() {
        let found =
            ssh_config("Include config.d/*\nHost main\n", &|p| if p == "config.d/*" { vec!["Host inner\n".into()] } else { vec![] }, 0);
        assert_eq!(found.iter().map(|s| s.host.as_str()).collect::<Vec<_>>(), vec!["inner", "main"]);
        assert!(matches("work.conf", "*.conf"));
        assert!(matches("a1", "a?"));
        assert!(!matches("a12", "a?"));
    }

    #[test]
    fn known_hosts_skip_hashes_and_forges() {
        let text = "github.com ssh-ed25519 AAA\n|1|abc= ssh-rsa AAA\n[box.local]:2222,10.0.0.9 ssh-ed25519 AAA\n@cert-authority *.corp ssh-rsa AAA\nbox.local ssh-rsa A\n";
        let found = known_hosts(text);
        assert_eq!(
            found.iter().map(|s| (s.host.as_str(), s.port)).collect::<Vec<_>>(),
            vec![("box.local", Some(2222)), ("10.0.0.9", None), ("box.local", None)]
        );
    }

    #[test]
    fn tailnet_peers_that_are_online() {
        let json = r#"{"Peer":{"a":{"Online":true,"DNSName":"box.tail1.ts.net.","HostName":"box","OS":"linux"},"b":{"Online":false,"DNSName":"off.ts.net."}}}"#;
        let found = tailscale(json);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].host, "box.tail1.ts.net");
        assert_eq!(found[0].detail.as_deref(), Some("linux"));
    }

    #[test]
    fn merge_drops_duplicates_and_added_machines() {
        let s = |h: &str, src| Suggestion { name: h.into(), host: h.into(), port: None, source: src, detail: None };
        let existing = vec![RemoteMachine::from_input(None, "", "me@added", None, "").unwrap()];
        let merged = merge(
            vec![s("box", Source::Tailscale)],
            vec![s("box", Source::SshConfig), s("added", Source::SshConfig)],
            vec![s("pi", Source::KnownHosts)],
            &existing,
        );
        assert_eq!(
            merged.iter().map(|m| (m.host.as_str(), m.source)).collect::<Vec<_>>(),
            vec![("box", Source::Tailscale), ("pi", Source::KnownHosts)]
        );
    }
}
