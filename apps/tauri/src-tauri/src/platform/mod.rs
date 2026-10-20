//! De platformlaag: wat Windows, Linux en Android elk anders doen, achter de traits uit `nook_core::platform`.

pub mod secrets;

#[cfg(desktop)]
pub mod desktop;

#[cfg(desktop)]
pub mod audio;
#[cfg(desktop)]
pub mod imaging;
#[cfg(desktop)]
pub mod process;

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub mod android;
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "windows")]
pub mod windows;

use std::sync::Arc;

use nook_core::platform::{
    Capabilities, Dictation, FieldSkip, FocusedField, InputEvent, MediaControl, PowerMonitor, QuietWatch, ScreenReader, SpeechOutput,
    SystemControl, TextInput, WakeWord,
};
use nook_core::services::autocomplete::prefs::KeyChord;
use tauri::AppHandle;

/// De diensten van dit platform, één keer gemaakt bij de start.
#[derive(Clone)]
pub struct Platform {
    pub screen: Arc<dyn ScreenReader>,
    pub media: Arc<dyn MediaControl>,
    pub system: Arc<dyn SystemControl>,
    pub speech: Arc<dyn SpeechOutput>,
    pub dictation: Arc<dyn Dictation>,
    pub wake: Arc<dyn WakeWord>,
    /// Screen sharing and calls, for the meeting and sharing choices.
    pub quiet: Arc<dyn QuietWatch>,
    /// Battery, battery saver and load, for the energy plan.
    pub power: Arc<dyn PowerMonitor>,
    /// Autocomplete: keyboard hook, focused field, typing (Windows only).
    pub text_input: Arc<dyn TextInput>,
}

#[cfg(target_os = "linux")]
pub fn services(app: &AppHandle) -> Platform {
    Platform {
        screen: Arc::new(linux::LinuxScreen::new()),
        media: Arc::new(linux::LinuxMedia::new()),
        system: Arc::new(linux::LinuxSystem::new(app)),
        speech: Arc::new(linux::speech::LinuxSpeech::new()),
        dictation: Arc::new(Unavailable(
            "Spraakherkenning op deze computer zelf kan op Linux met whisper.cpp; kies anders een externe dienst.",
        )),
        wake: Arc::new(Unavailable("\"Hé Nook\" kan op Linux niet: er is geen zuinige spraakherkenning op de computer zelf.")),
        quiet: Arc::new(linux::LinuxQuiet::new()),
        power: Arc::new(linux::LinuxPower::new()),
        text_input: Arc::new(Unavailable("Aanvullen in elke app kan (nog) alleen op Windows.")),
    }
}

#[cfg(target_os = "windows")]
pub fn services(app: &AppHandle) -> Platform {
    Platform {
        screen: Arc::new(windows::WindowsScreen::new()),
        media: Arc::new(windows::WindowsMedia::new()),
        system: Arc::new(windows::WindowsSystem::new(app)),
        speech: Arc::new(windows::WindowsSpeech::new()),
        dictation: Arc::new(windows::WindowsDictation::new()),
        wake: Arc::new(windows::WindowsWake::new()),
        quiet: Arc::new(windows::WindowsQuiet),
        power: Arc::new(windows::WindowsPower::new()),
        text_input: Arc::new(windows::WindowsTextInput::new()),
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn services(app: &AppHandle) -> Platform {
    android::services(app)
}

/// Een melding van het systeem (Meldingencentrum op Windows, de notificatiedienst op Linux, Android).
pub fn notify(app: &AppHandle, title: &str, body: &str) {
    use tauri_plugin_notification::NotificationExt;
    if let Err(e) = app.notification().builder().title(title).body(body).show() {
        log::warn!("Melding kon niet getoond worden: {e}");
    }
}

/// Voor wat op een platform niet kan: elke aanroep zegt waarom.
#[cfg_attr(target_os = "windows", allow(dead_code))]
pub struct Unavailable(pub &'static str);

impl Dictation for Unavailable {
    fn available(&self) -> bool {
        false
    }
    fn start(&self, _language: &str) -> Result<(), String> {
        Err(self.0.into())
    }
    fn partial(&self) -> String {
        String::new()
    }
    fn stop(&self) -> Result<String, String> {
        Err(self.0.into())
    }
    fn cancel(&self) {}
}

impl WakeWord for Unavailable {
    fn available(&self) -> bool {
        false
    }
    fn start(&self, _on_wake: Box<dyn Fn() + Send + Sync>) -> Result<(), String> {
        Err(self.0.into())
    }
    fn stop(&self) {}
}

/// Without a platform layer: nothing to watch, so Nook never counts as sharing or in a call.
impl QuietWatch for Unavailable {}

/// Without power readings the energy plan only follows your choice and whether you are away.
impl PowerMonitor for Unavailable {}
impl TextInput for Unavailable {
    fn available(&self) -> bool {
        false
    }
    fn status(&self) -> String {
        self.0.into()
    }
    fn start(&self, _on_event: Arc<dyn Fn(InputEvent) + Send + Sync>) -> Result<(), String> {
        Err(self.0.into())
    }
    fn stop(&self) {}
    fn set_keys(&self, _word: Option<KeyChord>, _all: Option<KeyChord>) {}
    fn arm(&self, _armed: bool) {}
    fn focused_field(&self) -> Result<FocusedField, FieldSkip> {
        Err(FieldSkip::NoField)
    }
    fn type_text(&self, _text: &str) -> Result<(), String> {
        Err(self.0.into())
    }
}

impl SpeechOutput for Unavailable {
    fn available(&self) -> bool {
        false
    }
    fn speak(&self, _text: &str, _language: &str) -> Result<(), String> {
        Err(self.0.into())
    }
    fn enqueue(&self, _text: &str, _language: &str) -> Result<(), String> {
        Err(self.0.into())
    }
    fn stop(&self) {}
    fn speaking(&self) -> bool {
        false
    }
}

static MEASURED: std::sync::OnceLock<Capabilities> = std::sync::OnceLock::new();

/// Bewaart wat de diensten bij de start maten; daarna geeft [`capabilities`] dat terug.
pub fn set_measured(capabilities: Capabilities) {
    let _ = MEASURED.set(capabilities);
}

pub fn capabilities() -> Capabilities {
    if let Some(measured) = MEASURED.get() {
        return measured.clone();
    }
    let os = if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "android") {
        "android"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    };
    let desktop = cfg!(desktop);
    Capabilities {
        os: os.into(),
        desktop,
        screen_reading: false,
        global_shortcuts: desktop,
        tray: desktop,
        terminals: desktop,
        local_agents: desktop,
        media: false,
        ..Default::default()
    }
}

/// Wat de platformdiensten echt kunnen, gemeten bij de start (de interface verbergt de rest).
pub fn service_capabilities(platform: &Platform, base: &mut Capabilities) {
    let mut notes = std::collections::BTreeMap::new();
    base.screen_reading = platform.screen.available();
    let status = platform.screen.status();
    if !status.is_empty() {
        notes.insert("screenReading".to_string(), status);
    }
    base.speech_output = platform.speech.available();
    base.local_speech = platform.dictation.available();
    base.wake_word = platform.wake.available();
    base.share_detection = platform.quiet.available();
    // Tauri's content protection is `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` on Windows; Linux has no such thing.
    base.capture_exclusion = cfg!(target_os = "windows");
    base.autocomplete = platform.text_input.available();
    if !base.autocomplete {
        notes.insert("autocomplete".into(), platform.text_input.status());
    }
    #[cfg(desktop)]
    {
        base.media = true;
        base.screen_part = platform.screen.can_capture();
        base.microphone = audio::has_microphone();
        base.system_audio = audio::has_system_audio();
        base.open_apps = true;
        // Op Linux regelt Nook het volume via PipeWire, PulseAudio of ALSA; zonder een van die drie kan het niet.
        base.volume = !cfg!(target_os = "linux") || ["wpctl", "pactl", "amixer"].iter().any(|p| process::which(p));
        base.clipboard = true;
        base.notifications = true;
        base.files = true;
        base.flow = base.microphone;
        if !base.speech_output {
            notes.insert("speechOutput".into(), "Voorlezen kan niet: installeer espeak-ng of speech-dispatcher.".into());
        }
        if !base.microphone {
            notes.insert("microphone".into(), "Geen microfoon gevonden.".into());
        }
        if !base.system_audio {
            notes.insert(
                "systemAudio".into(),
                "Het geluid van de computer opnemen kan hier niet; de Notetaker neemt alleen je microfoon op.".into(),
            );
        }
        if !base.volume {
            notes.insert(
                "volume".into(),
                "Het volume regelen kan niet: installeer PipeWire (wpctl), PulseAudio (pactl) of ALSA (amixer).".into(),
            );
        }
        if !base.screen_part {
            notes.insert(
                "screenPart".into(),
                "Een schermdeel kan hier niet: er is geen schermafbeelding (Wayland laat dat apps niet toe).".into(),
            );
        }
    }
    if base.desktop && !base.share_detection {
        notes.insert(
            "shareDetection".into(),
            "Nook ziet hier niet wanneer je je scherm deelt: zonder X11 (Wayland) zijn de vensters van andere apps onzichtbaar. Een gesprek dat de Notetaker opneemt of een afspraak in je agenda telt wel.".into(),
        );
    }
    if base.desktop && !base.capture_exclusion {
        notes.insert(
            "captureExclusion".into(),
            "Op Linux kan Nook zich niet uit een gedeeld scherm of schermafbeelding halen; ‘Verbergen voor kijkers’ houdt hem hier alleen stil.".into(),
        );
    }
    if !base.wake_word {
        notes.insert("wakeWord".into(), "\"Hé Nook\" kan alleen waar de spraakherkenning op de computer zelf draait (Windows).".into());
    }
    base.notes = notes;
}
