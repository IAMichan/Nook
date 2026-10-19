//! Stem op Windows: voorlezen met `SpeechSynthesizer` (op de computer), dicteren met de spraakherkenning van Windows
//! (die bij vrije tekst de online spraakherkenning van Microsoft gebruikt: alleen als de gebruiker daarvoor kiest),
//! en "Hé Nook" met een vaste woordenlijst, die op de computer zelf herkend wordt.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use nook_core::platform::{Dictation, SpeechOutput, WakeWord};
use windows::core::HSTRING;
use windows::Foundation::TypedEventHandler;
use windows::Globalization::Language;
use windows::Media::Core::MediaSource;
use windows::Media::Playback::{MediaPlaybackState, MediaPlayer};
use windows::Media::SpeechRecognition::{
    SpeechContinuousRecognitionSession, SpeechRecognitionConfidence, SpeechRecognitionListConstraint, SpeechRecognitionResultStatus,
    SpeechRecognitionScenario, SpeechRecognitionTopicConstraint, SpeechRecognizer,
};
use windows::Media::SpeechSynthesis::SpeechSynthesizer;

#[derive(Default)]
struct Queue {
    items: VecDeque<(String, String)>,
    busy: bool,
    stop: bool,
}

pub struct WindowsSpeech {
    shared: Arc<(Mutex<Queue>, Condvar)>,
    available: bool,
}

impl WindowsSpeech {
    pub fn new() -> Self {
        let shared = Arc::new((Mutex::new(Queue::default()), Condvar::new()));
        let available = SpeechSynthesizer::AllVoices().and_then(|v| v.Size()).map(|n| n > 0).unwrap_or(false);
        if available {
            let worker = shared.clone();
            std::thread::Builder::new().name("nook-spraak".into()).spawn(move || speaker(worker)).ok();
        }
        Self { shared, available }
    }
}

fn voice_for(synth: &SpeechSynthesizer, language: &str) {
    let prefix: String = language.chars().take(2).collect::<String>().to_lowercase();
    if let Ok(voices) = SpeechSynthesizer::AllVoices() {
        for voice in voices {
            let lang = voice.Language().map(|l| l.to_string().to_lowercase()).unwrap_or_default();
            if lang == language.to_lowercase() || lang.starts_with(&prefix) {
                let _ = synth.SetVoice(&voice);
                return;
            }
        }
    }
}

fn speaker(shared: Arc<(Mutex<Queue>, Condvar)>) {
    let (lock, signal) = &*shared;
    let (Ok(synth), Ok(player)) = (SpeechSynthesizer::new(), MediaPlayer::new()) else { return };
    loop {
        let (text, language) = {
            let mut q = lock.lock().unwrap_or_else(|e| e.into_inner());
            while q.items.is_empty() {
                q.busy = false;
                q = signal.wait(q).unwrap_or_else(|e| e.into_inner());
            }
            q.busy = true;
            q.stop = false;
            q.items.pop_front().unwrap_or_default()
        };
        voice_for(&synth, &language);
        let Ok(stream) = synth.SynthesizeTextToStreamAsync(&HSTRING::from(text)).and_then(|o| o.join()) else { continue };
        let Ok(content) = stream.ContentType() else { continue };
        let Ok(source) = MediaSource::CreateFromStream(&stream, &content) else { continue };
        if player.SetSource(&source).is_err() || player.Play().is_err() {
            continue;
        }
        std::thread::sleep(Duration::from_millis(150));
        loop {
            if lock.lock().unwrap_or_else(|e| e.into_inner()).stop {
                let _ = player.Pause();
                break;
            }
            let state = player.PlaybackSession().and_then(|s| s.PlaybackState()).unwrap_or(MediaPlaybackState::None);
            if state != MediaPlaybackState::Playing && state != MediaPlaybackState::Opening && state != MediaPlaybackState::Buffering {
                break;
            }
            std::thread::sleep(Duration::from_millis(60));
        }
    }
}

impl SpeechOutput for WindowsSpeech {
    fn available(&self) -> bool {
        self.available
    }

    fn speak(&self, text: &str, language: &str) -> Result<(), String> {
        self.stop();
        self.enqueue(text, language)
    }

    fn enqueue(&self, text: &str, language: &str) -> Result<(), String> {
        if !self.available {
            return Err("Voorlezen kan niet: Windows heeft geen stemmen geïnstalleerd (Instellingen › Tijd en taal › Spraak).".into());
        }
        let text: String = text.trim().chars().take(1200).collect();
        if text.is_empty() {
            return Ok(());
        }
        let (lock, signal) = &*self.shared;
        lock.lock().unwrap_or_else(|e| e.into_inner()).items.push_back((text, language.into()));
        signal.notify_one();
        Ok(())
    }

    fn stop(&self) {
        let (lock, _) = &*self.shared;
        let mut q = lock.lock().unwrap_or_else(|e| e.into_inner());
        q.items.clear();
        q.stop = true;
    }

    fn speaking(&self) -> bool {
        let (lock, _) = &*self.shared;
        let q = lock.lock().unwrap_or_else(|e| e.into_inner());
        q.busy || !q.items.is_empty()
    }
}

fn recognizer(language: &str) -> windows::core::Result<SpeechRecognizer> {
    match Language::CreateLanguage(&HSTRING::from(language)).and_then(|l| SpeechRecognizer::Create(&l)) {
        Ok(r) => Ok(r),
        Err(_) => SpeechRecognizer::new(),
    }
}

#[derive(Default)]
struct Heard {
    text: String,
    partial: String,
}

/// Dicteren met de spraakherkenning van Windows. Vrije tekst gaat via de online spraakherkenning van Microsoft; de
/// gebruiker kiest daar zelf voor in Instellingen › Stem en geluid.
pub struct WindowsDictation {
    session: Mutex<Option<(SpeechRecognizer, SpeechContinuousRecognitionSession)>>,
    heard: Arc<Mutex<Heard>>,
}

impl WindowsDictation {
    pub fn new() -> Self {
        Self { session: Mutex::new(None), heard: Arc::new(Mutex::new(Heard::default())) }
    }
}

fn explain(e: windows::core::Error) -> String {
    format!(
        "De spraakherkenning van Windows werkt niet: {}. Zet Online spraakherkenning aan bij Instellingen › Privacy › Spraak, of kies een andere herkenning.",
        e.message()
    )
}

impl Dictation for WindowsDictation {
    fn available(&self) -> bool {
        true
    }

    fn start(&self, language: &str) -> Result<(), String> {
        self.cancel();
        let recognizer = recognizer(language).map_err(explain)?;
        let constraint = SpeechRecognitionTopicConstraint::Create(SpeechRecognitionScenario::Dictation, &HSTRING::from("dictation")).map_err(explain)?;
        recognizer.Constraints().and_then(|c| c.Append(&constraint)).map_err(explain)?;
        let compiled = recognizer.CompileConstraintsAsync().and_then(|o| o.join()).map_err(explain)?;
        if compiled.Status().map_err(explain)? != SpeechRecognitionResultStatus::Success {
            return Err("De spraakherkenning van Windows kon niet starten. Staat Online spraakherkenning aan (Instellingen › Privacy › Spraak)?".into());
        }
        *self.heard.lock().unwrap_or_else(|e| e.into_inner()) = Heard::default();
        let heard = self.heard.clone();
        recognizer
            .HypothesisGenerated(&TypedEventHandler::<SpeechRecognizer, windows::Media::SpeechRecognition::SpeechRecognitionHypothesisGeneratedEventArgs>::new(move |_, args| {
                if let Some(args) = args.as_ref() {
                    let args: &windows::Media::SpeechRecognition::SpeechRecognitionHypothesisGeneratedEventArgs = args;
                    if let Ok(text) = args.Hypothesis().and_then(|h| h.Text()) {
                        heard.lock().unwrap_or_else(|e| e.into_inner()).partial = text.to_string();
                    }
                }
                Ok(())
            }))
            .map_err(explain)?;
        let session = recognizer.ContinuousRecognitionSession().map_err(explain)?;
        let heard = self.heard.clone();
        session
            .ResultGenerated(&TypedEventHandler::<SpeechContinuousRecognitionSession, windows::Media::SpeechRecognition::SpeechContinuousRecognitionResultGeneratedEventArgs>::new(move |_, args| {
                if let Some(args) = args.as_ref() {
                    let args: &windows::Media::SpeechRecognition::SpeechContinuousRecognitionResultGeneratedEventArgs = args;
                    if let Ok(text) = args.Result().and_then(|r| r.Text()) {
                        let mut h = heard.lock().unwrap_or_else(|e| e.into_inner());
                        let text = text.to_string();
                        if !text.trim().is_empty() {
                            if !h.text.is_empty() {
                                h.text.push(' ');
                            }
                            h.text.push_str(text.trim());
                        }
                        h.partial.clear();
                    }
                }
                Ok(())
            }))
            .map_err(explain)?;
        session.StartAsync().and_then(|o| o.join()).map_err(explain)?;
        *self.session.lock().unwrap_or_else(|e| e.into_inner()) = Some((recognizer, session));
        Ok(())
    }

    fn partial(&self) -> String {
        let h = self.heard.lock().unwrap_or_else(|e| e.into_inner());
        [h.text.as_str(), h.partial.as_str()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
    }

    fn stop(&self) -> Result<String, String> {
        let taken = self.session.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some((_, session)) = taken {
            session.StopAsync().and_then(|o| o.join()).map_err(explain)?;
        }
        let h = self.heard.lock().unwrap_or_else(|e| e.into_inner());
        Ok(if h.text.is_empty() { h.partial.clone() } else { h.text.clone() })
    }

    fn cancel(&self) {
        if let Some((_, session)) = self.session.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = session.CancelAsync().and_then(|o| o.join());
        }
    }
}

/// "Hé Nook" met een vaste woordenlijst: Windows herkent die op de computer zelf, zonder internet.
pub struct WindowsWake {
    session: Mutex<Option<(SpeechRecognizer, SpeechContinuousRecognitionSession)>>,
}

impl WindowsWake {
    pub fn new() -> Self {
        Self { session: Mutex::new(None) }
    }
}

impl WakeWord for WindowsWake {
    fn available(&self) -> bool {
        SpeechRecognizer::SupportedGrammarLanguages().and_then(|l| l.Size()).map(|n| n > 0).unwrap_or(false)
    }

    fn start(&self, on_wake: Box<dyn Fn() + Send + Sync>) -> Result<(), String> {
        self.stop();
        let language = SpeechRecognizer::SystemSpeechLanguage().ok();
        let recognizer = match language {
            Some(l) => SpeechRecognizer::Create(&l),
            None => SpeechRecognizer::new(),
        }
        .map_err(|e| format!("\"Hé Nook\" kan niet starten: {}", e.message()))?;
        let phrases: windows_collections::IIterable<HSTRING> =
            ["hé nook", "hey nook", "hee nook", "hoi nook", "hallo nook"].into_iter().map(HSTRING::from).collect::<Vec<_>>().into();
        let constraint = SpeechRecognitionListConstraint::Create(&phrases).map_err(|e| e.message().to_string())?;
        recognizer.Constraints().and_then(|c| c.Append(&constraint)).map_err(|e| e.message().to_string())?;
        let compiled = recognizer.CompileConstraintsAsync().and_then(|o| o.join()).map_err(|e| e.message().to_string())?;
        if compiled.Status().map_err(|e| e.message().to_string())? != SpeechRecognitionResultStatus::Success {
            return Err("\"Hé Nook\" kan niet starten: installeer een spraaktaal bij Instellingen › Tijd en taal › Spraak.".into());
        }
        let session = recognizer.ContinuousRecognitionSession().map_err(|e| e.message().to_string())?;
        let on_wake = Arc::new(on_wake);
        session
            .ResultGenerated(&TypedEventHandler::<SpeechContinuousRecognitionSession, windows::Media::SpeechRecognition::SpeechContinuousRecognitionResultGeneratedEventArgs>::new(move |_, args| {
                if let Some(args) = args.as_ref() {
                    let args: &windows::Media::SpeechRecognition::SpeechContinuousRecognitionResultGeneratedEventArgs = args;
                    let confident = args
                        .Result()
                        .and_then(|r| r.Confidence())
                        .map(|c| c == SpeechRecognitionConfidence::High || c == SpeechRecognitionConfidence::Medium)
                        .unwrap_or(false);
                    if confident {
                        on_wake();
                    }
                }
                Ok(())
            }))
            .map_err(|e| e.message().to_string())?;
        session.StartAsync().and_then(|o| o.join()).map_err(|e| e.message().to_string())?;
        *self.session.lock().unwrap_or_else(|e| e.into_inner()) = Some((recognizer, session));
        Ok(())
    }

    fn stop(&self) {
        if let Some((_, session)) = self.session.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = session.StopAsync().and_then(|o| o.join());
        }
    }
}
