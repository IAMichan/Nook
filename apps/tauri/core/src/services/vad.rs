//! Spraakdetectie op energie, voor "Hé Nook" en de Notetaker: de herkenning draait alleen terwijl iemand praat, dus de
//! microfoon kost in stilte bijna niets. Zelfde algoritme als `EnergyVAD` op de Mac (naar open-source code onder de
//! MIT-licentie, © 2026 Louis Raillé; zie THIRD-PARTY-NOTICES.md).
//!
//! - IJken (~0,5 s): de ruisvloer snel leren, nog niets starten.
//! - Daarna drijft de ruisvloer langzaam mee; een stuk begint als het vermogen boven ruis×8 komt.
//! - Een stuk duurt hooguit ~30 s, zodat de detectie nooit blijft hangen.
//! - `reset()` na een stuk wist de tellers maar houdt de geleerde ruisvloer.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VadEvent {
    None,
    Start,
    End,
}

const REFERENCE_RATE: f64 = 43.0;
const CALIB_FRAMES: usize = 22;
const RISE_RATIO: f64 = 8.0;
const FALL_RATIO: f64 = 2.0;
const SILENCE_FRAMES: usize = 35;
const MAX_ACTIVE_FRAMES: usize = 1300;

#[derive(Debug, Clone)]
pub struct EnergyVad {
    calib_limit: usize,
    silence_limit: usize,
    active_limit: usize,
    k_calib: f64,
    k_idle: f64,
    k_silent: f64,
    frame_rate: f64,
    active: bool,
    noise_power: f64,
    calib_count: usize,
    silent_count: usize,
    active_count: usize,
    segment_sum: f64,
    segment_count: usize,
}

impl Default for EnergyVad {
    fn default() -> Self {
        Self {
            calib_limit: CALIB_FRAMES,
            silence_limit: SILENCE_FRAMES,
            active_limit: MAX_ACTIVE_FRAMES,
            k_calib: 0.15,
            k_idle: 0.005,
            k_silent: 0.001,
            frame_rate: REFERENCE_RATE,
            active: false,
            noise_power: 1e-7,
            calib_count: 0,
            silent_count: 0,
            active_count: 0,
            segment_sum: 0.0,
            segment_count: 0,
        }
    }
}

impl EnergyVad {
    /// Buffers per seconde die echt binnenkomen; houdt dezelfde duur (0,5 s ijken, 0,8 s stilte, 30 s maximaal).
    pub fn set_frame_rate(&mut self, fps: f64) {
        if fps <= 1.0 {
            return;
        }
        self.frame_rate = fps;
        let r = fps / REFERENCE_RATE;
        let scaled = |frames: usize| ((frames as f64 * r).round() as usize).max(1);
        self.calib_limit = scaled(CALIB_FRAMES);
        self.silence_limit = scaled(SILENCE_FRAMES);
        self.active_limit = scaled(MAX_ACTIVE_FRAMES);
        let k = |per_ref: f64| 1.0 - (1.0 - per_ref).powf(1.0 / r);
        self.k_calib = k(0.15);
        self.k_idle = k(0.005);
        self.k_silent = k(0.001);
    }

    pub fn is_active(&self) -> bool {
        self.active
    }

    pub fn frame_rate(&self) -> f64 {
        self.frame_rate
    }

    /// Terug naar stil; de geijkte ruisvloer blijft.
    pub fn reset(&mut self) {
        self.active = false;
        self.silent_count = 0;
        self.active_count = 0;
        self.segment_sum = 0.0;
        self.segment_count = 0;
    }

    /// Eén buffer: het gemiddelde kwadraat van de samples. Zegt of een stuk begon of eindigde.
    pub fn feed(&mut self, power: f64) -> VadEvent {
        if self.calib_count < self.calib_limit {
            self.calib_count += 1;
            self.noise_power = self.noise_power * (1.0 - self.k_calib) + power * self.k_calib;
            return VadEvent::None;
        }
        if !self.active {
            self.noise_power = self.noise_power * (1.0 - self.k_idle) + power * self.k_idle;
            if power > self.noise_power * RISE_RATIO {
                self.active = true;
                self.silent_count = 0;
                self.active_count = 0;
                self.segment_sum = power;
                self.segment_count = 1;
                return VadEvent::Start;
            }
            return VadEvent::None;
        }
        self.active_count += 1;
        self.segment_sum += power;
        self.segment_count += 1;
        if self.active_count >= self.active_limit {
            // Doorlopend geluid (muziek, ruis): dat is het nieuwe achtergrondniveau.
            if self.segment_count > 0 {
                self.noise_power = self.segment_sum / self.segment_count as f64;
            }
            self.reset();
            return VadEvent::End;
        }
        if power < self.noise_power * FALL_RATIO {
            self.silent_count += 1;
            self.noise_power = self.noise_power * (1.0 - self.k_silent) + power * self.k_silent;
            if self.silent_count >= self.silence_limit {
                self.active = false;
                self.silent_count = 0;
                self.active_count = 0;
                return VadEvent::End;
            }
        } else {
            self.silent_count = 0;
        }
        VadEvent::None
    }
}

/// Het gemiddelde kwadraat van een buffer, voor [`EnergyVad::feed`].
pub fn power(samples: &[f32]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    samples.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>() / samples.len() as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speech_starts_and_silence_ends() {
        let mut vad = EnergyVad::default();
        vad.set_frame_rate(10.0);
        for _ in 0..10 {
            assert_eq!(vad.feed(1e-6), VadEvent::None, "ijken op stilte");
        }
        assert_eq!(vad.feed(1e-6), VadEvent::None);
        assert_eq!(vad.feed(1e-3), VadEvent::Start, "een stem ver boven de ruis");
        for _ in 0..5 {
            vad.feed(1e-3);
        }
        let ended = (0..12).any(|_| vad.feed(1e-6) == VadEvent::End);
        assert!(ended, "ongeveer 0,8 s stilte eindigt het stuk");
        assert!(!vad.is_active());
    }

    #[test]
    fn a_noisy_room_is_not_speech() {
        let mut vad = EnergyVad::default();
        vad.set_frame_rate(10.0);
        // Een vaste reeks in plaats van toeval: 0,8…1,2 keer hetzelfde niveau.
        for i in 0..200 {
            let jitter = 0.8 + 0.4 * ((i * 37 % 100) as f64 / 100.0);
            assert_ne!(vad.feed(2e-4 * jitter), VadEvent::Start);
        }
    }

    #[test]
    fn power_is_mean_square() {
        assert_eq!(power(&[]), 0.0);
        assert!((power(&[0.5, -0.5]) - 0.25).abs() < 1e-9);
    }
}
