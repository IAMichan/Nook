//! "Hé Nook" without wasting power (`WakeWordService` on the Mac): the microphone only measures loudness until someone
//! speaks, speech recognition runs for that stretch only, and listening pauses while the screen is locked or asleep, in
//! battery saver and while the battery runs low (and Nook may spare it). It comes back by itself.

use super::energy::EnergyMode;
use super::vad::{self, EnergyVad, VadEvent};

/// At or below this charge on battery, the battery counts as low (Windows warns at the same point).
pub const LOW_BATTERY_AT: u8 = 20;
/// The charge the battery has to climb back above before it no longer counts as low, so a battery that hovers around
/// the line does not flip the wake word on and off.
pub const LOW_BATTERY_CLEARS_AT: u8 = 25;

/// Whether the battery counts as low now, given whether it did on the last reading. On the charger it never does.
pub fn is_low_battery(level: Option<u8>, on_battery: bool, was_low: bool) -> bool {
    match (on_battery, level) {
        (true, Some(level)) => level <= if was_low { LOW_BATTERY_CLEARS_AT } else { LOW_BATTERY_AT },
        _ => false,
    }
}

/// What the computer says right now.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Signals {
    pub screen_locked: bool,
    pub display_asleep: bool,
    /// The system's battery saver.
    pub low_power_mode: bool,
    pub low_battery: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PauseReason {
    Locked,
    DisplayAsleep,
    LowPowerMode,
    LowBattery,
}

/// Why listening waits, if it does. A nearly empty battery only counts when you did not tell Nook to keep going at full
/// power (`EnergyMode::Full`); the lock, a sleeping display and battery saver always count.
pub fn pause_reason(signals: &Signals, mode: EnergyMode) -> Option<PauseReason> {
    if signals.screen_locked {
        Some(PauseReason::Locked)
    } else if signals.display_asleep {
        Some(PauseReason::DisplayAsleep)
    } else if signals.low_power_mode {
        Some(PauseReason::LowPowerMode)
    } else if signals.low_battery && mode != EnergyMode::Full {
        Some(PauseReason::LowBattery)
    } else {
        None
    }
}

/// What the loudness check asks of speech recognition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    None,
    /// Someone speaks: recognise this stretch.
    Open,
    /// Silence again: recognition stops.
    Close,
}

/// Loudness in frames of a tenth of a second, as [`EnergyVad`] wants them. Samples are 16 kHz mono.
pub struct LoudnessGate {
    vad: EnergyVad,
    pending: Vec<f32>,
}

/// Samples in one frame: a tenth of a second at 16 kHz.
const FRAME: usize = 1600;

impl Default for LoudnessGate {
    fn default() -> Self {
        let mut vad = EnergyVad::default();
        vad.set_frame_rate(10.0);
        Self { vad, pending: Vec::new() }
    }
}

impl LoudnessGate {
    /// Feeds a chunk of the microphone; returns the last change it caused (a chunk is far shorter than a stretch).
    pub fn feed(&mut self, samples: &[f32]) -> Gate {
        self.pending.extend_from_slice(samples);
        let mut gate = Gate::None;
        while self.pending.len() >= FRAME {
            let frame: Vec<f32> = self.pending.drain(..FRAME).collect();
            match self.vad.feed(vad::power(&frame)) {
                VadEvent::Start => gate = Gate::Open,
                VadEvent::End => gate = Gate::Close,
                VadEvent::None => {}
            }
        }
        gate
    }

    /// Back to silent, keeping the learned noise floor.
    pub fn reset(&mut self) {
        self.vad.reset();
        self.pending.clear();
    }
}

/// Default RMS loudness threshold before running wake-word speech recognition (`SV-51`).
pub const DEFAULT_LOUDNESS_THRESHOLD: f32 = 0.008;

/// Whether wake-word listening should run given current system/battery signals and Nook's energy mode (`SV-51`).
pub fn should_listen(signals: &Signals, mode: EnergyMode) -> bool {
    pause_reason(signals, mode).is_none()
}

/// Fast RMS loudness check on raw 16 kHz mono samples (`SV-51`): returns `true` only when the audio buffer carries
/// enough speech energy to justify waking the recognizer.
pub fn loudness_passes(samples: &[f32], threshold: f32) -> bool {
    if samples.is_empty() {
        return false;
    }
    let rms = vad::power(samples).sqrt() as f32;
    rms >= threshold.max(0.0001)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_battery_has_to_recover_before_it_stops_counting_as_low() {
        assert!(is_low_battery(Some(20), true, false));
        assert!(!is_low_battery(Some(21), true, false));
        assert!(is_low_battery(Some(24), true, true));
        assert!(!is_low_battery(Some(26), true, true));
        assert!(!is_low_battery(Some(5), false, true));
        assert!(!is_low_battery(None, true, false));
    }

    #[test]
    fn listening_waits_for_the_lock_the_saver_and_a_low_battery() {
        let none = Signals::default();
        assert_eq!(pause_reason(&none, EnergyMode::Automatic), None);
        assert!(should_listen(&none, EnergyMode::Automatic));
        assert_eq!(pause_reason(&Signals { screen_locked: true, ..none }, EnergyMode::Full), Some(PauseReason::Locked));
        assert!(!should_listen(&Signals { screen_locked: true, ..none }, EnergyMode::Full));
        assert_eq!(pause_reason(&Signals { display_asleep: true, ..none }, EnergyMode::Automatic), Some(PauseReason::DisplayAsleep));
        assert_eq!(pause_reason(&Signals { low_power_mode: true, ..none }, EnergyMode::Full), Some(PauseReason::LowPowerMode));
        let low = Signals { low_battery: true, ..none };
        assert_eq!(pause_reason(&low, EnergyMode::Automatic), Some(PauseReason::LowBattery));
        assert_eq!(pause_reason(&low, EnergyMode::Saver), Some(PauseReason::LowBattery));
        assert_eq!(pause_reason(&low, EnergyMode::Full), None);
        assert!(should_listen(&low, EnergyMode::Full));
    }

    fn tone(frames: usize, amplitude: f32) -> Vec<f32> {
        (0..frames * FRAME).map(|i| amplitude * (i as f32 * 0.3).sin()).collect()
    }

    #[test]
    fn speech_opens_the_gate_and_silence_closes_it() {
        let mut gate = LoudnessGate::default();
        // The noise floor is learned from a quiet room first.
        assert_eq!(gate.feed(&tone(30, 0.001)), Gate::None);
        assert_eq!(gate.feed(&tone(3, 0.3)), Gate::Open);
        let mut closed = false;
        for _ in 0..30 {
            if gate.feed(&tone(1, 0.001)) == Gate::Close {
                closed = true;
            }
        }
        assert!(closed);
    }

    #[test]
    fn a_partial_frame_waits_for_the_rest() {
        let mut gate = LoudnessGate::default();
        assert_eq!(gate.feed(&[0.0; 100]), Gate::None);
        gate.reset();
    }

    #[test]
    fn loudness_passes_filters_silence_and_accepts_speech() {
        assert!(!loudness_passes(&[], DEFAULT_LOUDNESS_THRESHOLD));
        assert!(!loudness_passes(&tone(1, 0.001), DEFAULT_LOUDNESS_THRESHOLD));
        assert!(loudness_passes(&tone(1, 0.08), DEFAULT_LOUDNESS_THRESHOLD));
    }
}
