//! Starts a local brain that is installed but not running. "Ollama draait niet" was the most common first error: the
//! model is there, only the server is not. Nook now starts it itself, quietly, at launch and from the error's button.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

/// What happened when Nook tried to start the local brain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    /// It was already answering.
    AlreadyRunning,
    /// Nook started it and it answers now.
    Started,
    /// It is not installed on this computer (or Nook can not find it).
    NotInstalled,
    /// It was started but did not answer in time.
    NoAnswer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Server {
    Ollama,
    LmStudio,
}

impl Server {
    fn health_url(self) -> &'static str {
        match self {
            Self::Ollama => "http://127.0.0.1:11434/api/tags",
            Self::LmStudio => "http://127.0.0.1:1234/v1/models",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        match name.to_lowercase().replace(' ', "").as_str() {
            "ollama" => Some(Self::Ollama),
            "lmstudio" => Some(Self::LmStudio),
            _ => None,
        }
    }
}

pub async fn answers(server: Server) -> bool {
    let Ok(client) = reqwest::Client::builder().timeout(Duration::from_millis(1500)).build() else { return false };
    client.get(server.health_url()).send().await.is_ok_and(|r| r.status().is_success())
}

/// Starts `server` if it is installed and not answering, and waits up to 15 seconds for it.
pub async fn ensure_running(server: Server) -> Outcome {
    if answers(server).await {
        return Outcome::AlreadyRunning;
    }
    let Some(program) = find(server) else { return Outcome::NotInstalled };
    let mut command = Command::new(&program);
    match server {
        Server::Ollama => command.arg("serve"),
        Server::LmStudio => command.args(["server", "start"]),
    };
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No console window, and the server keeps running on its own when Nook stops.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        command.creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS);
    }
    if let Err(e) = command.spawn() {
        log::warn!("{} could not start: {e}", program.display());
        return Outcome::NoAnswer;
    }
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if answers(server).await {
            log::info!("Started {}", program.display());
            return Outcome::Started;
        }
    }
    Outcome::NoAnswer
}

/// Where the program is: on the PATH, or where its installer puts it.
fn find(server: Server) -> Option<PathBuf> {
    let name = match server {
        Server::Ollama => "ollama",
        Server::LmStudio => "lms",
    };
    let exe = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    let on_path = std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|d| d.join(&exe)).find(|p| p.is_file()));
    on_path.or_else(|| candidates(server, &exe).into_iter().find(|p| p.is_file()))
}

fn candidates(server: Server, exe: &str) -> Vec<PathBuf> {
    let mut out = vec![];
    let home = dirs::home_dir();
    match server {
        Server::Ollama => {
            if let Some(local) = dirs::data_local_dir() {
                out.push(local.join("Programs").join("Ollama").join(exe));
            }
            out.push(PathBuf::from("/usr/local/bin").join(exe));
            out.push(PathBuf::from("/usr/bin").join(exe));
        }
        Server::LmStudio => {
            if let Some(home) = &home {
                out.push(home.join(".lmstudio").join("bin").join(exe));
                out.push(home.join(".cache").join("lm-studio").join("bin").join(exe));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knows_the_servers_by_their_display_name() {
        assert_eq!(Server::from_name("Ollama"), Some(Server::Ollama));
        assert_eq!(Server::from_name("LM Studio"), Some(Server::LmStudio));
        assert_eq!(Server::from_name("Claude"), None);
    }
}
