// Nook as a buddy in the bar (`momentStrip` in the Mac's NotchRootView, SV-19): the moment the half-minute timer in
// `src-tauri/src/services/buddy.rs` shares (`buddy-moment`) shows as a one-line notice with Nook's face in its mood, at
// most one button and OK, and goes by itself after its seconds (hovering holds it). "Breathe with Nook now" in Settings
// and "Breathe along" on a break (`buddy-breathe`) show three slow breaths: Nook grows and shrinks (the orb's `breathe`
// mood, 4 s in, 4 s holding, 6 s out) and the line says when to breathe in and out.
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Mood } from "../components/Orb.svelte";
import { Countdown } from "./notice";
import { nook } from "./state.svelte";
import { tr } from "./i18n.svelte";

export interface BuddyMomentView {
  id: string;
  kind: "morning" | "welcomeBack" | "breakTime" | "lateNight" | "fridayWrap" | "birthday" | "milestone" | "breathe";
  mood: Mood;
  line: string;
  action?: "today" | "agents" | "breathe" | null;
  actionTitle?: string | null;
  seconds: number;
  count: number;
  minutes: number;
}

/// One breathing cycle (`NookMoment.breathCycle`): 4 seconds in, 4 holding, 6 out.
export const BREATH_CYCLE = 14;
/// Three cycles, about 40 seconds (`NookMoment.breathLength`).
export const BREATH_LENGTH = BREATH_CYCLE * 3;

/// The line for the breathing phase at `elapsed` seconds (`breathPhaseKey`).
export function breathLine(elapsed: number): string {
  const c = ((elapsed % BREATH_CYCLE) + BREATH_CYCLE) % BREATH_CYCLE;
  if (c < 4) return tr("Adem rustig in…", "Breathe in slowly…");
  if (c < 8) return tr("Even vasthouden…", "Hold…");
  return tr("En langzaam uit…", "And slowly out…");
}

class Buddy {
  /// The moment in the bar, or null.
  moment = $state<BuddyMomentView | null>(null);
  /// What is left of its time, from 1 to 0, for the ring on OK.
  left = $state<number | null>(null);
  /// Seconds since a breathing moment started.
  elapsed = $state(0);
  /// The pointer is on the bar: the countdown holds while you read.
  hovering = false;
  private timer: ReturnType<typeof setInterval> | undefined;
  private started = false;

  /// The line the bar shows now: the moment's words, or the breathing phase.
  get line(): string {
    const m = this.moment;
    if (!m) return "";
    return m.kind === "breathe" ? breathLine(this.elapsed) : m.line;
  }

  /// Listens once per window for the moments and the breathing.
  start() {
    if (this.started) return;
    this.started = true;
    listen<BuddyMomentView>("buddy-moment", (e) => this.show(e.payload)).catch(() => {});
    listen("buddy-breathe", () => this.breathe()).catch(() => {});
  }

  show(moment: BuddyMomentView) {
    if (nook.settings?.buddyMoments === false && moment.kind !== "breathe") return;
    this.moment = moment;
    this.run(moment.seconds);
  }

  /// A minute of breathing along, also when no moment shows: asked for, so it shows over what is there.
  breathe() {
    this.show({ id: `breathe-${Date.now()}`, kind: "breathe", mood: "breathe", line: "", seconds: BREATH_LENGTH, count: 0, minutes: 0 });
  }

  /// Asks the app to breathe along (it also starts a fresh stretch of work); in a preview without the app, here at once.
  requestBreathe() {
    invoke("buddy_breathe").catch(() => this.breathe());
  }

  /// OK, or its time is up: gone, and Home's card does not show it again.
  dismiss() {
    const id = this.moment?.id;
    this.stop();
    if (id && !id.startsWith("breathe-")) invoke("buddy_moment", { dismissId: id }).catch(() => {});
  }

  private run(seconds: number) {
    clearInterval(this.timer);
    const clock = new Countdown(seconds, seconds * 4);
    const shown = this.moment;
    const begin = performance.now();
    let last = begin;
    this.left = 1;
    this.elapsed = 0;
    this.timer = setInterval(() => {
      const now = performance.now();
      // Breathing goes on with the pointer on the bar: the breath does not wait.
      clock.advance((now - last) / 1000, this.hovering && shown?.kind !== "breathe");
      last = now;
      this.left = clock.fraction;
      this.elapsed = (now - begin) / 1000;
      if (clock.done && this.moment === shown) this.dismiss();
    }, 250);
  }

  private stop() {
    clearInterval(this.timer);
    this.timer = undefined;
    this.moment = null;
    this.left = null;
    this.elapsed = 0;
  }
}

export const buddy = new Buddy();
