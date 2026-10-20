// Agent notices in the bar (AgentCards on the Mac): how long one stays, the countdown on its OK button, and the one
// line a compact notice shows. No UI code, so tests can use it on its own.
import type { AgentStatus } from "./agents";

/// How long a notice stays while the pointer is off the bar; the ring on its OK counts down the same time.
export const NOTICE_SECONDS = 5.2;
/// Hovering holds the clock, but a notice never stays longer than this in all.
export const NOTICE_MAX_SECONDS = 100;

export type NoticeTone = "done" | "failed" | "waiting";

/// A clock that only runs while the pointer is off the bar. Call `advance` on every tick.
export class Countdown {
  private left: number;
  private total = 0;

  constructor(
    private readonly seconds = NOTICE_SECONDS,
    private readonly max = NOTICE_MAX_SECONDS,
  ) {
    this.left = seconds;
  }

  /// `elapsed` seconds went by; while `paused` (the pointer is on the bar) the countdown holds.
  advance(elapsed: number, paused: boolean) {
    this.total += elapsed;
    if (!paused) this.left = Math.max(0, this.left - elapsed);
  }

  /// What is left of the ring, from 1 (full) to 0.
  get fraction(): number {
    return this.seconds > 0 ? this.left / this.seconds : 0;
  }

  get done(): boolean {
    return this.left <= 0 || this.total >= this.max;
  }
}

export function noticeTone(status: AgentStatus): NoticeTone {
  return status === "done" ? "done" : status === "failed" ? "failed" : "waiting";
}

/// The line of a compact notice: "Claude Code is klaar · nook".
export function compactNotice(name: string, project: string, status: AgentStatus): string {
  const tone = noticeTone(status);
  const who = tone === "done" ? `${name} is klaar` : tone === "failed" ? `${name} is gestopt met een fout` : `${name} wacht op je`;
  return project ? `${who} · ${project}` : who;
}
