//! Praten tegen Nook (sneltoets of microfoonknop) en de spraakherkenning die ook Flow en de Notetaker gebruiken.
//!
//! Herkenning, in de volgorde die de gebruiker kiest (Instellingen › Stem en geluid):
//! - op deze computer met whisper.cpp (`whisper-cli` met een `ggml-*.bin`-model) — standaard;
//! - de spraakherkenning van Windows (vrije tekst gaat dan via Microsoft, dus alleen als je daarvoor kiest);
//! - OpenAI of Groq (`audio/transcriptions`) met je eigen sleutel.
//!
//! Nooit stilletjes naar de cloud: zonder keuze en zonder whisper.cpp zegt Nook wat er nodig is.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nook_core::provider::AIProvider;
use nook_core::services::notes::TimedWord;
use nook_core::services::prefs::SpeechEngine;
use nook_core::services::transcribe;
use nook_core::services::vad::{self, EnergyVad, VadEvent};
use serde::Serialize;
use tauri::{AppHandle, Manager};

use super::Services;
use crate::state::AppState;

/// Waar een opname voor is: de vraag aan Nook, of Flow (plakken waar je typt).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Talk,
    Flow,
}

impl Purpose {
    fn event(self) -> &'static str {
        match self {
            Self::Talk => "voice-state",
            Self::Flow => "flow-state",
        }
    }
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct VoiceEvent {
    /// "listening", "working", "idle" of "error".
    pub phase: String,
    /// Wat er tot nu toe gehoord is (als de herkenning dat live geeft).
    pub text: String,
    /// Luidheid, 0…1.
    pub level: f32,
    pub error: Option<String>,
    /// De herkende tekst als het luisteren klaar is.
    pub result: Option<String>,
    /// Seconden sinds het begin.
    pub seconds: f64,
}

struct Listen {
    purpose: Purpose,
    #[cfg(desktop)]
    recording: Option<crate::platform::audio::Recording>,
    samples: Arc<Mutex<Vec<f32>>>,
    dictation: bool,
    started: Instant,
    generation: u64,
}

#[derive(Default)]
pub struct VoiceState {
    current: Mutex<Option<Listen>>,
    generation: AtomicU64,
    stop_requested: Arc<AtomicBool>,
}

pub fn emit(app: &AppHandle, purpose: Purpose, event: VoiceEvent) {
    super::emit(app, purpose.event(), event);
}

fn language(app: &AppHandle) -> String {
    let settings = app.state::<AppState>().settings();
    transcribe::language_code(&settings.language, &settings.app_language)
}

fn locale(code: &str) -> &'static str {
    match code {
        "en" => "en-US",
        "de" => "de-DE",
        "fr" => "fr-FR",
        "es" => "es-ES",
        _ => "nl-NL",
    }
}

/// Het programma van whisper.cpp, als het geïnstalleerd is.
pub fn whisper_binary() -> Option<&'static str> {
    #[cfg(desktop)]
    {
        ["whisper-cli", "whisper-cpp", "whisper.cpp"].into_iter().find(|b| crate::platform::process::which(b))
    }
    #[cfg(not(desktop))]
    {
        None
    }
}

/// Of de gekozen herkenning klaar is; anders wat er nodig is, in een zin.
pub fn engine_ready(app: &AppHandle, purpose_live: bool) -> Result<SpeechEngine, String> {
    let services = app.state::<Services>();
    let prefs = services.prefs();
    match prefs.speech_engine {
        SpeechEngine::Local => {
            if whisper_binary().is_none() {
                return Err("Voor spraakherkenning op deze computer is whisper.cpp nodig (het programma whisper-cli). Installeer het en kies een model bij Instellingen › Stem en geluid, of kies daar een andere herkenning.".into());
            }
            if prefs.whisper_model.trim().is_empty() || !std::path::Path::new(prefs.whisper_model.trim()).is_file() {
                return Err("Kies het model van whisper.cpp (een ggml-….bin-bestand) bij Instellingen › Stem en geluid.".into());
            }
            Ok(SpeechEngine::Local)
        }
        SpeechEngine::Windows => {
            if !cfg!(target_os = "windows") {
                return Err(
                    "De spraakherkenning van Windows is er alleen op Windows. Kies een andere bij Instellingen › Stem en geluid.".into()
                );
            }
            if !purpose_live {
                return Err("De spraakherkenning van Windows luistert alleen live. De Notetaker heeft whisper.cpp of een externe dienst nodig (Instellingen › Stem en geluid).".into());
            }
            Ok(SpeechEngine::Windows)
        }
        engine @ (SpeechEngine::Openai | SpeechEngine::Groq) => {
            let provider = if engine == SpeechEngine::Openai { AIProvider::Openai } else { AIProvider::Groq };
            if app.state::<AppState>().key_for(provider).is_none() {
                return Err(format!(
                    "Er is nog geen {}-sleutel voor de spraakherkenning. Plak hem bij Instellingen › Brein ({}).",
                    provider.title(),
                    provider.title()
                ));
            }
            Ok(engine)
        }
    }
}

/// 16 kHz mono → tekst en woorden met hun tijd, met de gekozen herkenning.
pub async fn transcribe(app: &AppHandle, samples: Vec<f32>, offset: f64) -> Result<(String, Vec<TimedWord>), String> {
    let engine = engine_ready(app, false)?;
    let lang = language(app);
    match engine {
        SpeechEngine::Local => {
            let model = app.state::<Services>().prefs().whisper_model.trim().to_string();
            tauri::async_runtime::spawn_blocking(move || whisper(&samples, &model, &lang, offset)).await.map_err(|e| e.to_string())?
        }
        SpeechEngine::Openai | SpeechEngine::Groq => {
            let provider = if engine == SpeechEngine::Openai { AIProvider::Openai } else { AIProvider::Groq };
            let key = app.state::<AppState>().key_for(provider).unwrap_or_default();
            transcribe::remote(engine, &key, &samples, &lang, offset).await.map_err(|e| e.0)
        }
        SpeechEngine::Windows => Err("De spraakherkenning van Windows luistert alleen live.".into()),
    }
}

/// whisper.cpp op deze computer. Het geluid staat heel even in een afgeschermd bestand en gaat daarna weg.
fn whisper(samples: &[f32], model: &str, lang: &str, offset: f64) -> Result<(String, Vec<TimedWord>), String> {
    #[cfg(desktop)]
    {
        let binary = whisper_binary().ok_or("whisper.cpp ontbreekt.")?;
        let dir = nook_core::paths::support_directory().join("tmp");
        let _ = std::fs::create_dir_all(&dir);
        nook_core::paths::restrict(&dir, 0o700);
        let base = dir.join(uuid::Uuid::new_v4().to_string());
        let wav = base.with_extension("wav");
        std::fs::write(&wav, nook_core::services::audio::wav(samples, 16_000)).map_err(|e| e.to_string())?;
        nook_core::paths::restrict(&wav, 0o600);
        let (wav_s, base_s) = (wav.to_string_lossy().to_string(), base.to_string_lossy().to_string());
        let result = crate::platform::process::run_text(
            binary,
            &["-m", model, "-f", &wav_s, "-l", lang, "-oj", "-of", &base_s, "-np"],
            Duration::from_secs(120),
        );
        let json_path = base.with_extension("json");
        let json = std::fs::read_to_string(&json_path);
        let _ = std::fs::remove_file(&wav);
        let _ = std::fs::remove_file(&json_path);
        result.map_err(|e| format!("whisper.cpp gaf een fout: {e}"))?;
        let value: serde_json::Value = serde_json::from_str(&json.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        Ok(transcribe::parse_whisper_cpp(&value, offset))
    }
    #[cfg(not(desktop))]
    {
        let _ = (samples, model, lang, offset);
        Err("whisper.cpp kan op dit platform niet.".into())
    }
}

/// Begint te luisteren. Bij praten stopt Nook vanzelf na een stilte; bij Flow als je de toets loslaat.
pub fn start(app: &AppHandle, purpose: Purpose) -> Result<(), String> {
    let services = app.state::<Services>();
    let engine = engine_ready(app, true)?;
    cancel(app);
    services.platform.speech.stop();
    let generation = services.voice.generation.fetch_add(1, Ordering::SeqCst) + 1;
    services.voice.stop_requested.store(false, Ordering::SeqCst);
    let samples: Arc<Mutex<Vec<f32>>> = Arc::default();
    let dictation = engine == SpeechEngine::Windows;
    #[cfg(desktop)]
    let recording = if dictation {
        services.platform.dictation.start(locale(&language(app)))?;
        None
    } else {
        let sink_samples = samples.clone();
        Some(crate::platform::audio::microphone(Box::new(move |chunk: &[f32]| {
            sink_samples.lock().unwrap_or_else(|e| e.into_inner()).extend_from_slice(chunk);
        }))?)
    };
    #[cfg(not(desktop))]
    {
        let _ = (dictation, locale(""));
        return Err("Opnemen kan op dit platform (nog) niet.".into());
    }
    #[cfg(desktop)]
    {
        *services.voice.current.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(Listen { purpose, recording, samples: samples.clone(), dictation, started: Instant::now(), generation });
        emit(app, purpose, VoiceEvent { phase: "listening".into(), ..Default::default() });
        let app = app.clone();
        std::thread::Builder::new().name("nook-luisteren".into()).spawn(move || watch(app, purpose, samples, generation)).ok();
        Ok(())
    }
}

/// Houdt de luidheid bij en stopt het praten na een stilte: 6 s om te beginnen, 1,8 s na het laatste woord.
fn watch(app: AppHandle, purpose: Purpose, samples: Arc<Mutex<Vec<f32>>>, generation: u64) {
    let services = app.state::<Services>();
    let mut vad = EnergyVad::default();
    vad.set_frame_rate(10.0);
    let mut read = 0usize;
    let mut heard = false;
    let mut last_voice = Instant::now();
    let mut last_partial = String::new();
    let started = Instant::now();
    loop {
        std::thread::sleep(Duration::from_millis(100));
        if services.voice.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        if services.voice.stop_requested.load(Ordering::SeqCst) {
            finish(&app);
            return;
        }
        let (level, chunk_power) = {
            let all = samples.lock().unwrap_or_else(|e| e.into_inner());
            let chunk = &all[read.min(all.len())..];
            read = all.len();
            (nook_core::services::notes::rms(chunk), vad::power(chunk))
        };
        let partial = services.platform.dictation.partial();
        let dictating = services.voice.current.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|l| l.dictation);
        if dictating {
            if partial != last_partial {
                last_partial = partial.clone();
                heard = true;
                last_voice = Instant::now();
            }
        } else {
            match vad.feed(chunk_power) {
                VadEvent::Start => {
                    heard = true;
                    last_voice = Instant::now();
                }
                _ if vad.is_active() => last_voice = Instant::now(),
                _ => {}
            }
        }
        emit(
            &app,
            purpose,
            VoiceEvent {
                phase: "listening".into(),
                text: if dictating { partial } else { String::new() },
                level: (level * 8.0).min(1.0),
                seconds: started.elapsed().as_secs_f64(),
                ..Default::default()
            },
        );
        if purpose == Purpose::Talk {
            let quiet = last_voice.elapsed().as_secs_f64();
            if (!heard && started.elapsed().as_secs_f64() > 6.0) || (heard && quiet > 1.8) || started.elapsed().as_secs() > 120 {
                finish(&app);
                return;
            }
        }
    }
}

/// Vraagt het luisteren te stoppen (de knop Klaar, of de toets van Flow los).
pub fn request_finish(app: &AppHandle) {
    let services = app.state::<Services>();
    if services.voice.current.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
        services.voice.stop_requested.store(true, Ordering::SeqCst);
        // Als de wachtdraad al weg is (Flow), doen we het zelf.
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(250));
            if app.state::<Services>().voice.current.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
                finish(&app);
            }
        });
    }
}

/// Stopt en herkent wat er gezegd is; het resultaat komt als event.
fn finish(app: &AppHandle) {
    let services = app.state::<Services>();
    let Some(mut listen) = services.voice.current.lock().unwrap_or_else(|e| e.into_inner()).take() else { return };
    #[cfg(desktop)]
    if let Some(mut recording) = listen.recording.take() {
        recording.stop();
    }
    let purpose = listen.purpose;
    let seconds = listen.started.elapsed().as_secs_f64();
    emit(app, purpose, VoiceEvent { phase: "working".into(), seconds, ..Default::default() });
    let app = app.clone();
    let generation = listen.generation;
    tauri::async_runtime::spawn(async move {
        let result = if listen.dictation {
            app.state::<Services>().platform.dictation.stop()
        } else {
            let samples = std::mem::take(&mut *listen.samples.lock().unwrap_or_else(|e| e.into_inner()));
            if nook_core::services::notes::rms(&samples) < 0.002 || samples.len() < 8000 {
                Ok(String::new())
            } else {
                transcribe(&app, samples, 0.0).await.map(|(text, _)| text)
            }
        };
        if app.state::<Services>().voice.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        match result {
            Ok(text) => match purpose {
                Purpose::Talk => emit(
                    &app,
                    purpose,
                    VoiceEvent { phase: "idle".into(), result: Some(text.trim().to_string()), seconds, ..Default::default() },
                ),
                Purpose::Flow => super::flow::deliver(&app, text.trim(), seconds).await,
            },
            Err(e) => emit(&app, purpose, VoiceEvent { phase: "error".into(), error: Some(e), seconds, ..Default::default() }),
        }
    });
}

/// Stopt zonder iets te doen met wat er gezegd is.
pub fn cancel(app: &AppHandle) {
    let services = app.state::<Services>();
    services.voice.generation.fetch_add(1, Ordering::SeqCst);
    let taken = services.voice.current.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(mut listen) = taken {
        #[cfg(desktop)]
        if let Some(mut recording) = listen.recording.take() {
            recording.stop();
        }
        if listen.dictation {
            services.platform.dictation.cancel();
        }
        emit(app, listen.purpose, VoiceEvent { phase: "idle".into(), ..Default::default() });
    }
}

pub fn is_listening(app: &AppHandle) -> bool {
    app.state::<Services>().voice.current.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

/// "Hé Nook" aan of uit, volgens de instelling.
pub fn start_wake_word(app: &AppHandle) {
    let services = app.state::<Services>();
    let wake = services.platform.wake.clone();
    wake.stop();
    if !app.state::<AppState>().settings().wake_word || !wake.available() {
        return;
    }
    let handle = app.clone();
    let result = wake.start(Box::new(move || {
        if !is_listening(&handle) {
            #[cfg(desktop)]
            crate::platform::desktop::open_bar(&handle, "voice");
        }
    }));
    if let Err(e) = result {
        log::warn!("Hé Nook: {e}");
    }
}
