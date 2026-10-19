//! Lokale modellen: wat Ollama en LM Studio nu aanbieden, en een model bij Ollama installeren met één klik
//! (`POST /api/pull`), met voortgang per byte over alle lagen samen.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::StreamExt;
use serde::Serialize;
use serde_json::{json, Value};

use super::conversations::ollama_base_url;
use super::http::lines;
use super::profile::{Server, ServerModel};
use crate::provider::AIProvider;
use crate::{NookError, Result};

/// De modellen die Ollama en LM Studio nu draaien (leeg als ze niet draaien). Wacht hoogstens anderhalve seconde.
pub async fn server_models() -> Vec<ServerModel> {
    let client = reqwest::Client::builder().timeout(Duration::from_millis(1_500)).build().unwrap_or_default();
    let fetch = |url: String, server: Server| {
        let client = client.clone();
        async move {
            let Ok(response) = client.get(url).send().await else { return vec![] };
            if response.status().as_u16() != 200 {
                return vec![];
            }
            let object: Value = response.json().await.unwrap_or_default();
            object
                .get("models")
                .or_else(|| object.get("data"))
                .and_then(|v| v.as_array())
                .into_iter()
                .flatten()
                .filter_map(|m| m.get("name").or_else(|| m.get("id")).and_then(|v| v.as_str()))
                .filter(|name| AIProvider::is_chat_model(name))
                .map(|name| ServerModel { server: server.clone(), name: name.to_string() })
                .collect::<Vec<_>>()
        }
    };
    let (ollama, lmstudio) = tokio::join!(
        fetch(format!("{}/api/tags", ollama_base_url()), Server::Ollama),
        fetch(format!("{}/models", AIProvider::Lmstudio.base_url()), Server::Lmstudio)
    );
    ollama.into_iter().chain(lmstudio).collect()
}

/// Hoe ver een download is.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PullProgress {
    pub model: String,
    pub status: String,
    /// 0…1, of niets zolang Ollama de grootte nog niet weet.
    pub fraction: Option<f64>,
    pub done: bool,
    pub error: Option<String>,
}

/// Telt de bytes van alle lagen op.
#[derive(Default)]
pub struct Tally {
    layers: HashMap<String, (u64, u64)>,
}

impl Tally {
    /// Verwerkt één regel van Ollama en geeft de stand terug.
    pub fn feed(&mut self, model: &str, line: &Value) -> PullProgress {
        if let Some(error) = line["error"].as_str() {
            return PullProgress {
                model: model.into(),
                status: String::new(),
                fraction: None,
                done: true,
                error: Some(pull_error(model, error)),
            };
        }
        let status = line["status"].as_str().unwrap_or("").to_string();
        if let (Some(digest), Some(total)) = (line["digest"].as_str(), line["total"].as_u64()) {
            let completed = line["completed"].as_u64().unwrap_or(0);
            self.layers.insert(digest.into(), (completed.min(total), total));
        }
        let (completed, total) = self.layers.values().fold((0u64, 0u64), |a, l| (a.0 + l.0, a.1 + l.1));
        let done = status == "success";
        let fraction = if done { Some(1.0) } else { (total > 0).then(|| completed as f64 / total as f64) };
        PullProgress { model: model.into(), status: status_text(&status), fraction, done, error: None }
    }
}

fn status_text(status: &str) -> String {
    match status {
        "pulling manifest" => "Voorbereiden…".into(),
        "verifying sha256 digest" => "Controleren…".into(),
        "writing manifest" | "removing any unused layers" => "Afronden…".into(),
        "success" => "Klaar".into(),
        s if s.starts_with("pulling") || s.starts_with("downloading") => "Downloaden…".into(),
        other => other.to_string(),
    }
}

fn pull_error(model: &str, error: &str) -> String {
    let lower = error.to_lowercase();
    if lower.contains("not found") || lower.contains("does not exist") || lower.contains("manifest unknown") {
        format!("Ollama kent het model {model} niet. Kies een ander model bij Instellingen › Brein.")
    } else if lower.contains("space") || lower.contains("disk") {
        format!("Er is niet genoeg schijfruimte voor {model}.")
    } else {
        format!("Ollama: {error}")
    }
}

/// Installeert een model bij Ollama. `progress` krijgt de stand, hoogstens tien keer per seconde.
pub async fn pull(model: &str, progress: &(dyn Fn(PullProgress) + Send + Sync)) -> Result<()> {
    let client = reqwest::Client::builder().connect_timeout(Duration::from_secs(5)).build()?;
    let response =
        client.post(format!("{}/api/pull", ollama_base_url())).json(&json!({"model": model, "stream": true})).send().await.map_err(
            |e| {
                if e.is_connect() {
                    NookError::new("Ollama draait niet. Installeer en start Ollama, en probeer het opnieuw.")
                } else {
                    NookError(e.to_string())
                }
            },
        )?;
    if !response.status().is_success() {
        let object: Value = response.json().await.unwrap_or_default();
        return Err(NookError(pull_error(model, object["error"].as_str().unwrap_or("onbekende fout"))));
    }
    let mut stream = Box::pin(lines(response.bytes_stream().map(|r| r.map_err(NookError::from))));
    let mut tally = Tally::default();
    let mut last = std::time::Instant::now() - Duration::from_secs(1);
    while let Some(line) = stream.next().await {
        let line = line?;
        let Ok(object) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let state = tally.feed(model, &object);
        if let Some(error) = state.error.clone() {
            progress(state);
            return Err(NookError(error));
        }
        let done = state.done;
        if done || last.elapsed() >= Duration::from_millis(100) {
            last = std::time::Instant::now();
            progress(state);
        }
        if done {
            return Ok(());
        }
    }
    Err(NookError::new("De download stopte voor hij klaar was. Probeer het opnieuw; wat er al is, blijft staan."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_adds_up_all_layers() {
        let mut tally = Tally::default();
        assert_eq!(tally.feed("m", &json!({"status": "pulling manifest"})).fraction, None);
        tally.feed("m", &json!({"status": "pulling a", "digest": "a", "total": 100, "completed": 50}));
        let state = tally.feed("m", &json!({"status": "pulling b", "digest": "b", "total": 100, "completed": 0}));
        assert_eq!(state.fraction, Some(0.25));
        assert_eq!(state.status, "Downloaden…");
        assert!(tally.feed("m", &json!({"status": "success"})).done);
        let failed = Tally::default().feed("x:1b", &json!({"error": "pull model manifest: file does not exist"}));
        assert!(failed.error.unwrap().contains("kent het model x:1b niet"));
    }
}
