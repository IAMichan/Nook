#!/usr/bin/env python3
"""Calm ambient score for Nook videos, generated from scratch so it is free to use anywhere.

Warm, slowly breathing pads over a soft bass, a few sparse bells, and quiet sound cues that land on the moments the
video marks (the notch opening, a state turning to done or merged, the closing card). No drums, no sharp attacks:
the music should feel like Nook itself, calm and in the background.

    python3 music.py --duration 25 --cues '[{"t":0.4,"sound":"open"}]' --out score.wav

Cue sounds: open (an airy swell), chime (two soft bells), done (a gentle rising pair), merge (three rising notes),
end (a low warm bell), tick. With --bpm the score gets a soft lo-fi groove (plucked arpeggio, round kick, snap, a
whisper of hi-hat) for videos that cut on the beat. Only numpy is needed.
"""
import argparse
import json
import wave

import numpy as np

SR = 48000


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


# Progressions as (bass, pad voicing) in MIDI notes. Major sevenths and ninths: open and unresolved, never sad.
PROGRESSIONS = {
    # Fmaj9 – Cmaj9/E – Am9 – Bbmaj9
    "calm": [(41, [53, 57, 60, 64, 67]), (40, [52, 55, 59, 62, 67]), (45, [57, 60, 64, 67, 71]), (46, [58, 62, 65, 69, 72])],
    # Dbmaj9 – Ab/C – Fm9 – Gbmaj7#11: a little warmer and darker
    "warm": [(37, [49, 53, 56, 60, 63]), (36, [48, 51, 56, 60, 63]), (41, [53, 56, 60, 63, 67]), (42, [54, 58, 61, 65, 72])],
    # Cmaj9 – Gsus/B – Am7 – Fmaj9: brighter, for launches and good news
    "bright": [(36, [55, 59, 62, 64, 67]), (35, [55, 59, 62, 64, 69]), (45, [57, 60, 64, 67, 72]), (41, [57, 60, 64, 67, 69])],
}


def lowpass(x, cutoff):
    """Gentle one-pole-like low-pass in the frequency domain (works on long signals at once)."""
    n = len(x)
    spec = np.fft.rfft(x, n)
    f = np.fft.rfftfreq(n, 1 / SR)
    spec *= 1 / np.sqrt(1 + (f / cutoff) ** 2)
    return np.fft.irfft(spec, n)


def bandpass(x, lo, hi):
    n = len(x)
    spec = np.fft.rfft(x, n)
    f = np.fft.rfftfreq(n, 1 / SR)
    spec *= np.exp(-0.5 * ((np.log(np.maximum(f, 1)) - np.log(np.sqrt(lo * hi))) / (np.log(hi / lo) / 2)) ** 2)
    return np.fft.irfft(spec, n)


def envelope(n, attack, release, total):
    """Sine-shaped attack, hold, sine-shaped release; `total` samples long with the note lasting `n`."""
    env = np.ones(total)
    a = min(int(attack * SR), n)
    env[:a] = 0.5 - 0.5 * np.cos(np.pi * np.arange(a) / max(a, 1))
    r = total - n
    if r > 0:
        env[n:] = 0.5 + 0.5 * np.cos(np.pi * np.arange(r) / r)
    return env


def bell(f, length, rng, decay=1.6, bright=1.0):
    t = np.arange(int(length * SR)) / SR
    ph = rng.uniform(0, 2 * np.pi, 3)
    tone = (np.sin(2 * np.pi * f * t + ph[0]) * np.exp(-t / decay)
            + 0.30 * bright * np.sin(2 * np.pi * 2.0 * f * t + ph[1]) * np.exp(-t / (decay * 0.35))
            + 0.10 * bright * np.sin(2 * np.pi * 2.76 * f * t + ph[2]) * np.exp(-t / (decay * 0.18)))
    attack = np.minimum(1, t / 0.006)
    return tone * attack


def add(bus, sig, at, pan=0.0, gain=1.0):
    i = int(at * SR)
    if i >= bus.shape[1] or i < 0:
        return
    sig = sig[: bus.shape[1] - i] * gain
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    bus[0, i:i + len(sig)] += sig * left * np.sqrt(2)
    bus[1, i:i + len(sig)] += sig * right * np.sqrt(2)


def reverb(bus, rng, seconds=3.2, wet=0.35):
    n_ir = int(seconds * SR)
    t = np.arange(n_ir) / SR
    tau = seconds / 6.9
    out = np.zeros_like(bus)
    for ch in range(2):
        ir = rng.standard_normal(n_ir) * np.exp(-t / tau)
        ir[: int(0.022 * SR)] = 0  # pre-delay
        ir = lowpass(ir, 4200)
        ir /= np.sqrt(np.sum(ir ** 2))
        n = 1 << int(np.ceil(np.log2(bus.shape[1] + n_ir)))
        wet_sig = np.fft.irfft(np.fft.rfft(bus[ch], n) * np.fft.rfft(ir, n), n)[: bus.shape[1]]
        out[ch] = bus[ch] * (1 - wet) + wet_sig * wet * 1.6
    return out


def score(duration, cues, mood="calm", seed=7, chord_len=6.0, bells=True, bpm=None, drums_from=None, drums_until=None):
    rng = np.random.default_rng(seed)
    total = int((duration + 0.05) * SR)
    pads = np.zeros((2, total))
    bass = np.zeros((2, total))
    sparkle = np.zeros((2, total))
    prog = PROGRESSIONS[mood]
    release, attack = 2.6, 2.0
    if bpm:
        # Groove: a chord per bar so the harmony moves with the beat; quicker swells so changes land on the one.
        chord_len, release, attack, bells = 4 * 60 / bpm, 1.4, 0.45, False

    # Pads and bass: each chord swells in and lets go slowly, so changes are crossfades, never cuts.
    k = 0
    start = 0.0
    while start < duration:
        root, voicing = prog[k % len(prog)]
        n = int(chord_len * SR)
        length = n + int(release * SR)
        t = np.arange(length) / SR
        env = envelope(n, attack, release, length)
        for j, note in enumerate(voicing):
            f = hz(note)
            voice = np.zeros(length)
            for cents in (-5, 0, 5):
                ff = f * 2 ** (cents / 1200)
                p = rng.uniform(0, 2 * np.pi)
                voice += np.sin(2 * np.pi * ff * t + p) + 0.16 * np.sin(4 * np.pi * ff * t + p) + 0.05 * np.sin(6 * np.pi * ff * t + p)
            # Each note breathes on its own slow cycle, so the chord moves without anything being played.
            lfo = 1 + 0.18 * np.sin(2 * np.pi * rng.uniform(0.07, 0.16) * t + rng.uniform(0, 6.3))
            add(pads, voice * env * lfo / 3, start, pan=(-0.35 if j % 2 else 0.35) * (0.4 + 0.6 * j / len(voicing)), gain=0.075)
        fb = hz(root)
        b = (np.sin(2 * np.pi * fb * t) + 0.12 * np.sin(4 * np.pi * fb * t)) * envelope(n, min(1.4, attack), release, length)
        add(bass, b, start, gain=0.11)

        # Sparse bells from the chord's own notes, an octave or two up: a few per chord, never on a grid.
        if bells:
            beat = 60 / 64
            for s in range(int(chord_len / beat)):
                if rng.random() < 0.38:
                    note = voicing[rng.integers(1, len(voicing))] + 12 * rng.integers(1, 3)
                    at = start + s * beat + rng.uniform(-0.05, 0.05)
                    if 1.0 < at < duration - 3.0:
                        add(sparkle, bell(hz(min(note, 88)), 3.0, rng, decay=1.3), at, pan=rng.uniform(-0.5, 0.5), gain=0.045)
        start += chord_len
        k += 1

    pads[0] = lowpass(pads[0], 1700)
    pads[1] = lowpass(pads[1], 1700)

    # Cues: quiet, bell-like, tuned to whatever chord is sounding at that moment.
    fx = np.zeros((2, total))
    for cue in cues:
        at, sound = float(cue["t"]), cue.get("sound", "chime")
        gain = float(cue.get("gain", 1.0))
        root, voicing = prog[int(at // chord_len) % len(prog)]
        tones = sorted(voicing)
        if sound == "open":
            length = int(1.8 * SR)
            t = np.arange(length) / SR
            air = bandpass(rng.standard_normal(length), 500, 2600)
            env = np.where(t < 0.7, np.sin(np.pi / 2 * t / 0.7) ** 2, np.exp(-(t - 0.7) / 0.35))
            add(fx, air * env / np.max(np.abs(air)), at - 0.35, gain=0.05 * gain)
            add(fx, bell(hz(tones[0] + 12), 3.0, rng, decay=1.8, bright=0.5), at + 0.25, gain=0.08 * gain)
        elif sound == "chime":
            add(fx, bell(hz(tones[2] + 12), 3.0, rng), at, pan=-0.2, gain=0.08 * gain)
            add(fx, bell(hz(tones[4] + 12), 3.0, rng), at + 0.14, pan=0.2, gain=0.07 * gain)
        elif sound == "done":
            add(fx, bell(hz(tones[1] + 12), 3.0, rng), at, pan=-0.15, gain=0.08 * gain)
            add(fx, bell(hz(tones[3] + 12), 3.0, rng), at + 0.16, pan=0.15, gain=0.08 * gain)
        elif sound == "merge":
            for i, idx in enumerate((0, 2, 4)):
                add(fx, bell(hz(tones[idx] + 24 if idx < 4 else tones[idx] + 12), 3.0, rng), at + i * 0.17, pan=-0.3 + 0.3 * i, gain=0.075 * gain)
        elif sound == "end":
            add(fx, bell(hz(root + 24), 4.0, rng, decay=2.6, bright=0.6), at, gain=0.11 * gain)
            add(fx, bell(hz(tones[2] + 12), 4.0, rng, decay=2.2, bright=0.4), at + 0.09, gain=0.06 * gain)
        elif sound == "tick":
            add(fx, bell(hz(tones[4] + 24), 0.4, rng, decay=0.05, bright=0.2), at, pan=rng.uniform(-0.3, 0.3), gain=0.02 * gain)

    drums = np.zeros((2, total))
    if bpm:
        groove(pads, bass, sparkle, drums, prog, bpm, duration, rng,
               drums_from if drums_from is not None else 0.0, drums_until if drums_until is not None else duration)

    mix = pads + bass + drums + reverb(sparkle + fx, rng, wet=0.45) * 1.0
    mix = reverb(mix, np.random.default_rng(seed + 1), seconds=2.4, wet=0.2)

    # Fade in (quickly for a groove, whose first second is the hook) and out over the last 3 s; then a soft limiter.
    t = np.arange(total) / SR
    fade = np.minimum(1, t / (0.5 if bpm else 2.0)) * np.clip((duration - t) / 3.0, 0, 1)
    fade = 0.5 - 0.5 * np.cos(np.pi * fade)
    mix *= fade
    mix = np.tanh(mix * 1.2) / 1.2
    peak = np.max(np.abs(mix)) or 1
    return mix / peak * 10 ** (-3 / 20)


def groove(pads, bass, sparkle, drums, prog, bpm, duration, rng, drums_from, drums_until):
    """A soft lo-fi pulse: a plucked arpeggio from the first bar, and from `drums_from` a round kick on 1 and 3, a
    finger snap on 2 and 4 and a whisper of hi-hat on the off-beats, slightly swung. The pads dip gently on each kick
    so the whole thing breathes with the beat. Still calm: nothing hits hard, nothing is bright."""
    beat = 60 / bpm
    bar = 4 * beat
    swing = 0.06 * beat

    tk = np.arange(int(0.45 * SR)) / SR
    kick = np.sin(2 * np.pi * np.cumsum(46 + 64 * np.exp(-tk / 0.035)) / SR) * np.exp(-tk / 0.17)
    kick *= np.minimum(1, tk / 0.002)
    ts = np.arange(int(0.3 * SR)) / SR
    snap = bandpass(rng.standard_normal(len(ts)), 1300, 4200) * np.exp(-ts / 0.045)
    snap = snap / np.max(np.abs(snap)) + 0.35 * np.sin(2 * np.pi * 190 * ts) * np.exp(-ts / 0.03)
    th = np.arange(int(0.08 * SR)) / SR
    hat = bandpass(rng.standard_normal(len(th)), 6000, 12000) * np.exp(-th / 0.018)
    hat /= np.max(np.abs(hat))

    duck = np.ones(pads.shape[1])
    arp = (0, 2, 4, 2, 1, 3, 4, 3)
    n_bars = int(np.ceil(duration / bar))
    for b in range(n_bars):
        root, voicing = prog[b % len(prog)]
        tones = sorted(voicing)
        for step in range(8):
            at = b * bar + step * beat / 2 + (swing if step % 2 else 0)
            if at > duration - 1.5:
                break
            f = hz(tones[arp[step]] + 12)
            tp = np.arange(int(0.9 * SR)) / SR
            pl = (np.sin(2 * np.pi * f * tp) + 0.45 * np.sin(4 * np.pi * f * tp) * np.exp(-tp / 0.07)
                  + 0.2 * np.sin(6 * np.pi * f * tp) * np.exp(-tp / 0.04)) * np.exp(-tp / 0.3) * np.minimum(1, tp / 0.004)
            accent = 1.0 if step % 4 == 0 else 0.75
            add(sparkle, pl, at, pan=0.35 if step % 2 else -0.35, gain=0.05 * accent)
        if not (drums_from - 1e-3 <= b * bar < drums_until - 1e-3):
            continue
        for k_at in (0, 2) + ((2.5,) if b % 2 else ()):
            at = b * bar + k_at * beat
            add(drums, kick, at, gain=0.34 if k_at != 2.5 else 0.2)
            i = int(at * SR)
            d = np.arange(pads.shape[1] - i) / SR
            duck[i:] *= 1 - 0.28 * np.exp(-d / 0.16)[: pads.shape[1] - i]
        for s_at in (1, 3):
            add(sparkle, snap, b * bar + s_at * beat, pan=0.1, gain=0.055)
        for h in range(8):
            if h % 2:
                add(drums, hat, b * bar + h * beat / 2 + swing, pan=0.25, gain=0.012)
    pads *= duck
    bass *= duck


def write_wav(path, stereo):
    data = (np.clip(stereo.T, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--duration", type=float, required=True, help="length in seconds")
    ap.add_argument("--cues", default="[]", help='JSON list like [{"t":1.2,"sound":"chime"}]')
    ap.add_argument("--mood", default="calm", choices=sorted(PROGRESSIONS), help="chord progression")
    ap.add_argument("--chord", type=float, default=6.0, help="seconds per chord (slower is calmer)")
    ap.add_argument("--seed", type=int, default=7, help="same seed, same music")
    ap.add_argument("--no-bells", action="store_true", help="pads only")
    ap.add_argument("--bpm", type=float, help="adds a soft lo-fi groove at this tempo (80-90 feels relaxed)")
    ap.add_argument("--drums-from", type=float, help="seconds where the drums come in (the 'drop'); default: start")
    ap.add_argument("--drums-until", type=float, help="seconds where the drums stop; default: the end")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    write_wav(a.out, score(a.duration, json.loads(a.cues), a.mood, a.seed, a.chord, not a.no_bells,
                              a.bpm, a.drums_from, a.drums_until))


if __name__ == "__main__":
    main()
