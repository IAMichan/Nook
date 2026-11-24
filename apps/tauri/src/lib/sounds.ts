// Korte geluiden: attention (een agent of Nook wacht op je), done (klaar) en error. Een eigen geluid in de map
// Geluiden gaat voor; anders een zacht ingebouwd toontje (zoals Ping, Glass en Basso op de Mac).
import { services } from "./services";
import { quiet } from "./quiet.svelte";
import { nook } from "./state.svelte";

export type SoundName = "attention" | "permission" | "done" | "error";

const custom = new Map<string, string | null>();
let context: AudioContext | null = null;
let playing: HTMLAudioElement | null = null;

/// Frequenties en duur per geluid: oplopend voor klaar, twee tikjes voor aandacht, laag voor een fout.
const tones: Record<SoundName, { freq: number; at: number; length: number }[]> = {
  attention: [{ freq: 880, at: 0, length: 0.12 }, { freq: 880, at: 0.16, length: 0.12 }],
  // A permission request: a rising pair, so it is told apart from a question (Hero vs Ping on the Mac).
  permission: [{ freq: 740, at: 0, length: 0.12 }, { freq: 1110, at: 0.14, length: 0.18 }],
  done: [{ freq: 660, at: 0, length: 0.14 }, { freq: 990, at: 0.1, length: 0.22 }],
  error: [{ freq: 196, at: 0, length: 0.32 }],
};

function synth(name: SoundName) {
  context ??= new AudioContext();
  const now = context.currentTime;
  for (const tone of tones[name]) {
    const osc = context.createOscillator();
    const gain = context.createGain();
    osc.type = name === "error" ? "triangle" : "sine";
    osc.frequency.value = tone.freq;
    gain.gain.setValueAtTime(0, now + tone.at);
    gain.gain.linearRampToValueAtTime(0.12, now + tone.at + 0.015);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + tone.at + tone.length);
    osc.connect(gain).connect(context.destination);
    osc.start(now + tone.at);
    osc.stop(now + tone.at + tone.length + 0.05);
  }
}

export async function play(name: SoundName, enabled = true) {
  // Silent while you share your screen or sit in a meeting, when you chose so.
  if (!enabled || quiet.silent) return;
  await playChoice(name, nook.settings?.soundChoices?.[name] ?? "");
}

/** Plays a moment's sound as `choice` sets it (Settings › Sound & voice): "" is Nook's own (your file first), "file" your
 *  file, "none" nothing, anything else a system sound. The settings page calls this to let you hear a choice. */
export async function playChoice(name: SoundName, choice: string) {
  if (choice === "none") return;
  const key = `${name}:${choice}`;
  if (!custom.has(key)) custom.set(key, await services.soundFile(name, choice).catch(() => null));
  const file = custom.get(key);
  if (file) {
    playing?.pause();
    playing = new Audio(file);
    playing.volume = 0.8;
    await playing.play().catch(() => synth(name));
    return;
  }
  try {
    synth(name);
  } catch {
    // Geen geluid in deze omgeving: niets aan de hand.
  }
}

/// Na het neerzetten van een eigen geluid opnieuw kijken.
export function forgetCustomSounds() {
  custom.clear();
}
