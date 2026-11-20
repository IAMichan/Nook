// The main window's keyboard and layout parts brought over from the Mac: back and forward (UI-36), the sidebar's width
// (UI-37), split view (UI-35), the cheat sheet key (UI-40) and the held-Ctrl hints and F6 areas (UI-63).
import { describe, expect, it } from "vitest";
import { Trail } from "./trail";
import { LAYOUT, dragged, panelWidth, sidebarWidth } from "./panel-resize";
import { splitLanding, splitSide, storedTabWindows, tabFromLocation } from "./panel-split";
import { holdsCtrlAlone, numberHint } from "./key-hold";
import { nextArea, shellShortcut } from "./shell-shortcuts";

const press = (key: string, more: Partial<KeyboardEvent> = {}) => ({ key, ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, repeat: false, isComposing: false, defaultPrevented: false, ...more });
const context = { paletteOpen: false, modalOpen: false, editing: false, chat: true };

describe("back and forward", () => {
  it("walks the trail and drops what was ahead when another opens", () => {
    const t = new Trail<string>("a");
    t.visit("b");
    t.visit("c");
    expect(t.back()).toBe("b");
    expect(t.back()).toBe("a");
    expect(t.canBack).toBe(false);
    expect(t.forward()).toBe("b");
    t.visit("d");
    expect(t.canForward).toBe(false);
    expect(t.items).toEqual(["a", "b", "d"]);
  });

  it("ignores opening what is already open and keeps at most the limit", () => {
    const t = new Trail<number>(null, 3);
    for (const n of [1, 1, 2, 3, 4]) t.visit(n);
    expect(t.items).toEqual([2, 3, 4]);
    expect(t.current).toBe(4);
  });

  it("forgets a deleted item and keeps its place", () => {
    const t = new Trail<string>("a");
    t.visit("b");
    t.visit("c");
    t.back();
    t.drop("b");
    expect(t.items).toEqual(["a", "c"]);
    expect(t.current).toBe("a");
  });

  it("answers Ctrl+[ and Ctrl+], and Ctrl+/ or ? for the cheat sheet", () => {
    expect(shellShortcut(press("["), context)).toBe("back");
    expect(shellShortcut(press("]"), { ...context, editing: true })).toBe("forward");
    expect(shellShortcut(press("/"), context)).toBe("cheatsheet");
    expect(shellShortcut(press("?", { ctrlKey: false, shiftKey: true }), context)).toBe("cheatsheet");
    expect(shellShortcut(press("?", { ctrlKey: false, shiftKey: true }), { ...context, editing: true })).toBeNull();
    expect(shellShortcut(press("["), { ...context, modalOpen: true })).toBeNull();
  });
});

describe("panel widths", () => {
  it("keeps the sidebar between its minimum and maximum, and leaves the page a conversation", () => {
    expect(sidebarWidth(100, 1400)).toBe(LAYOUT.sidebarMin);
    expect(sidebarWidth(900, 1400)).toBe(LAYOUT.sidebarMax);
    expect(sidebarWidth(320, 1400)).toBe(320);
    expect(sidebarWidth(400, 700)).toBe(700 - LAYOUT.minimumConversation);
  });

  it("shrinks both in proportion when there is too little room", () => {
    const w = panelWidth(440, 240, 500, 376);
    expect(w).toBeLessThanOrEqual(240);
    expect(w).toBeGreaterThan(100);
    expect(panelWidth(300, 240, 0, 376)).toBe(300);
  });

  it("drags a line on the leading edge the other way", () => {
    expect(dragged(300, 20, false)).toBe(320);
    expect(dragged(300, 20, true)).toBe(280);
  });
});

describe("split view", () => {
  it("never shows the tab beside itself", () => {
    expect(splitSide("chats", "chat")).toBe("chats");
    expect(splitSide("chats", "chats")).toBeNull();
    expect(splitSide("", "chat")).toBeNull();
    expect(splitSide("settings", "chat")).toBeNull();
  });

  it("opens a tab that already shows beside in that pane", () => {
    expect(splitLanding("chats", "chat", "chats")).toBe("chat");
    expect(splitLanding("agents", "chat", "chats")).toBe("agents");
  });

  it("reads the torn-off windows and a window's tab safely", () => {
    expect(storedTabWindows('["chats","music","chats","nope"]')).toEqual(["chats", "music"]);
    expect(storedTabWindows("not json")).toEqual([]);
    expect(tabFromLocation("?tab=music")).toBe("music");
    expect(tabFromLocation("?tab=settings")).toBeNull();
  });
});

describe("keys held and areas", () => {
  it("shows hints only for Ctrl alone", () => {
    expect(holdsCtrlAlone({ key: "Control", ctrlKey: true, metaKey: false, altKey: false, shiftKey: false })).toBe(true);
    expect(holdsCtrlAlone({ key: "Control", ctrlKey: true, metaKey: false, altKey: false, shiftKey: true })).toBe(false);
    expect(holdsCtrlAlone({ key: "k", ctrlKey: true, metaKey: false, altKey: false, shiftKey: false })).toBe(false);
    expect(numberHint(0)).toBe("Ctrl+1");
    expect(numberHint(8, true)).toBe("⌘9");
    expect(numberHint(9)).toBeNull();
  });

  it("cycles F6 through the areas", () => {
    expect(shellShortcut(press("F6", { ctrlKey: false }), context)).toBe("focus-next");
    expect(shellShortcut(press("F6", { ctrlKey: false, shiftKey: true }), context)).toBe("focus-previous");
    expect(nextArea(-1, 3, false)).toBe(0);
    expect(nextArea(2, 3, false)).toBe(0);
    expect(nextArea(0, 3, true)).toBe(2);
    expect(nextArea(0, 0, false)).toBe(-1);
  });
});

describe("tray status lines", async () => {
  const { trayLive } = await import("./tray-live");
  const base = { now: Date.parse("2026-11-20T10:00:00Z"), locale: "en-GB", events: null, sessions: [], nooks: [], playing: null, update: null, updateVersion: null };
  const session = (status: string, name = "Fix the login") => ({ id: name, name, status, approvalId: null, questionId: null }) as never;

  it("is quiet when nothing goes on", () => {
    const t = trayLive(base);
    expect([t.nextEvent, t.needsYou, t.track, t.update]).toEqual([null, null, null, null]);
    expect(t.agentsRunning).toBe(0);
  });

  it("takes the next meeting, the agents, what needs you and the music", () => {
    const t = trayLive({
      ...base,
      events: [
        { title: "Lunch", start: "2026-11-20T12:00:00Z", end: "2026-11-20T13:00:00Z", allDay: false },
        { title: "Standup", start: "2026-11-20T09:45:00Z", end: "2026-11-20T10:15:00Z", allDay: false },
        { title: "Done", start: "2026-11-20T08:00:00Z", end: "2026-11-20T09:00:00Z", allDay: false },
      ],
      sessions: [session("running"), session("waiting", "Review")],
      playing: { app: "Spotify", title: "Song", artist: "Band", album: "", playing: true, artwork: null, position: null, duration: null } as never,
      update: "available", updateVersion: "1.2.0",
    });
    expect(t.nextEvent).toBe("Standup");
    expect(t.nextEventNow).toBe(true);
    expect([t.agentsRunning, t.agentsWaiting]).toEqual([2, 1]);
    expect([t.needsYou, t.needsYouRoute]).toEqual(["Review", "agents"]);
    expect(t.track).toBe("Song – Band");
    expect([t.update, t.updateVersion]).toEqual(["available", "1.2.0"]);
  });

  it("puts a Nook that asks you first", () => {
    const t = trayLive({ ...base, sessions: [session("waiting")], nooks: [{ id: "n1", title: "Offsite", status: "waiting" }] as never });
    expect([t.needsYou, t.needsYouRoute]).toEqual(["Offsite", "nook:n1"]);
  });
});

describe("hold Ctrl+Q to quit", async () => {
  const { QuitHold, quitInput, HOLD_MS } = await import("./quit-hold");
  it("quits only after a full second and the release", () => {
    const h = new QuitHold();
    expect(h.handle("pressed", 0)).toEqual({ hint: "hold", checkIn: HOLD_MS });
    expect(h.handle("check", 400).quit).toBeUndefined();
    expect(h.handle("check", HOLD_MS)).toEqual({ hint: "release" });
    expect(h.handle("otherKey", HOLD_MS + 50)).toEqual({});
    expect(h.handle("released", HOLD_MS + 100)).toEqual({ hint: "hidden", quit: true });
    expect(h.idle).toBe(true);
  });

  it("lets go early without quitting", () => {
    const h = new QuitHold();
    h.handle("pressed", 0);
    expect(h.handle("released", 300)).toEqual({ hint: "hidden" });
    expect(h.handle("check", HOLD_MS)).toEqual({});
  });

  it("reads the keys", () => {
    const k = (type: string, key: string, more = {}) => ({ type, key, ctrlKey: false, metaKey: false, altKey: false, shiftKey: false, repeat: false, ...more });
    expect(quitInput(k("keydown", "q", { ctrlKey: true }))).toBe("pressed");
    expect(quitInput(k("keydown", "q", { ctrlKey: true, repeat: true }))).toBeNull();
    expect(quitInput(k("keydown", "q", { ctrlKey: true, shiftKey: true }))).toBe("otherKey");
    expect(quitInput(k("keyup", "Control"))).toBe("released");
    expect(quitInput(k("keydown", "Control", { ctrlKey: true }))).toBeNull();
  });
});

describe("the bar's new-track strip", async () => {
  const { isNewTrack, trackLine } = await import("./bar-music");
  const np = (title: string, playing = true) => ({ app: "Spotify", title, artist: "Band", album: "", playing, artwork: null, position: null, duration: null }) as never;
  it("names the track and speaks only for another playing one", () => {
    expect(trackLine(np("Song"))).toBe("Song – Band");
    expect(trackLine(null)).toBeNull();
    expect(isNewTrack(undefined, np("Song"))).toBe(false);
    expect(isNewTrack(null, np("Song"))).toBe(true);
    expect(isNewTrack("Song – Band", np("Song"))).toBe(false);
    expect(isNewTrack("Old – Band", np("Song", false))).toBe(false);
  });
});

describe("the orb's mood per tab", async () => {
  const { orbMood } = await import("./bar-music");
  const m = { nookWaiting: 0, nookWorking: 1, agentsWaiting: 1, agentsRunning: 2, playing: true };
  it("follows the tab on screen, and everything when closed", () => {
    expect(orbMood("agents", m)).toBe("waiting");
    expect(orbMood("nook", m)).toBe("working");
    expect(orbMood("music", m)).toBe("listen");
    expect(orbMood(null, m)).toBe("waiting");
    expect(orbMood(null, { ...m, agentsWaiting: 0 })).toBe("working");
    expect(orbMood(null, { nookWaiting: 0, nookWorking: 0, agentsWaiting: 0, agentsRunning: 0, playing: true })).toBe("idle");
  });
});

describe("birthdays from the calendar", async () => {
  const { calendarBirthdays } = await import("./birthdays");
  it("finds today's all-day birthday events and the person's name", () => {
    const today = new Date(2026, 10, 20, 9);
    const at = new Date(2026, 10, 20).toISOString();
    const list = calendarBirthdays([
      { title: "Anna's birthday", start: at, allDay: true },
      { title: "Verjaardag van Peter 🎂", start: at, allDay: true },
      { title: "Birthday party planning", start: at, allDay: false },
      { title: "Team offsite", start: at, allDay: true },
    ], today);
    expect(list.map((b) => b.name)).toEqual(["Anna", "Peter"]);
  });
});

describe("snooze options", async () => {
  const { snoozeEnd, snoozeMenu, cleaned, DEFAULT_OPTIONS } = await import("./snooze-options");
  it("ends at the right time and hides what has passed", () => {
    const now = new Date(2026, 10, 20, 19, 30); // a Friday evening
    expect(snoozeEnd({ kind: "time", day: "today", hour: 18, minute: 0 }, now)).toBeNull();
    expect(snoozeEnd({ kind: "time", day: "monday", hour: 9, minute: 0 }, now)?.getDate()).toBe(23);
    expect(snoozeEnd({ kind: "time", day: "friday", hour: 9, minute: 0 }, now)?.getDate()).toBe(27);
    expect(snoozeEnd({ kind: "duration", minutes: 60 }, now)?.getHours()).toBe(20);
    expect(snoozeMenu(DEFAULT_OPTIONS, now).map((x) => x.option.kind)).toEqual(["duration", "time"]);
  });
  it("keeps only valid options, once each", () => {
    expect(cleaned([{ kind: "duration", minutes: 30 }, { kind: "duration", minutes: 30 }, { kind: "time", day: "mars", hour: 9, minute: 0 }])).toEqual([{ kind: "duration", minutes: 30 }]);
    expect(cleaned("nonsense")).toEqual(DEFAULT_OPTIONS);
  });
});
