// What the tray menu shows on top (the Mac's menu bar menu, `AppDelegate.rebuild`), from what the main window knows:
// the next meeting, the agents at work, the one thing that needs you, the music and an update. Rust builds the menu
// and the taskbar badge from it (`platform/tray_live.rs`). Pure, so the choice of lines is tested.
import type { AgentSession } from "./agents";
import type { NowPlaying } from "./services";
import type { ConversationSummary } from "./types";

export interface TrayLive {
  nextEvent: string | null;
  nextEventAt: string | null;
  nextEventNow: boolean;
  agentsRunning: number;
  agentsWaiting: number;
  needsYou: string | null;
  needsYouRoute: string | null;
  track: string | null;
  playing: boolean;
  update: "available" | "installing" | "ready" | "failed" | null;
  updateVersion: string | null;
  wordsToday: number | null;
}

export interface TrayEvent { title: string; start: string; end: string; allDay: boolean }

export function trayLive(input: {
  now: number;
  locale: string;
  events: TrayEvent[] | null;
  sessions: AgentSession[];
  nooks: ConversationSummary[];
  playing: NowPlaying | null;
  update: string | null;
  updateVersion: string | null;
}): TrayLive {
  const { now } = input;
  // The meeting that is on or comes next today, as on the Mac (`upcoming.first { end > now }`).
  const event = (input.events ?? [])
    .filter((e) => !e.allDay && Date.parse(e.end) > now)
    .sort((a, b) => Date.parse(a.start) - Date.parse(b.start))[0];
  const running = input.sessions.filter((s) => s.status === "running" || s.status === "waiting");
  const waiting = input.sessions.filter((s) => s.status === "waiting" || s.approvalId || s.questionId);
  // The one thing that waits on you most: a Nook that asks you something, then a session that waits for you.
  const nook = input.nooks.find((n) => n.status === "waiting");
  const session = waiting[0];
  const track = input.playing?.title ? (input.playing.artist ? `${input.playing.title} – ${input.playing.artist}` : input.playing.title) : null;
  const update = input.update === "available" || input.update === "installing" || input.update === "ready" || input.update === "failed" ? input.update : null;
  return {
    nextEvent: event?.title ?? null,
    nextEventAt: event ? new Date(event.start).toLocaleTimeString(input.locale, { hour: "2-digit", minute: "2-digit" }) : null,
    nextEventNow: !!event && Date.parse(event.start) <= now,
    agentsRunning: running.length,
    agentsWaiting: waiting.length,
    needsYou: nook?.title ?? session?.name ?? null,
    needsYouRoute: nook ? `nook:${nook.id}` : session ? "agents" : null,
    track,
    playing: !!input.playing?.playing,
    update,
    updateVersion: update === "available" ? input.updateVersion : null,
    wordsToday: null,
  };
}
