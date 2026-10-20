// Geluiden van Nook (`NookSound` op de Mac): attention, done, error. Een eigen bestand in <Nook-map>/Sounds wint;
// anders een kort toontje met WebAudio.
import { agentApi } from "./agents";
import { quiet } from "./quiet.svelte";

export type SoundKind = "attention" | "done" | "error";

const custom = new Map<SoundKind, string | null>();
let context: AudioContext | null = null;

function tone(ctx: AudioContext, freq: number, start: number, length: number, gain = 0.12) {
  const osc = ctx.createOscillator();
  const g = ctx.createGain();
  osc.type = "sine";
  osc.frequency.value = freq;
  g.gain.setValueAtTime(0, ctx.currentTime + start);
  g.gain.linearRampToValueAtTime(gain, ctx.currentTime + start + 0.01);
  g.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + start + length);
  osc.connect(g).connect(ctx.destination);
  osc.start(ctx.currentTime + start);
  osc.stop(ctx.currentTime + start + length + 0.05);
}

export async function playSound(kind: SoundKind) {
  // Silent while you share your screen or sit in a meeting, when you chose so.
  if (quiet.silent) return;
  try {
    if (!custom.has(kind)) custom.set(kind, await agentApi.sound(kind));
    const file = custom.get(kind);
    if (file) {
      await new Audio(file).play();
      return;
    }
    context ??= new AudioContext();
    if (context.state === "suspended") await context.resume();
    if (kind === "attention") {
      tone(context, 880, 0, 0.25);
    } else if (kind === "done") {
      tone(context, 660, 0, 0.18);
      tone(context, 990, 0.12, 0.3);
    } else {
      tone(context, 220, 0, 0.35, 0.16);
    }
  } catch {
    // Geen geluid mogelijk (geen audio-apparaat): stil doorgaan is hier goed, het is alleen een signaal.
  }
}
