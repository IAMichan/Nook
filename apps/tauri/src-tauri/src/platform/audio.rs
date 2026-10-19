//! Opnemen: de microfoon met cpal, en wat de computer afspeelt voor de Notetaker (WASAPI-loopback op Windows, de
//! monitor van PulseAudio/PipeWire via `parec` op Linux). Alles komt binnen als 16 kHz mono en blijft in het geheugen.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use nook_core::services::audio::Resampler;

pub type Sink = Box<dyn FnMut(&[f32]) + Send>;

/// Een lopende opname; stopt bij `stop()` of als hij weggaat.
pub struct Recording {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Recording {
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Of er een microfoon is.
pub fn has_microphone() -> bool {
    cpal::default_host().default_input_device().is_some_and(|d| d.default_input_config().is_ok())
}

/// Neemt op met de standaardmicrofoon.
pub fn microphone(sink: Sink) -> Result<Recording, String> {
    spawn_cpal(false, sink)
}

/// Neemt op wat de computer afspeelt.
pub fn system_audio(sink: Sink) -> Result<Recording, String> {
    #[cfg(target_os = "windows")]
    {
        spawn_cpal(true, sink)
    }
    #[cfg(not(target_os = "windows"))]
    {
        parec(sink)
    }
}

/// Of het geluid van de computer opgenomen kan worden.
pub fn has_system_audio() -> bool {
    if cfg!(target_os = "windows") {
        cpal::default_host().default_output_device().is_some()
    } else {
        super::process::which("parec")
    }
}

fn spawn_cpal(loopback: bool, mut sink: Sink) -> Result<Recording, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();
    let flag = stop.clone();
    let thread = std::thread::Builder::new()
        .name("nook-opname".into())
        .spawn(move || {
            let host = cpal::default_host();
            let device = if loopback { host.default_output_device() } else { host.default_input_device() };
            let Some(device) = device else {
                let _ =
                    ready_tx.send(Err(if loopback { "Geen geluidsuitgang gevonden.".into() } else { "Geen microfoon gevonden.".into() }));
                return;
            };
            let config = if loopback { device.default_output_config() } else { device.default_input_config() };
            let config = match config {
                Ok(c) => c,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("De microfoon is niet te gebruiken: {e}")));
                    return;
                }
            };
            let channels = config.channels() as usize;
            let rate = config.sample_rate().0;
            let format = config.sample_format();
            let stream_config: cpal::StreamConfig = config.into();
            let mut resampler = Resampler::new(rate, channels, 16_000);
            let mut deliver = move |samples: &[f32]| {
                let out = resampler.push(samples);
                if !out.is_empty() {
                    sink(&out);
                }
            };
            let error = |e: cpal::StreamError| log::warn!("Opname: {e}");
            let stream = match format {
                cpal::SampleFormat::F32 => device.build_input_stream(&stream_config, move |data: &[f32], _: &_| deliver(data), error, None),
                cpal::SampleFormat::I16 => device.build_input_stream(
                    &stream_config,
                    move |data: &[i16], _: &_| deliver(&data.iter().map(|s| *s as f32 / i16::MAX as f32).collect::<Vec<_>>()),
                    error,
                    None,
                ),
                cpal::SampleFormat::U16 => device.build_input_stream(
                    &stream_config,
                    move |data: &[u16], _: &_| deliver(&data.iter().map(|s| (*s as f32 - 32768.0) / 32768.0).collect::<Vec<_>>()),
                    error,
                    None,
                ),
                cpal::SampleFormat::I32 => device.build_input_stream(
                    &stream_config,
                    move |data: &[i32], _: &_| deliver(&data.iter().map(|s| *s as f32 / i32::MAX as f32).collect::<Vec<_>>()),
                    error,
                    None,
                ),
                other => {
                    let _ = ready_tx.send(Err(format!("Dit geluidsformaat ({other}) kent Nook niet.")));
                    return;
                }
            };
            let stream = match stream {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.send(Err(format!("Opnemen lukte niet: {e}")));
                    return;
                }
            };
            if let Err(e) = stream.play() {
                let _ = ready_tx.send(Err(format!("Opnemen lukte niet: {e}")));
                return;
            }
            let _ = ready_tx.send(Ok(()));
            while !flag.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(40));
            }
            drop(stream);
        })
        .map_err(|e| e.to_string())?;
    match ready_rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => Ok(Recording { stop, thread: Some(thread) }),
        Ok(Err(e)) => {
            let _ = thread.join();
            Err(e)
        }
        Err(_) => {
            stop.store(true, Ordering::SeqCst);
            Err("De microfoon reageert niet.".into())
        }
    }
}

#[cfg(not(target_os = "windows"))]
fn parec(mut sink: Sink) -> Result<Recording, String> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    if !super::process::which("parec") {
        return Err("Het geluid van de computer opnemen kan niet: parec (pulseaudio-utils, ook voor PipeWire) ontbreekt.".into());
    }
    let mut child = Command::new("parec")
        .args(["--device=@DEFAULT_MONITOR@", "--format=float32le", "--rate=16000", "--channels=1", "--latency-msec=100"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("parec kon niet starten: {e}"))?;
    let mut stdout = child.stdout.take().ok_or("Geen uitvoer van parec.")?;
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    let thread = std::thread::Builder::new()
        .name("nook-systeemgeluid".into())
        .spawn(move || {
            let mut buffer = vec![0u8; 6400];
            let mut rest: Vec<u8> = Vec::new();
            while !flag.load(Ordering::SeqCst) {
                match stdout.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        rest.extend_from_slice(&buffer[..n]);
                        let whole = rest.len() / 4 * 4;
                        let samples = nook_core::services::audio::f32_from_le(&rest[..whole]);
                        rest.drain(..whole);
                        sink(&samples);
                    }
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        })
        .map_err(|e| e.to_string())?;
    Ok(Recording { stop, thread: Some(thread) })
}
