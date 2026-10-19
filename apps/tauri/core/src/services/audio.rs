//! Audio voor spraakherkenning: naar 16 kHz mono, en als WAV voor een herkenning die een bestand wil.

/// Mono uit een buffer met `channels` kanalen door elkaar.
pub fn downmix(samples: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return samples.to_vec();
    }
    samples.chunks(channels).map(|frame| frame.iter().sum::<f32>() / frame.len() as f32).collect()
}

/// Lineair herbemonsteren naar `to` Hz. Goed genoeg voor spraak; voor muziek zou je filteren.
pub fn resample(samples: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || samples.is_empty() || from == 0 {
        return samples.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let count = (samples.len() as f64 / ratio).floor() as usize;
    (0..count)
        .map(|i| {
            let position = i as f64 * ratio;
            let index = position as usize;
            let fraction = (position - index as f64) as f32;
            let a = samples[index.min(samples.len() - 1)];
            let b = samples[(index + 1).min(samples.len() - 1)];
            a + (b - a) * fraction
        })
        .collect()
}

/// Houdt het herbemonsteren gelijk over opeenvolgende buffers (geen klik op de grens).
#[derive(Debug, Clone)]
pub struct Resampler {
    from: u32,
    to: u32,
    channels: usize,
    position: f64,
    last: f32,
}

impl Resampler {
    pub fn new(from: u32, channels: usize, to: u32) -> Self {
        Self { from, to, channels: channels.max(1), position: 0.0, last: 0.0 }
    }

    /// Een buffer van het apparaat (kanalen door elkaar) → 16 kHz mono.
    pub fn push(&mut self, interleaved: &[f32]) -> Vec<f32> {
        let mono = downmix(interleaved, self.channels);
        if self.from == self.to {
            return mono;
        }
        let step = self.from as f64 / self.to as f64;
        let mut out = Vec::with_capacity((mono.len() as f64 / step) as usize + 1);
        // `position` is relatief aan het eerste sample van deze buffer; -1 is het laatste van de vorige.
        while self.position < mono.len() as f64 - 1.0 {
            let index = self.position.floor();
            let fraction = (self.position - index) as f32;
            let a = if index < 0.0 { self.last } else { mono[index as usize] };
            let b = mono[(index + 1.0) as usize];
            out.push(a + (b - a) * fraction);
            self.position += step;
        }
        self.position -= mono.len() as f64;
        if let Some(last) = mono.last() {
            self.last = *last;
        }
        out
    }
}

/// 16-bit PCM WAV, mono.
pub fn wav(samples: &[f32], rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for sample in samples {
        let value = (sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        out.extend_from_slice(&value.to_le_bytes());
    }
    out
}

/// Ruwe 32-bit float little-endian (wat `parec --format=float32le` geeft) naar samples.
pub fn f32_from_le(bytes: &[u8]) -> Vec<f32> {
    bytes.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mono_and_sixteen_khz() {
        assert_eq!(downmix(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
        let one_second: Vec<f32> = (0..48_000).map(|i| (i as f32 / 48.0).sin()).collect();
        assert_eq!(resample(&one_second, 48_000, 16_000).len(), 16_000);
        let mut r = Resampler::new(48_000, 1, 16_000);
        let total: usize = one_second.chunks(480).map(|c| r.push(c).len()).sum();
        assert!((15_990..=16_010).contains(&total), "{total}");
    }

    #[test]
    fn wav_header() {
        let bytes = wav(&[0.0, 1.0, -1.0], 16_000);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(bytes.len(), 44 + 6);
        assert_eq!(i16::from_le_bytes([bytes[46], bytes[47]]), i16::MAX);
        assert_eq!(f32_from_le(&1.5f32.to_le_bytes()), vec![1.5]);
    }
}
