//! Spraak naar tekst via een externe dienst die de gebruiker zelf koos (OpenAI of Groq, `audio/transcriptions`), en
//! het lezen van wat whisper.cpp lokaal schrijft. Woorden komen terug met hun tijd, voor de Notetaker.

use serde_json::Value;

use super::audio;
use super::notes::TimedWord;
use super::prefs::SpeechEngine;
use crate::provider::AIProvider;
use crate::{nook_err, Result};

/// Adres, model en sleutel-dienst van een externe herkenning.
pub fn endpoint(engine: SpeechEngine) -> Option<(&'static str, &'static str, AIProvider)> {
    match engine {
        SpeechEngine::Openai => Some(("https://api.openai.com/v1/audio/transcriptions", "whisper-1", AIProvider::Openai)),
        SpeechEngine::Groq => Some(("https://api.groq.com/openai/v1/audio/transcriptions", "whisper-large-v3-turbo", AIProvider::Groq)),
        SpeechEngine::Local | SpeechEngine::Windows => None,
    }
}

/// Een multipart-formulier met het geluid en de velden (zonder extra afhankelijkheid).
pub fn multipart(boundary: &str, fields: &[(&str, &str)], wav: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    for (name, value) in fields {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"nook.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// Tekst en woorden uit een `verbose_json`-antwoord. Zonder woordtijden krijgen de segmenten hun tijd.
pub fn parse_verbose(json: &Value, offset: f64) -> (String, Vec<TimedWord>) {
    let text = json.get("text").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let timed = |items: &Value, key: &str| -> Vec<TimedWord> {
        items
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|w| {
                let word = w.get(key)?.as_str()?.trim();
                let start = w.get("start")?.as_f64()?;
                let end = w.get("end")?.as_f64()?;
                (!word.is_empty()).then(|| TimedWord { text: word.into(), start: offset + start, end: offset + end.max(start + 0.05) })
            })
            .collect()
    };
    let mut words = json.get("words").map(|w| timed(w, "word")).unwrap_or_default();
    if words.is_empty() {
        words = json.get("segments").map(|s| timed(s, "text")).unwrap_or_default();
    }
    (text, words)
}

/// Stuurt 16 kHz mono naar de gekozen dienst. `language` is een tweelettercode of leeg.
pub async fn remote(engine: SpeechEngine, key: &str, samples: &[f32], language: &str, offset: f64) -> Result<(String, Vec<TimedWord>)> {
    let Some((url, model, _)) = endpoint(engine) else { return Err(nook_err!("Geen externe spraakherkenning gekozen.")) };
    let wav = audio::wav(samples, 16_000);
    let boundary = format!("nook{}", uuid::Uuid::new_v4().simple());
    let mut fields = vec![("model", model), ("response_format", "verbose_json"), ("timestamp_granularities[]", "word")];
    if engine == SpeechEngine::Openai {
        fields.push(("timestamp_granularities[]", "segment"));
    }
    if language.len() == 2 {
        fields.push(("language", language));
    }
    let body = multipart(&boundary, &fields, &wav);
    let response = reqwest::Client::new()
        .post(url)
        .bearer_auth(key)
        .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
        .timeout(std::time::Duration::from_secs(90))
        .body(body)
        .send()
        .await?;
    let status = response.status();
    let json: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let message = json.pointer("/error/message").and_then(Value::as_str).unwrap_or("onbekende fout");
        return Err(nook_err!("De spraakherkenning gaf een fout ({status}): {message}"));
    }
    Ok(parse_verbose(&json, offset))
}

/// De JSON die `whisper-cli -oj` schrijft: `transcription` met `offsets` in milliseconden.
pub fn parse_whisper_cpp(json: &Value, offset: f64) -> (String, Vec<TimedWord>) {
    let mut words = Vec::new();
    let mut text = Vec::new();
    for segment in json.get("transcription").and_then(Value::as_array).into_iter().flatten() {
        let piece = segment.get("text").and_then(Value::as_str).unwrap_or("").trim();
        if piece.is_empty() {
            continue;
        }
        text.push(piece.to_string());
        let from = segment.pointer("/offsets/from").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        let to = segment.pointer("/offsets/to").and_then(Value::as_f64).unwrap_or(0.0) / 1000.0;
        // Per segment de woorden gelijk verdeeld over de tijd: genoeg voor regels in het transcript.
        let parts: Vec<&str> = piece.split_whitespace().collect();
        let step = ((to - from) / parts.len().max(1) as f64).max(0.05);
        for (i, part) in parts.iter().enumerate() {
            let start = offset + from + i as f64 * step;
            words.push(TimedWord { text: (*part).into(), start, end: start + step * 0.9 });
        }
    }
    (text.join(" "), words)
}

/// De taal voor de herkenning: de antwoordtaal, of bij "auto" de taal van de interface.
pub fn language_code(answer: &str, app: &str) -> String {
    if let Some(code) = super::dictation_lang::fixed(answer) {
        return code.to_string();
    }
    let code = if answer == "auto" { app } else { answer };
    if let Some(mapped) = super::dictation_lang::code_of(code) {
        mapped.to_string()
    } else if code.len() == 2 {
        code.into()
    } else {
        "nl".into()
    }
}

/// Extracts the detected language code from an OpenAI/Groq `verbose_json` response or a `whisper.cpp` JSON output (`SV-47`).
pub fn detected_language(json: &Value) -> Option<&'static str> {
    let raw = json.get("language").and_then(Value::as_str).or_else(|| json.pointer("/result/language").and_then(Value::as_str))?;
    super::dictation_lang::code_of(raw)
}

/// Builds CLI arguments for local `whisper-cli` (`whisper.cpp`), wiring `dictation_lang` (`-l auto` or fixed code, `SV-47`)
/// and `dictation_context` (`--prompt`, `SV-49`).
pub fn whisper_cli_args(model_path: &str, wav_path: &str, language_setting: &str, prompt_hint: &str) -> Vec<String> {
    let lang = super::dictation_lang::fixed(language_setting).unwrap_or(super::dictation_lang::AUTOMATIC);
    let mut args = vec![
        "-m".to_string(),
        model_path.to_string(),
        "-f".to_string(),
        wav_path.to_string(),
        "-l".to_string(),
        lang.to_string(),
        "-oj".to_string(),
    ];
    let trimmed = prompt_hint.trim();
    if !trimmed.is_empty() {
        args.push("--prompt".to_string());
        args.push(trimmed.to_string());
    }
    args
}

/// Stuurt 16 kHz mono naar OpenAI of Groq met optionele `prompt` (`SV-49`) en automatische taalherkenning (`SV-47`).
pub async fn remote_with_prompt(
    engine: SpeechEngine,
    key: &str,
    samples: &[f32],
    language_setting: &str,
    prompt_hint: Option<&str>,
    offset: f64,
) -> Result<(String, Vec<TimedWord>, Option<&'static str>)> {
    let Some((url, model, _)) = endpoint(engine) else {
        return Err(nook_err!("Geen externe spraakherkenning gekozen."));
    };
    let wav = audio::wav(samples, 16_000);
    let boundary = format!("nook{}", uuid::Uuid::new_v4().simple());
    let mut fields = vec![("model", model), ("response_format", "verbose_json"), ("timestamp_granularities[]", "word")];
    if engine == SpeechEngine::Openai {
        fields.push(("timestamp_granularities[]", "segment"));
    }
    if let Some(fixed_lang) = super::dictation_lang::fixed(language_setting) {
        fields.push(("language", fixed_lang));
    }
    let prompt_clean = prompt_hint.map(str::trim).filter(|p| !p.is_empty());
    if let Some(p) = prompt_clean {
        fields.push(("prompt", p));
    }
    let body = multipart(&boundary, &fields, &wav);
    let response = reqwest::Client::new()
        .post(url)
        .bearer_auth(key)
        .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
        .timeout(std::time::Duration::from_secs(90))
        .body(body)
        .send()
        .await?;
    let status = response.status();
    let json: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        let message = json.pointer("/error/message").and_then(Value::as_str).unwrap_or("unknown error");
        return Err(nook_err!(
            "{}",
            crate::i18n::trf(
                "De spraakherkenning gaf een fout ({status}): {message}",
                "Speech recognition returned an error ({status}): {message}",
                &[("status", &status), ("message", &message)],
            )
        ));
    }
    let heard_lang = detected_language(&json);
    let (text, words) = parse_verbose(&json, offset);
    Ok((text, words, heard_lang))
}

// ── SV-48: Parakeet & Local Speech Model Catalog + Hugging Face Cache Scanner ──

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LocalModelRuntime {
    /// `whisper.cpp` GGML / GGUF model.
    WhisperCpp,
    /// NVIDIA Parakeet TDT transducer via `sherpa-onnx` / ONNX Runtime (`SV-48`).
    ParakeetOnnx,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpeechModelCatalogEntry {
    pub id: String,
    pub name: String,
    pub runtime: LocalModelRuntime,
    pub repo_id: String,
    pub size_mb: u32,
    pub multilingual: bool,
    pub description: String,
}

/// Built-in local speech recognition catalog (`SV-48`), including NVIDIA Parakeet TDT 0.6B (`sherpa-onnx`) and Whisper models.
pub fn model_catalog() -> Vec<SpeechModelCatalogEntry> {
    vec![
        SpeechModelCatalogEntry {
            id: "parakeet-tdt-0.6b-v2".into(),
            name: "Parakeet TDT 0.6B v2 (sherpa-onnx)".into(),
            runtime: LocalModelRuntime::ParakeetOnnx,
            repo_id: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8".into(),
            size_mb: 620,
            multilingual: false,
            description: "Fast local NVIDIA Parakeet transducer (int8 ONNX) with low-latency word timestamps.".into(),
        },
        SpeechModelCatalogEntry {
            id: "parakeet-tdt-0.6b-v3".into(),
            name: "Parakeet TDT 0.6B v3 Multilingual (sherpa-onnx)".into(),
            runtime: LocalModelRuntime::ParakeetOnnx,
            repo_id: "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8".into(),
            size_mb: 640,
            multilingual: true,
            description: "Multilingual NVIDIA Parakeet TDT 0.6B v3 transducer for European languages and English.".into(),
        },
        SpeechModelCatalogEntry {
            id: "ggml-large-v3-turbo".into(),
            name: "Whisper Large v3 Turbo (whisper.cpp)".into(),
            runtime: LocalModelRuntime::WhisperCpp,
            repo_id: "ggerganov/whisper.cpp".into(),
            size_mb: 809,
            multilingual: true,
            description: "High-accuracy multilingual Whisper Large v3 Turbo model in GGML format.".into(),
        },
        SpeechModelCatalogEntry {
            id: "ggml-small".into(),
            name: "Whisper Small (whisper.cpp)".into(),
            runtime: LocalModelRuntime::WhisperCpp,
            repo_id: "ggerganov/whisper.cpp".into(),
            size_mb: 466,
            multilingual: true,
            description: "Balanced multilingual Whisper Small model for everyday dictation.".into(),
        },
        SpeechModelCatalogEntry {
            id: "ggml-base".into(),
            name: "Whisper Base (whisper.cpp)".into(),
            runtime: LocalModelRuntime::WhisperCpp,
            repo_id: "ggerganov/whisper.cpp".into(),
            size_mb: 142,
            multilingual: true,
            description: "Lightweight Whisper Base model for fast CPU transcription.".into(),
        },
    ]
}

/// A speech model already downloaded on disk in a Hugging Face cache (`~/.cache/huggingface/hub/models--*`) that Nook can
/// link or reuse without downloading a second copy (`SV-48`, `VoiceModelCopies` on macOS).
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReusableModelCopy {
    pub model_id: String,
    pub name: String,
    pub runtime: LocalModelRuntime,
    pub repo_id: String,
    pub snapshot_path: String,
    pub size_bytes: u64,
    pub already_linked: bool,
}

/// Candidate Hugging Face Hub cache directories on Windows, macOS, and Linux.
pub fn hf_hub_roots() -> Vec<std::path::PathBuf> {
    let mut roots = Vec::new();
    let mut push = |p: std::path::PathBuf| {
        if !p.as_os_str().is_empty() && !roots.contains(&p) {
            roots.push(p);
        }
    };
    for var in ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE"] {
        if let Ok(val) = std::env::var(var) {
            if !val.trim().is_empty() {
                push(std::path::PathBuf::from(val.trim()));
            }
        }
    }
    if let Ok(hf_home) = std::env::var("HF_HOME") {
        if !hf_home.trim().is_empty() {
            push(std::path::PathBuf::from(hf_home.trim()).join("hub"));
        }
    }
    if let Ok(xdg) = std::env::var("XDG_CACHE_HOME") {
        if !xdg.trim().is_empty() {
            push(std::path::PathBuf::from(xdg.trim()).join("huggingface").join("hub"));
        }
    }
    for home_var in ["USERPROFILE", "HOME"] {
        if let Ok(home) = std::env::var(home_var) {
            if !home.trim().is_empty() {
                push(std::path::PathBuf::from(home.trim()).join(".cache").join("huggingface").join("hub"));
            }
        }
    }
    if let Ok(local_app_data) = std::env::var("LOCALAPPDATA") {
        if !local_app_data.trim().is_empty() {
            push(std::path::PathBuf::from(local_app_data.trim()).join("huggingface").join("hub"));
        }
    }
    roots
}

fn dir_size_and_files(dir: &std::path::Path) -> (u64, Vec<std::path::PathBuf>) {
    let mut total = 0u64;
    let mut files = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return (0, files) };
    for entry in entries.flatten() {
        let path = entry.path();
        if let Ok(meta) = std::fs::metadata(&path) {
            if meta.is_file() {
                total = total.saturating_add(meta.len());
                files.push(path);
            } else if meta.is_dir() {
                let (sub_size, sub_files) = dir_size_and_files(&path);
                total = total.saturating_add(sub_size);
                files.extend(sub_files);
            }
        }
    }
    (total, files)
}

fn classify_hf_snapshot(repo_id: &str, snapshot_dir: &std::path::Path, linked_dir: Option<&std::path::Path>) -> Vec<ReusableModelCopy> {
    let lower_repo = repo_id.to_lowercase();
    let (total_size, files) = dir_size_and_files(snapshot_dir);
    if files.is_empty() {
        return Vec::new();
    }

    let is_linked = |target_name: &str| -> bool { linked_dir.is_some_and(|d| d.join(target_name).exists()) };

    // 1. Parakeet transducer / ONNX / NeMo repositories
    if lower_repo.contains("parakeet") {
        let has_model_files = files.iter().any(|f| {
            let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();
            name.ends_with(".onnx") || name.ends_with(".nemo") || name.ends_with(".safetensors") || name == "tokens.txt"
        });
        if has_model_files {
            let is_v3 = lower_repo.contains("v3");
            let model_id = if is_v3 { "parakeet-tdt-0.6b-v3" } else { "parakeet-tdt-0.6b-v2" };
            let name = if is_v3 { "Parakeet TDT 0.6B v3 (Hugging Face cache)" } else { "Parakeet TDT 0.6B v2 (Hugging Face cache)" };
            return vec![ReusableModelCopy {
                model_id: model_id.to_string(),
                name: name.to_string(),
                runtime: LocalModelRuntime::ParakeetOnnx,
                repo_id: repo_id.to_string(),
                snapshot_path: snapshot_dir.to_string_lossy().to_string(),
                size_bytes: total_size,
                already_linked: is_linked(model_id),
            }];
        }
    }

    // 2. Whisper GGML / GGUF files in whisper.cpp or whisper repositories
    let mut copies = Vec::new();
    for file in &files {
        let fname = file.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let lower_name = fname.to_lowercase();
        let is_ggml = (lower_name.starts_with("ggml-") || lower_repo.contains("whisper"))
            && (lower_name.ends_with(".bin") || lower_name.ends_with(".gguf"));
        if is_ggml {
            let size = std::fs::metadata(file).map(|m| m.len()).unwrap_or(total_size);
            let stem = fname.trim_end_matches(".bin").trim_end_matches(".gguf").to_string();
            copies.push(ReusableModelCopy {
                model_id: stem.clone(),
                name: format!("{fname} ({repo_id})"),
                runtime: LocalModelRuntime::WhisperCpp,
                repo_id: repo_id.to_string(),
                snapshot_path: file.to_string_lossy().to_string(),
                size_bytes: size,
                already_linked: is_linked(fname) || is_linked(&stem),
            });
        }
    }

    // 3. Generic Whisper Hugging Face snapshot (e.g. openai/whisper-large-v3-turbo or Systran/faster-whisper-*)
    if copies.is_empty() && lower_repo.contains("whisper") {
        let has_weights = files.iter().any(|f| {
            let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();
            name.ends_with(".safetensors") || name.ends_with(".bin") || name.ends_with(".onnx")
        });
        if has_weights {
            let short = repo_id.rsplit('/').next().unwrap_or(repo_id);
            copies.push(ReusableModelCopy {
                model_id: short.to_string(),
                name: format!("{short} ({repo_id})"),
                runtime: LocalModelRuntime::WhisperCpp,
                repo_id: repo_id.to_string(),
                snapshot_path: snapshot_dir.to_string_lossy().to_string(),
                size_bytes: total_size,
                already_linked: is_linked(short),
            });
        }
    }

    copies
}

/// Scans a single Hugging Face Hub directory (`~/.cache/huggingface/hub`) for `models--*` snapshots that Nook can reuse (`SV-48`).
pub fn scan_hf_cache_dir(hub_dir: &std::path::Path, linked_dir: Option<&std::path::Path>) -> Vec<ReusableModelCopy> {
    let mut out = Vec::new();
    let mut seen_ids = std::collections::HashSet::new();
    let Ok(entries) = std::fs::read_dir(hub_dir) else { return out };
    let mut dirs: Vec<std::path::PathBuf> = entries.flatten().map(|e| e.path()).collect();
    dirs.sort();

    for model_dir in dirs {
        let Some(folder_name) = model_dir.file_name().and_then(|n| n.to_str()) else { continue };
        let Some(rest) = folder_name.strip_prefix("models--") else { continue };
        let repo_id = rest.replacen("--", "/", 1);
        let snapshots_root = model_dir.join("snapshots");
        let snapshot_dirs: Vec<std::path::PathBuf> = if snapshots_root.is_dir() {
            std::fs::read_dir(&snapshots_root).ok().into_iter().flatten().flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()
        } else if model_dir.is_dir() {
            vec![model_dir.clone()]
        } else {
            Vec::new()
        };

        for snap in snapshot_dirs {
            for copy in classify_hf_snapshot(&repo_id, &snap, linked_dir) {
                let key = format!("{}:{}", copy.model_id, copy.repo_id);
                if seen_ids.insert(key) {
                    out.push(copy);
                }
            }
        }
    }
    out
}

/// Directory where Nook keeps or links local speech models.
pub fn speech_models_dir() -> std::path::PathBuf {
    crate::paths::support_directory().join("speech-models")
}

/// Scans all standard Hugging Face cache roots on the system for reusable Whisper and Parakeet models (`SV-48`).
pub fn discover_reusable_models() -> Vec<ReusableModelCopy> {
    let linked = speech_models_dir();
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for root in hf_hub_roots() {
        for item in scan_hf_cache_dir(&root, Some(&linked)) {
            if seen.insert(item.snapshot_path.clone()) {
                out.push(item);
            }
        }
    }
    out
}

/// Links or registers an existing Hugging Face snapshot/file into `target_dir` so Nook can use it without re-downloading (`SV-48`).
pub fn reuse_hf_model(model_id: &str, snapshot_path: &std::path::Path, target_dir: &std::path::Path) -> Result<std::path::PathBuf> {
    if !snapshot_path.exists() {
        let path = snapshot_path.display();
        return Err(nook_err!(
            "{}",
            crate::i18n::trf("Modelbestand bestaat niet: {path}", "Model file does not exist: {path}", &[("path", &path)],)
        ));
    }
    std::fs::create_dir_all(target_dir)?;
    let safe_name: String =
        model_id.chars().map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' }).collect();
    let dest = if snapshot_path.is_file() {
        let ext = snapshot_path.extension().and_then(|e| e.to_str()).unwrap_or("bin");
        if safe_name.ends_with(&format!(".{ext}")) {
            target_dir.join(&safe_name)
        } else {
            target_dir.join(format!("{safe_name}.{ext}"))
        }
    } else {
        target_dir.join(&safe_name)
    };

    if dest.exists() {
        return Ok(dest);
    }

    #[cfg(unix)]
    {
        if std::os::unix::fs::symlink(snapshot_path, &dest).is_ok() {
            return Ok(dest);
        }
    }
    #[cfg(windows)]
    {
        let linked = if snapshot_path.is_dir() {
            std::os::windows::fs::symlink_dir(snapshot_path, &dest)
        } else {
            std::os::windows::fs::symlink_file(snapshot_path, &dest).or_else(|_| std::fs::hard_link(snapshot_path, &dest))
        };
        if linked.is_ok() {
            return Ok(dest);
        }
    }

    // Fallback when OS symlinks are restricted: write a lightweight `.nook-model-link` pointer or hardlink.
    if snapshot_path.is_file() && std::fs::hard_link(snapshot_path, &dest).is_ok() {
        return Ok(dest);
    }
    crate::paths::write_atomic(&dest, snapshot_path.to_string_lossy().as_bytes())?;
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_words_with_their_time() {
        let json = json!({"text": " Hallo daar ", "words": [{"word": "Hallo", "start": 0.1, "end": 0.4}, {"word": "daar", "start": 0.5, "end": 0.9}]});
        let (text, words) = parse_verbose(&json, 10.0);
        assert_eq!(text, "Hallo daar");
        assert_eq!(words.len(), 2);
        assert!((words[1].start - 10.5).abs() < 1e-9);
        let segments = json!({"text": "Hoi", "segments": [{"text": "Hoi", "start": 1.0, "end": 1.5}]});
        assert_eq!(parse_verbose(&segments, 0.0).1[0].text, "Hoi");
    }

    #[test]
    fn whisper_cpp_output() {
        let json = json!({"transcription": [{"offsets": {"from": 0, "to": 1000}, "text": " goede morgen"}]});
        let (text, words) = parse_whisper_cpp(&json, 2.0);
        assert_eq!(text, "goede morgen");
        assert_eq!(words.len(), 2);
        assert!((words[1].start - 2.5).abs() < 1e-9);
    }

    #[test]
    fn multipart_has_the_file_and_fields() {
        let body = String::from_utf8_lossy(&multipart("b", &[("model", "whisper-1")], b"RIFF")).to_string();
        assert!(body.starts_with("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"));
        assert!(body.contains("filename=\"nook.wav\""));
        assert!(body.ends_with("RIFF\r\n--b--\r\n"));
        assert_eq!(endpoint(SpeechEngine::Local), None);
        assert_eq!(language_code("auto", "en"), "en");
    }

    #[test]
    fn whisper_cli_args_wires_auto_language_and_prompt_context() {
        let auto_args = whisper_cli_args("/models/ggml-base.bin", "/tmp/in.wav", "auto", "Nook, Parakeet");
        assert_eq!(auto_args, vec!["-m", "/models/ggml-base.bin", "-f", "/tmp/in.wav", "-l", "auto", "-oj", "--prompt", "Nook, Parakeet"]);
        let fixed_args = whisper_cli_args("/models/ggml-base.bin", "/tmp/in.wav", "nl-NL", "  ");
        assert_eq!(fixed_args, vec!["-m", "/models/ggml-base.bin", "-f", "/tmp/in.wav", "-l", "nl", "-oj"]);
        assert_eq!(detected_language(&json!({"language": "dutch"})), Some("nl"));
        assert_eq!(detected_language(&json!({"result": {"language": "de"}})), Some("de"));
    }

    #[test]
    fn scans_and_reuses_parakeet_and_whisper_from_huggingface_cache() {
        let temp = std::env::temp_dir().join(format!("nook-hf-test-{}", uuid::Uuid::new_v4().simple()));
        let parakeet_snap = temp.join("models--csukuangfj--sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8").join("snapshots").join("abc123456");
        let whisper_snap = temp.join("models--ggerganov--whisper.cpp").join("snapshots").join("def789012");
        let linked_dir = temp.join("linked");

        std::fs::create_dir_all(&parakeet_snap).unwrap();
        std::fs::write(parakeet_snap.join("encoder.int8.onnx"), b"onnx-encoder-weights").unwrap();
        std::fs::write(parakeet_snap.join("decoder.int8.onnx"), b"onnx-decoder-weights").unwrap();
        std::fs::write(parakeet_snap.join("tokens.txt"), b"a 0\nb 1\n").unwrap();

        std::fs::create_dir_all(&whisper_snap).unwrap();
        std::fs::write(whisper_snap.join("ggml-large-v3-turbo.bin"), b"ggml-weights").unwrap();

        let found = scan_hf_cache_dir(&temp, Some(&linked_dir));
        assert_eq!(found.len(), 2);
        assert!(found.iter().any(|m| m.model_id == "parakeet-tdt-0.6b-v2" && m.runtime == LocalModelRuntime::ParakeetOnnx));
        assert!(found.iter().any(|m| m.model_id == "ggml-large-v3-turbo" && m.runtime == LocalModelRuntime::WhisperCpp));

        let parakeet = found.iter().find(|m| m.model_id == "parakeet-tdt-0.6b-v2").unwrap();
        let dest = reuse_hf_model(&parakeet.model_id, std::path::Path::new(&parakeet.snapshot_path), &linked_dir).unwrap();
        assert!(dest.exists());

        let found_after = scan_hf_cache_dir(&temp, Some(&linked_dir));
        let parakeet_after = found_after.iter().find(|m| m.model_id == "parakeet-tdt-0.6b-v2").unwrap();
        assert!(parakeet_after.already_linked);

        let _ = std::fs::remove_dir_all(&temp);
    }
}
