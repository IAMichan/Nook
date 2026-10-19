//! Voorlezen op Linux met espeak-ng (of espeak, of speech-dispatcher). Eén zin tegelijk in een eigen draad, zodat
//! stoppen meteen werkt en zinnen achter elkaar kunnen terwijl het antwoord nog geschreven wordt.

use std::collections::VecDeque;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};

use nook_core::platform::SpeechOutput;

#[derive(Clone, Copy, PartialEq)]
enum Engine {
    EspeakNg,
    Espeak,
    SpdSay,
}

#[derive(Default)]
struct Shared {
    queue: VecDeque<(String, String)>,
    child: Option<Child>,
    busy: bool,
}

pub struct LinuxSpeech {
    engine: Option<Engine>,
    shared: Arc<(Mutex<Shared>, Condvar)>,
}

impl LinuxSpeech {
    pub fn new() -> Self {
        let engine = if crate::platform::process::which("espeak-ng") {
            Some(Engine::EspeakNg)
        } else if crate::platform::process::which("espeak") {
            Some(Engine::Espeak)
        } else if crate::platform::process::which("spd-say") {
            Some(Engine::SpdSay)
        } else {
            None
        };
        let shared = Arc::new((Mutex::new(Shared::default()), Condvar::new()));
        if let Some(engine) = engine {
            let worker = shared.clone();
            std::thread::Builder::new().name("nook-spraak".into()).spawn(move || run(engine, worker)).ok();
        }
        Self { engine, shared }
    }

    pub fn engine_name(&self) -> Option<&'static str> {
        self.engine.map(|e| match e {
            Engine::EspeakNg => "espeak-ng",
            Engine::Espeak => "espeak",
            Engine::SpdSay => "speech-dispatcher",
        })
    }
}

fn command(engine: Engine, text: &str, language: &str) -> Command {
    let short: String = language.chars().take(2).collect();
    let mut cmd = match engine {
        Engine::EspeakNg | Engine::Espeak => {
            let mut c = Command::new(if engine == Engine::EspeakNg { "espeak-ng" } else { "espeak" });
            c.args(["-v", &short, "-s", "165", "--", text]);
            c
        }
        Engine::SpdSay => {
            let mut c = Command::new("spd-say");
            c.args(["-w", "-l", &short, "--", text]);
            c
        }
    };
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    cmd
}

fn run(engine: Engine, shared: Arc<(Mutex<Shared>, Condvar)>) {
    let (lock, signal) = &*shared;
    loop {
        let (text, language) = {
            let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
            while state.queue.is_empty() {
                state.busy = false;
                state = signal.wait(state).unwrap_or_else(|e| e.into_inner());
            }
            state.busy = true;
            state.queue.pop_front().unwrap_or_default()
        };
        let Ok(child) = command(engine, &text, &language).spawn() else { continue };
        lock.lock().unwrap_or_else(|e| e.into_inner()).child = Some(child);
        // Wachten tot de zin uit is, zonder de lock vast te houden (stoppen moet het kind kunnen beëindigen).
        loop {
            let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
            match state.child.as_mut().map(|c| c.try_wait()) {
                Some(Ok(None)) => {}
                _ => {
                    state.child = None;
                    break;
                }
            }
            drop(state);
            std::thread::sleep(std::time::Duration::from_millis(60));
        }
    }
}

impl SpeechOutput for LinuxSpeech {
    fn available(&self) -> bool {
        self.engine.is_some()
    }

    fn speak(&self, text: &str, language: &str) -> Result<(), String> {
        self.stop();
        self.enqueue(text, language)
    }

    fn enqueue(&self, text: &str, language: &str) -> Result<(), String> {
        if self.engine.is_none() {
            return Err("Voorlezen kan niet: installeer espeak-ng of speech-dispatcher.".into());
        }
        let text: String = text.trim().chars().take(1200).collect();
        if text.is_empty() {
            return Ok(());
        }
        let (lock, signal) = &*self.shared;
        lock.lock().unwrap_or_else(|e| e.into_inner()).queue.push_back((text, language.into()));
        signal.notify_one();
        Ok(())
    }

    fn stop(&self) {
        let (lock, _) = &*self.shared;
        let mut state = lock.lock().unwrap_or_else(|e| e.into_inner());
        state.queue.clear();
        if let Some(child) = state.child.as_mut() {
            let _ = child.kill();
        }
        if self.engine == Some(Engine::SpdSay) {
            let _ = Command::new("spd-say").arg("-C").stdout(Stdio::null()).stderr(Stdio::null()).status();
        }
    }

    fn speaking(&self) -> bool {
        let (lock, _) = &*self.shared;
        let state = lock.lock().unwrap_or_else(|e| e.into_inner());
        state.busy || !state.queue.is_empty()
    }
}
